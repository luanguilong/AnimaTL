--!strict
-- MoonImport — 解析 Moon Animator 2 工程存档(StringValue),提取相机轨道数据。
-- MA2 存档结构:StringValue.Value = JSON 头(Information + Items);
-- 子级按 Items 序号建文件夹,相机项含 CFrame / FieldOfView 两个属性轨,
-- 每个关键帧是「帧号文件夹 → Values.0(值) + Eases.0(Type/Params.Direction)」。
-- 只读取数据,不引用 Moon Animator 任何代码。

local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")

local CutsceneFormat = require(script.Parent.Shared.CutsceneFormat)

local MoonImport = {}

local DEFAULT_FPS = 60 -- MA2 默认时间轴帧率

export type CameraKeyframe = {
	t: number, -- 秒
	value: CFrame,
	easing: string?,
}

export type FovKeyframe = {
	t: number,
	value: number,
	easing: string?,
}

export type CameraData = {
	keyframes: { CameraKeyframe },
	fov: number?, -- 首帧 FOV(写进 vcam attribute 作回退)
	fovKeyframes: { FovKeyframe }, -- 完整 FOV 关键帧(≥2 帧时驱动 FOV 动画)
	lengthSec: number,
}

-- 关节动画(20 spec):一个 Rig 项 → 一条 rigAnim 轨的数据。
export type RigData = {
	name: string,
	jointTracks: { CutsceneFormat.JointTrack },
	lengthSec: number,
}

export type ParsedSave = {
	cameras: { CameraData },
	rigs: { RigData },
	fps: number,
	lengthSec: number,
	-- 创作锚点:相对化转换用。优先从存档 Rig 项自身的 CFrame 属性轨读
	-- 「创作时」的 rig 位姿(default 值 = Moon 保存那一刻的模型 pivot,
	-- 不受之后 rig 被挪动影响);读不到才退回场景里 HRP 的导入时快照。
	anchorCf: CFrame?,
	anchorName: string?,
	anchorSource: string?, -- "save" | "live"
	-- 场景里 rig 当前位姿快照(vcam gizmo 摆位用;可能为 nil)
	liveAnchorCf: CFrame?,
}

function MoonImport.isSave(inst: Instance): boolean
	return inst:IsA("StringValue") and string.sub(inst.Value, 1, 15) == '{"Information":'
end

-- 在 workspace / ServerStorage 顶层(及 MoonAnimator 存档文件夹)里找 MA2 存档。
function MoonImport.findSaves(): { StringValue }
	local out: { StringValue } = {}
	local function scan(parent: Instance?, deep: boolean)
		if not parent then
			return
		end
		local pool = if deep then parent:GetDescendants() else parent:GetChildren()
		for _, c in pool do
			if MoonImport.isSave(c) then
				table.insert(out, c :: StringValue)
			end
		end
	end
	scan(workspace, false)
	scan(ServerStorage, false)
	scan(ServerStorage:FindFirstChild("MoonAnimator2Saves"), true)
	return out
end

-- MA2 缓动 → anima Easing 名(linear/quadIn/quadOut/quadInOut/cubicInOut/sine)
local function mapEase(easeType: string?, direction: string?): string?
	if easeType == nil or easeType == "Linear" then
		return nil -- 缺省线性
	end
	if easeType == "Sine" then
		return "sine"
	end
	if easeType == "Quad" then
		if direction == "In" then
			return "quadIn"
		elseif direction == "Out" then
			return "quadOut"
		end
		return "quadInOut"
	end
	-- Cubic/Quart/Quint/Expo/Back/Elastic… anima 暂无同款,用最接近的平滑档
	return "cubicInOut"
end

type FrameEntry = { frame: number, value: any, easing: string? }

