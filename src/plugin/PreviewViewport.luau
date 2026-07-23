--!strict
-- PreviewViewport — 可挂到任意父物体的相机实时预览(ViewportFrame)。
--
-- ViewportFrame 只能渲染自身子物体、不能镜像实景,所以把过场涉及的物体克隆进来
-- 并每帧按 playhead 求值驱动:
--   · 相机 → 当前上镜 vcam 位姿(独立相机轨,见 CameraDirector),含 FOV
--   · transform 目标克隆 → Sampler 求值移动
--   · 地面参考(Baseplate)克隆一份,便于判断空间
-- 叠加:电影黑边 + 三分构图网格 + 右上信息(vcam / FOV / 时间)。
--
-- 同一个组件既能挂进独立 DockWidget,也能挂进时间轴面板顶部横条。

local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")

local Shared = script.Parent.Shared
local CameraDirector = require(Shared.CameraDirector)
local VCam = require(Shared.VCam)
local Sampler = require(Shared.Sampler)
local CutsceneFormat = require(Shared.CutsceneFormat)
local SceneResolver = require(script.Parent.SceneResolver)
local AnimationPreview = require(script.Parent.AnimationPreview)
local MediaPreview = require(script.Parent.MediaPreview)
local PropertyPreview = require(script.Parent.PropertyPreview)
local RigAnimPreview = require(script.Parent.RigAnimPreview)
local ViewportFxFeedback = require(script.Parent.ViewportFxFeedback)

local PreviewViewport = {}
PreviewViewport.__index = PreviewViewport

export type PreviewViewport = typeof(setmetatable(
	{} :: {
		vf: ViewportFrame,
		world: WorldModel,
		cam: Camera,
		info: TextLabel,
		_clones: { [string]: Instance },
		_ground: Instance?,
		_animTracks: AnimationPreview.TrackCache,
		_conn: RBXScriptConnection?,
		_getCutscene: (() -> CutsceneFormat.Cutscene)?,
		_getTime: (() -> number)?,
		_lastMediaT: number,
		_getRevision: (() -> number)?,
	},
	PreviewViewport
))

-- 克隆进预览世界。带 Humanoid 的角色不锚定肢体(否则 LoadAnimation 看不到动作)。
local function isCharacterModel(inst: Instance): boolean
	return inst:IsA("Model") and inst:FindFirstChildOfClass("Humanoid") ~= nil
end

local function makeClone(inst: Instance): Instance
	local clone = inst:Clone()
	local isChar = isCharacterModel(clone)
	for _, d in clone:GetDescendants() do
		if d:IsA("BaseScript") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			if isChar then
				d.Anchored = false
				d.CanCollide = false
			else
				d.Anchored = true
			end
		end
	end
	if clone:IsA("BasePart") then
		clone.Anchored = not isChar
	end
	if isChar and clone:IsA("Model") then
		local hum = clone:FindFirstChildOfClass("Humanoid")
		if hum then
			hum.PlatformStand = false
		end
		if inst:IsA("Model") then
			clone:PivotTo(inst:GetPivot())
		elseif inst:IsA("BasePart") then
			clone:PivotTo(inst.CFrame)
		else
			clone:PivotTo(CFrame.new(0, 3, 0))
		end
	end
	return clone
end

local function syncCloneFromSource(clone: Instance, source: Instance)
	if source:IsA("Model") and clone:IsA("Model") then
		clone:PivotTo(source:GetPivot())
	elseif source:IsA("BasePart") and clone:IsA("BasePart") then
		clone.CFrame = source.CFrame
	elseif source:IsA("Model") and clone:IsA("BasePart") then
		clone.CFrame = source:GetPivot()
	elseif source:IsA("BasePart") and clone:IsA("Model") then
		clone:PivotTo(source.CFrame)
	end
end

local _warnedMissingClone: { [string]: boolean } = {}

