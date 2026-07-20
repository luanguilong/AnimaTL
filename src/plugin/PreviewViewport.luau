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
		_animTracks: { [string]: AnimationTrack }, -- "target|animId" -> 定帧用 track
		_conn: RBXScriptConnection?,
		_getCutscene: (() -> CutsceneFormat.Cutscene)?,
		_getTime: (() -> number)?,
	},
	PreviewViewport
))

-- 克隆进预览世界(去脚本、全锚定)。
local function makeClone(inst: Instance): Instance
	local clone = inst:Clone()
	for _, d in clone:GetDescendants() do
		if d:IsA("BaseScript") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = true
		end
	end
	if clone:IsA("BasePart") then
		clone.Anchored = true
	end
	return clone
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
	cam.Parent = vf
	vf.CurrentCamera = cam

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
	}, PreviewViewport)
end

-- 收集过场涉及的目标名(transform / animation / vcam LookAt)。
local function collectTargets(cutscene: CutsceneFormat.Cutscene): { string }
	local set: { [string]: boolean } = {}
	for _, track in cutscene.tracks do
		if track.kind == "transform" or track.kind == "animation" then
			set[track.target] = true
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

-- 依据过场重建克隆集合(目标 + 地面参考)。
function PreviewViewport.rebuild(self: PreviewViewport, cutscene: CutsceneFormat.Cutscene)
	for _, c in self._clones do
		c:Destroy()
	end
	self._clones = {}
	self._animTracks = {} -- 旧 AnimationTrack 随旧克隆的 Animator 失效
	if self._ground then
		self._ground:Destroy()
		self._ground = nil
	end

	for _, name in collectTargets(cutscene) do
		local inst = SceneResolver.resolve(name)
		if inst and (inst:IsA("BasePart") or inst:IsA("Model")) then
			local clone = makeClone(inst)
			clone.Parent = self.world
			self._clones[name] = clone
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
local function evalCamera(cutscene: CutsceneFormat.Cutscene, t: number): (CFrame?, number?, string?)
	local cf, name = CameraDirector.evaluate(cutscene, t)
	local fov: number? = nil
	if name then
		local part = VCam.find(name)
		local f = part and part:GetAttribute("FOV")
		if typeof(f) == "number" then
			fov = f
		end
	end
	return cf, fov, name
end

-- 取(或建)克隆角色上某 animationId 的定帧 AnimationTrack。无 Humanoid/加载失败返回 nil。
local function getAnimTrack(self: PreviewViewport, clone: Instance, animId: string): AnimationTrack?
	local key = clone.Name .. "|" .. animId
	local existing = self._animTracks[key]
	if existing then
		return existing
	end
	if not clone:IsA("Model") then
		return nil
	end
	local hum = clone:FindFirstChildOfClass("Humanoid")
	if not hum then
		return nil
	end
	local animator = hum:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = hum
	end
	local anim = Instance.new("Animation")
	anim.AnimationId = animId
	local ok, track = pcall(function()
		return (animator :: Animator):LoadAnimation(anim)
	end)
	if not ok or not track then
		return nil
	end
	track:Play()
	track:AdjustSpeed(0) -- 冻结,靠 TimePosition 定帧(scrub 时定格到对应帧)
	self._animTracks[key] = track
	return track
end

-- 更新一帧:相机 + transform 克隆 + 动画定帧 + 信息叠加。
function PreviewViewport.update(self: PreviewViewport, cutscene: CutsceneFormat.Cutscene, t: number)
	local camCF, fov, active = evalCamera(cutscene, t)
	if camCF then
		self.cam.CFrame = camCF
	end
	self.cam.FieldOfView = fov or 70
	self.info.Text =
		string.format("🎥 %s · FOV %d · %.2fs", active or "—", math.floor(fov or 70), t)

	for _, track in cutscene.tracks do
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

	-- 动画轨:在克隆角色上按 (t - startAt) 定帧(无效/未加载 id 静默跳过)
	for _, track in cutscene.tracks do
		if track.kind == "animation" and track.clips then
			local clone = self._clones[track.target]
			if clone then
				for _, clip in track.clips do
					if clip.animationId ~= "" and clip.animationId ~= "rbxassetid://0" then
						local at = getAnimTrack(self, clone, clip.animationId)
						if at then
							if t >= clip.startAt then
								local pos = (t - clip.startAt) * (clip.speed or 1)
								local len = at.Length
								if len > 0 then
									if clip.looped then
										pos %= len
									else
										pos = math.clamp(pos, 0, len)
									end
								end
								at.TimePosition = pos
							else
								at.TimePosition = 0
							end
						end
					end
				end
			end
		end
	end
end

-- 开始持续更新(观察外部的 cutscene / time)。
function PreviewViewport.start(
	self: PreviewViewport,
	getCutscene: () -> CutsceneFormat.Cutscene,
	getTime: () -> number
)
	self._getCutscene = getCutscene
	self._getTime = getTime
	self:rebuild(getCutscene())
	if self._conn then
		self._conn:Disconnect()
	end
	self._conn = RunService.RenderStepped:Connect(function()
		local ok, err = pcall(function()
			self:update(getCutscene(), getTime())
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