-- 读一个属性轨文件夹(CFrame / FieldOfView):帧号子文件夹 → Values.0 + Eases.0
local function readPropertyFrames(folder: Instance?): { FrameEntry }
	local out: { FrameEntry } = {}
	if not folder then
		return out
	end
	for _, fr in folder:GetChildren() do
		local frame = tonumber(fr.Name)
		if not frame or not fr:IsA("Folder") then
			continue
		end
		local values = fr:FindFirstChild("Values")
		local v = values and values:FindFirstChild("0")
		if not v then
			continue
		end
		local easeType: string? = nil
		local easeDir: string? = nil
		local eases = fr:FindFirstChild("Eases")
		local ease0 = eases and eases:FindFirstChild("0")
		if ease0 then
			local t = ease0:FindFirstChild("Type")
			if t and t:IsA("StringValue") then
				easeType = t.Value
			end
			local params = ease0:FindFirstChild("Params")
			local d = params and params:FindFirstChild("Direction")
			if d and d:IsA("StringValue") then
				easeDir = d.Value
			end
		end
		table.insert(out, {
			frame = frame,
			value = (v :: any).Value,
			easing = mapEase(easeType, easeDir),
		})
	end
	table.sort(out, function(a, b)
		return a.frame < b.frame
	end)
	return out
end

-- 按存档里的 InstanceNames 路径(["game","Workspace",...])找回实例。
local function resolveItemPath(names: any): Instance?
	if type(names) ~= "table" or #names < 2 then
		return nil
	end
	local cur: Instance = game
	for i = 2, #names do
		local nextInst = cur:FindFirstChild(tostring(names[i]))
		if not nextInst then
			return nil
		end
		cur = nextInst
	end
	return cur
end