local function cutsceneUsesTarget(cutscene: CutsceneFormat.Cutscene, name: string): boolean
	for _, tr in cutscene.tracks do
		if (tr.kind == "animation" or tr.kind == "transform") and tr.target == name then
			return true
		end
	end
	return false
end

-- 一条构图参考线。
local function gridLine(pos: UDim2, size: UDim2): Frame
	local f = Instance.new("Frame")
	f.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	f.BackgroundTransparency = 0.85
	f.BorderSizePixel = 0
	f.Position = pos
	f.Size = size
	f.ZIndex = 3
	return f
end

function PreviewViewport.new(parent: Instance): PreviewViewport
	local vf = Instance.new("ViewportFrame")
	vf.Name = "AnimaPreview"
	vf.Size = UDim2.fromScale(1, 1)
	vf.BackgroundColor3 = Color3.fromRGB(12, 13, 16)
	vf.Ambient = Lighting.Ambient
	vf.LightColor = Color3.fromRGB(255, 255, 255)
	vf.LightDirection = Lighting:GetSunDirection() * -1
	vf.Parent = parent

	local world = Instance.new("WorldModel")
	world.Parent = vf

	local cam = Instance.new("Camera")
	cam.FieldOfView = 70
	cam.Parent = world
	vf.CurrentCamera = cam
	ViewportFxFeedback.bindViewport(vf)

	-- 电影黑边(上下,近似 2.35:1 观感)
	for _, y in { 0, 1 } do
		local bar = Instance.new("Frame")
		bar.Name = "Letterbox"
		bar.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		bar.BorderSizePixel = 0
		bar.AnchorPoint = Vector2.new(0, y)
		bar.Position = UDim2.fromScale(0, y)
		bar.Size = UDim2.fromScale(1, 0.11)
		bar.ZIndex = 2
		bar.Parent = vf
	end

	-- 三分构图网格
	gridLine(UDim2.fromScale(1 / 3, 0), UDim2.new(0, 1, 1, 0)).Parent = vf
	gridLine(UDim2.fromScale(2 / 3, 0), UDim2.new(0, 1, 1, 0)).Parent = vf
	gridLine(UDim2.fromScale(0, 1 / 3), UDim2.new(1, 0, 0, 1)).Parent = vf
	gridLine(UDim2.fromScale(0, 2 / 3), UDim2.new(1, 0, 0, 1)).Parent = vf

	-- 右上信息叠加
	local info = Instance.new("TextLabel")
	info.Name = "Info"
	info.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	info.BackgroundTransparency = 0.4
	info.AnchorPoint = Vector2.new(1, 0)
	info.Position = UDim2.new(1, -6, 0, 6)
	info.Size = UDim2.fromOffset(180, 18)
	info.Text = "相机预览"
	info.TextColor3 = Color3.fromRGB(120, 200, 255)
	info.Font = Enum.Font.Gotham
	info.TextSize = 12
	info.TextXAlignment = Enum.TextXAlignment.Right
	info.ZIndex = 4
	local pad = Instance.new("UIPadding")
	pad.PaddingRight = UDim.new(0, 6)
	pad.Parent = info
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 3)
	corner.Parent = info
	info.Parent = vf

	return setmetatable({
		vf = vf,
		world = world,
		cam = cam,
		info = info,
		_clones = {},
		_ground = nil,
		_animTracks = {},
		_conn = nil,
		_getCutscene = nil,
		_getTime = nil,
		_lastMediaT = 0,
		_getRevision = nil,
	}, PreviewViewport)
end

local function findDescendantInClone(
	wsTarget: Instance,
	rigBinding: string,
	clones: { [string]: Instance }
): Instance?
	local rigSrc = SceneResolver.resolve(rigBinding)
	local rigClone = clones[rigBinding]
	if not rigSrc or not rigClone or not wsTarget:IsDescendantOf(rigSrc) then
		return nil
	end
	local segments: { string } = {}
	local cur: Instance? = wsTarget
	while cur and cur ~= rigSrc do
		table.insert(segments, 1, cur.Name)
		cur = cur.Parent
	end
	local node: Instance? = rigClone
	for _, seg in segments do
		if not node then
			return nil
		end
		node = node:FindFirstChild(seg)
	end
	return node
