--!strict
-- FollowAnchor — 相机轨跟随绑定的锚点解析与相对/世界 CFrame 换算。
-- 插件 SceneResolver 与 runtime BindingResolver 使用相同路径语义。

local CutsceneFormat = require(script.Parent.CutsceneFormat)

local FollowAnchor = {}

local DEFAULT_FOLLOW_PART = "HumanoidRootPart"
local _warnedKeys: { [string]: boolean } = {}

local function warnMissingOnce(track: CutsceneFormat.Track)
	local binding = track.followBinding or ""
	local partPath = track.followPart or DEFAULT_FOLLOW_PART
	local key = binding .. "|" .. partPath
	if _warnedKeys[key] then
		return
	end
	_warnedKeys[key] = true
	warn(
		`[anima] 相机轨跟随:无法解析锚点 binding='{binding}' part='{partPath}',关键帧按世界 CFrame 求值`
	)
end

local function nodeCFrame(node: Instance): CFrame?
	if node:IsA("Attachment") then
		return node.WorldCFrame
	end
	if node:IsA("BasePart") then
		return node.CFrame
	end
	return nil
end

local function findPath(root: Instance, partPath: string): Instance?
	if partPath == "" then
		partPath = DEFAULT_FOLLOW_PART
	end
	if not string.find(partPath, "/", 1, true) then
		local direct = root:FindFirstChild(partPath)
		if direct then
			return direct
		end
	end
	local cur: Instance = root
	for segment in string.split(partPath, "/") do
		if segment == "" then
			continue
		end
		local nextInst = cur:FindFirstChild(segment)
		if not nextInst then
			return nil
		end
		cur = nextInst
	end
	return cur
end

-- 把逻辑绑定 + 相对路径解析成锚点世界 CFrame。
function FollowAnchor.resolveFollowAnchor(
	followBinding: CutsceneFormat.Binding,
	followPart: string?,
	resolveBinding: CutsceneFormat.BindingResolver
): CFrame?
	if followBinding == "" then
		return nil
	end
	local inst = resolveBinding(followBinding)
	if not inst then
		return nil
	end
	local path = followPart or DEFAULT_FOLLOW_PART
	local node = findPath(inst, path)
	if not node and inst:IsA("Model") and path == DEFAULT_FOLLOW_PART then
		node = inst:FindFirstChild(DEFAULT_FOLLOW_PART)
	end
	if not node then
		return nil
	end
	return nodeCFrame(node)
end

function FollowAnchor.hasFollowBinding(track: CutsceneFormat.Track): boolean
	return track.kind == "camera" and track.followBinding ~= nil and track.followBinding ~= ""
end

-- 存储用:视口/把手世界位姿 → 写入 key 的 CFrame(相对或世界)。
function FollowAnchor.storeKeyframeCFrame(
	track: CutsceneFormat.Track,
	worldCf: CFrame,
	resolveBinding: CutsceneFormat.BindingResolver?
): CFrame
	if not FollowAnchor.hasFollowBinding(track) or not resolveBinding then
		return worldCf
	end
	local anchor = FollowAnchor.resolveFollowAnchor(
		track.followBinding :: string,
		track.followPart,
		resolveBinding
	)
	if anchor then
		return anchor:ToObjectSpace(worldCf)
	end
	return worldCf
end

-- 求值/视口还原:key 存储值 → 世界 CFrame。
function FollowAnchor.worldFromKeyframeCFrame(
	track: CutsceneFormat.Track,
	storedCf: CFrame,
	resolveBinding: CutsceneFormat.BindingResolver?
): CFrame
	if not FollowAnchor.hasFollowBinding(track) or not resolveBinding then
		return storedCf
	end
	local anchor = FollowAnchor.resolveFollowAnchor(
		track.followBinding :: string,
		track.followPart,
		resolveBinding
	)
	if anchor then
		return anchor * storedCf
	end
	warnMissingOnce(track)
	return storedCf
end

-- 切线 offset(存储空间) ↔ 世界位移(07 spec:与 value 同空间约定)。
function FollowAnchor.worldDeltaToStoredOffset(
	track: CutsceneFormat.Track,
	worldDelta: Vector3,
	resolveBinding: CutsceneFormat.BindingResolver?
): Vector3
	if not FollowAnchor.hasFollowBinding(track) or not resolveBinding then
		return worldDelta
	end
	local anchor = FollowAnchor.resolveFollowAnchor(
		track.followBinding :: string,
		track.followPart,
		resolveBinding
	)
	if anchor then
		return anchor:VectorToObjectSpace(worldDelta)
	end
	return worldDelta
end

function FollowAnchor.storedOffsetToWorldDelta(
	track: CutsceneFormat.Track,
	storedOffset: Vector3,
	resolveBinding: CutsceneFormat.BindingResolver?
): Vector3
	if not FollowAnchor.hasFollowBinding(track) or not resolveBinding then
		return storedOffset
	end
	local anchor = FollowAnchor.resolveFollowAnchor(
		track.followBinding :: string,
		track.followPart,
		resolveBinding
	)
	if anchor then
		return anchor:VectorToWorldSpace(storedOffset)
	end
	return storedOffset
end

return FollowAnchor