local function itemLastName(item: any): string?
	local names = item.Path and item.Path.InstanceNames
	if type(names) == "table" and #names > 0 then
		return tostring(names[#names])
	end
	return nil
end

-- 创作时锚点:Rig 项文件夹里的 CFrame 属性轨(模型 pivot 世界坐标根运动)。
-- default 子值 = Moon 保存那一刻的位姿;没有 default 就取首个关键帧。
local function authoredRigAnchor(sv: StringValue, items: { any }): (CFrame?, string?)
	for i, item in items do
		if type(item) ~= "table" or type(item.Path) ~= "table" or item.Path.ItemType ~= "Rig" then
			continue
		end
		local folder = sv:FindFirstChild(tostring(i))
		local cfFolder = folder and folder:FindFirstChild("CFrame")
		if not cfFolder then
			continue
		end
		local def = cfFolder:FindFirstChild("default")
		if def and def:IsA("CFrameValue") then
			return def.Value, itemLastName(item)
		end
		local frames = readPropertyFrames(cfFolder)
		if frames[1] and typeof(frames[1].value) == "CFrame" then
			return frames[1].value :: CFrame, itemLastName(item)
		end
	end
	return nil, nil
end

-- 读一个 _joint:返回 (关节路径, Transform 关键帧)。
-- 数学(spike 已验证,同 Moonlite):Transform = 帧值:Inverse() × default;
-- 关键帧包可跨多帧:Values.N = 包首帧 + N。烘焙数据逐帧一值,缓动按 linear。
local function readJointTrack(jointFolder: Instance, fps: number): (string?, { CutsceneFormat.Keyframe }?)
	local hier = jointFolder:FindFirstChild("_hier")
	local def = jointFolder:FindFirstChild("default")
	local kfs = jointFolder:FindFirstChild("_keyframes")
	if not (hier and hier:IsA("StringValue") and def and def:IsA("CFrameValue") and kfs) then
		return nil, nil
	end
	local defaultCf = def.Value
	local out: { CutsceneFormat.Keyframe } = {}
	for _, pack in kfs:GetChildren() do
		local baseFrame = tonumber(pack.Name)
		local values = pack:FindFirstChild("Values")
		if not baseFrame or not values then
			continue
		end
		for _, v in values:GetChildren() do
			local idx = tonumber(v.Name)
			if idx and v:IsA("CFrameValue") then
				table.insert(out, {
					t = (baseFrame + idx) / fps,
					value = v.Value:Inverse() * defaultCf,
				})
			end
		end
	end
	if #out == 0 then
		return nil, nil
	end
	table.sort(out, function(a, b)
		return a.t < b.t
	end)
	return hier.Value, out
end

-- 解析全部 Rig 项的关节动画。
local function parseRigs(sv: StringValue, items: { any }, fps: number): { RigData }
	local rigs: { RigData } = {}
	for i, item in items do
		if type(item) ~= "table" or type(item.Path) ~= "table" or item.Path.ItemType ~= "Rig" then
			continue
		end
		local folder = sv:FindFirstChild(tostring(i))
		local rigFolder = folder and folder:FindFirstChild("Rig")
		if not rigFolder then
			continue
		end
		local jointTracks: { CutsceneFormat.JointTrack } = {}
		local maxT = 0
		for _, j in rigFolder:GetChildren() do
			if j.Name ~= "_joint" then
				continue
			end
			local path, keyframes = readJointTrack(j, fps)
			if path and keyframes then
				maxT = math.max(maxT, keyframes[#keyframes].t)
				table.insert(jointTracks, { path = path, keyframes = keyframes })
			end
		end
		if #jointTracks > 0 then
			table.insert(rigs, {
				name = itemLastName(item) or "Rig",
				jointTracks = jointTracks,
				lengthSec = maxT,
			})
		end
	end
	return rigs
end

-- 存档第一个 Rig 项的 HRP 当前位姿(导入时快照;创作锚点的回退)。
local function resolveAnchor(items: { any }): (CFrame?, string?)
	for _, item in items do
		if type(item) == "table" and type(item.Path) == "table" and item.Path.ItemType == "Rig" then
			local inst = resolveItemPath(item.Path.InstanceNames)
			if inst and inst:IsA("Model") then
				local hrp = inst:FindFirstChild("HumanoidRootPart")
				if hrp and hrp:IsA("BasePart") then
					return hrp.CFrame, inst.Name
				end
				-- 道具 rig(斧头等)没有 HRP:用模型 pivot 当锚点
				return inst:GetPivot(), inst.Name
			end
		end
	end
	return nil, nil
end

function MoonImport.parse(sv: StringValue): ParsedSave?
	local ok, header = pcall(HttpService.JSONDecode, HttpService, sv.Value)
	if not ok or type(header) ~= "table" or type(header.Items) ~= "table" then
		return nil
	end
	local info = header.Information
	local fps = DEFAULT_FPS
	if type(info) == "table" and tonumber(info.FPS) then
		fps = tonumber(info.FPS) :: number
	end
	local lengthFrames = if type(info) == "table" and tonumber(info.Length)
		then tonumber(info.Length) :: number
		else 0

	local cameras: { CameraData } = {}
	for i, item in header.Items :: { any } do
		if
			type(item) ~= "table"
			or type(item.Path) ~= "table"
			or item.Path.ItemType ~= "Camera"
		then
			continue
		end
		local folder = sv:FindFirstChild(tostring(i))
		if not folder then
			continue
		end
		local cfFrames = readPropertyFrames(folder:FindFirstChild("CFrame"))
		if #cfFrames == 0 then
			continue
		end
		local keyframes: { CameraKeyframe } = {}
		local maxT = 0
		for _, e in cfFrames do
			if typeof(e.value) ~= "CFrame" then
				continue
			end
			local t = e.frame / fps
			maxT = math.max(maxT, t)
			table.insert(keyframes, { t = t, value = e.value :: CFrame, easing = e.easing })
		end
		local fovKeyframes: { FovKeyframe } = {}
		local fovFrames = readPropertyFrames(folder:FindFirstChild("FieldOfView"))
		for _, e in fovFrames do
			if typeof(e.value) == "number" then
				local t = e.frame / fps
				maxT = math.max(maxT, t)
				table.insert(fovKeyframes, { t = t, value = e.value :: number, easing = e.easing })
			end
		end
		table.insert(cameras, {
			keyframes = keyframes,
			fov = if fovKeyframes[1] then fovKeyframes[1].value else nil,
			fovKeyframes = fovKeyframes,
			lengthSec = math.max(maxT, if fps > 0 then lengthFrames / fps else 0),
		})
	end
	local rigs = parseRigs(sv, header.Items :: { any }, fps)
	if #cameras == 0 and #rigs == 0 then
		return nil
	end
	local liveAnchorCf, liveName = resolveAnchor(header.Items :: { any })
	local authoredCf, authoredName = authoredRigAnchor(sv, header.Items :: { any })
	return {
		cameras = cameras,
		rigs = rigs,
		fps = fps,
		lengthSec = if fps > 0 then lengthFrames / fps else 0,
		anchorCf = authoredCf or liveAnchorCf,
		anchorName = authoredName or liveName,
		anchorSource = if authoredCf then "save" elseif liveAnchorCf then "live" else nil,
		liveAnchorCf = liveAnchorCf,
	}
end

return MoonImport