end

-- 收集过场涉及的目标名(transform / animation / vcam LookAt)。
local function collectTargets(cutscene: CutsceneFormat.Cutscene): { string }
	local set: { [string]: boolean } = {}
	for _, track in cutscene.tracks do
		if
			track.kind == "transform"
			or track.kind == "animation"
			or track.kind == "effect"
			or track.kind == "sound"
			or track.kind == "property"
			or track.kind == "rigAnim"
		then
			set[track.target] = true
		elseif track.kind == "camera" and track.followBinding and track.followBinding ~= "" then
			set[track.followBinding] = true
		end
	end
	for _, name in VCam.list() do
		local part = VCam.find(name)
		local la = part and part:GetAttribute("LookAt")
		if typeof(la) == "string" and la ~= "" then
			set[la] = true
		end
	end
	local out = {}
	for name in set do
		table.insert(out, name)
	end
	return out
end

-- 依据过场重建克隆集合(目标 + 地面参考)。同一 Workspace 实例只克隆一次(多轨/Player+真名不重复)。
function PreviewViewport.rebuild(self: PreviewViewport, cutscene: CutsceneFormat.Cutscene)
	local destroyed: { [Instance]: boolean } = {}
	for _, c in self._clones do
		if not destroyed[c] then
			destroyed[c] = true
			c:Destroy()
		end
	end
	self._clones = {}
	self._lastMediaT = 0
	MediaPreview.reset("viewport")
	PropertyPreview.restore("viewport")
	AnimationPreview.clearCache(self._animTracks)
	if self._ground then
		self._ground:Destroy()
		self._ground = nil
	end

	local clonedSource: { [Instance]: Instance } = {}
	for _, name in collectTargets(cutscene) do
		local inst = SceneResolver.resolve(name)
		if inst and (inst:IsA("BasePart") or inst:IsA("Model")) then
			local clone = clonedSource[inst]
			if not clone then
				clone = makeClone(inst)
				clone.Parent = self.world
				clonedSource[inst] = clone
			end
			self._clones[name] = clone
		elseif cutsceneUsesTarget(cutscene, name) and not _warnedMissingClone[name] then
			_warnedMissingClone[name] = true
			warn(
				`[anima] 预览找不到目标 '{name}'。Player=Workspace 顶层 Rig(或 Play 时 LocalPlayer);请命名为 Player/Rig 或绑定具体物体名`
			)
		end
	end

	-- 地面参考
	local ground = workspace:FindFirstChild("Baseplate")
	if ground and ground:IsA("BasePart") then
		local g = makeClone(ground)
		g.Parent = self.world
		self._ground = g
	end

	-- 同步一次光照
	self.vf.Ambient = Lighting.Ambient
	self.vf.LightDirection = Lighting:GetSunDirection() * -1
end

-- 求某时刻的相机 CFrame + FOV + 上镜相机名(CameraDirector 择一)。
local function evalCamera(
	cutscene: CutsceneFormat.Cutscene,
	t: number,
	resolveBinding: CutsceneFormat.BindingResolver?
): (CFrame?, number?, string?)
	local cf, name, trackFov = CameraDirector.evaluate(cutscene, t, resolveBinding)
	local fov: number? = trackFov
	if not fov and name then
		local part = VCam.find(name)
		local f = part and part:GetAttribute("FOV")
		if typeof(f) == "number" then
			fov = f
		end
	end
	return cf, fov, name
end

-- 更新一帧:相机 + transform 克隆 + 动画定帧 + 信息叠加。
function PreviewViewport.update(
	self: PreviewViewport,
	cutscene: CutsceneFormat.Cutscene,
	t: number,
	stepDt: number?
)
	-- 跟随对齐:每个克隆源只对齐一次(多 binding 名指向同一 Rig 时不重复 Pivot)。
	local syncedClone: { [Instance]: boolean } = {}
	for _, track in cutscene.tracks do
		if track.kind == "camera" and track.followBinding and track.followBinding ~= "" then
			local name = track.followBinding
			local clone = self._clones[name]
			local source = SceneResolver.resolve(name)
			if clone and source and not syncedClone[clone] then
				syncedClone[clone] = true
				syncCloneFromSource(clone, source)
			end
		end
	end

	local camCF, fov, active = evalCamera(cutscene, t, SceneResolver.resolve)
	if camCF then
		self.cam.CFrame = camCF
	end
	self.cam.FieldOfView = fov or 70
	self.info.Text =
		string.format("🎥 %s · FOV %d · %.2fs", active or "—", math.floor(fov or 70), t)

	for _, track in cutscene.tracks do
		if track.hidden then
			continue
		end
		if track.kind == "transform" and track.keyframes and #track.keyframes > 0 then
			local clone = self._clones[track.target]
			if clone then
				local cf = Sampler.sampleCFrame(track.keyframes, t)
				if cf then
					if clone:IsA("BasePart") then
						clone.CFrame = cf
					elseif clone:IsA("Model") then
						clone:PivotTo(cf)
					end
				end
			end
		end
	end

	-- 动画轨:在克隆角色上定帧
	for _, track in cutscene.tracks do
		if track.kind == "animation" and track.clips and not track.hidden then
			local clone = self._clones[track.target]
			if clone and clone:IsA("Model") then
				AnimationPreview.stepClipsOnModel(
					clone,
					track.target,
					track.clips,
					t,
					self._animTracks,
					stepDt
				)
			end
		end
	end

	local function resolveInViewport(binding: string): Instance?
		local wsInst = SceneResolver.resolve(binding)
		if wsInst then
			for _, tr in cutscene.tracks do
				if tr.kind == "animation" then
					local inClone = findDescendantInClone(wsInst, tr.target, self._clones)
					if inClone then
						return inClone
					end
				end
			end
		end
		if self._clones[binding] then
			return self._clones[binding]
		end
		return wsInst
	end

	MediaPreview.step(cutscene, t, self._lastMediaT, resolveInViewport, "viewport", {
		workspaceResolve = SceneResolver.resolve,
		cutsceneRevision = if self._getRevision then self._getRevision() else nil,
		viewportFrame = self.vf,
	})
	PropertyPreview.apply(cutscene, t, resolveInViewport, "viewport")
	-- 小窗克隆的关节动画(C0 偏移;克隆销毁时 restore 里 Parent 判空自然跳过)
	RigAnimPreview.apply(cutscene, t, resolveInViewport)
	self._lastMediaT = t
end

-- 开始持续更新(观察外部的 cutscene / time)。
function PreviewViewport.start(
	self: PreviewViewport,
	getCutscene: () -> CutsceneFormat.Cutscene,
	getTime: () -> number,
	getRevision: (() -> number)?
)
	self._getCutscene = getCutscene
	self._getTime = getTime
	self._getRevision = getRevision
	self:rebuild(getCutscene())
	if self._conn then
		self._conn:Disconnect()
	end
	self._conn = RunService.RenderStepped:Connect(function(stepDt: number)
		local ok, err = pcall(function()
			self:update(getCutscene(), getTime(), stepDt)
		end)
		if not ok then
			warn("[anima] 预览出错:", err)
		end
	end)
end

-- 目标集合/轨道变化后重建克隆(用当前 getter)。
function PreviewViewport.refresh(self: PreviewViewport)
	if self._getCutscene then
		self:rebuild(self._getCutscene())
	end
end

function PreviewViewport.stop(self: PreviewViewport)
	if self._conn then
		self._conn:Disconnect()
		self._conn = nil
	end
end

return PreviewViewport
