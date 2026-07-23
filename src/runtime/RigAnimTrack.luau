--!strict
-- RigAnimTrack — Moon 导入的关节动画:逐帧把各 Motor6D.Transform 设为关键帧插值(20 spec)。
-- Transform 是运行时瞬态属性(不序列化进 place),stop 归 identity 即还原。

local RunService = game:GetService("RunService")

local Sampler = require(script.Parent.Parent.Shared.Sampler)
local CutsceneFormat = require(script.Parent.Parent.Shared.CutsceneFormat)

local RigAnimTrack = {}
RigAnimTrack.__index = RigAnimTrack

type BoundJoint = {
	motor: Motor6D,
	keyframes: { CutsceneFormat.Keyframe },
	current: CFrame?,
}

export type RigAnimTrack = typeof(setmetatable(
	{} :: {
		_joints: { BoundJoint },
		_target: Instance,
		_began: boolean,
		_disabledAnimate: LocalScript?,
		_steppedConn: RBXScriptConnection?,
	},
	RigAnimTrack
))

local function pathTail(path: string): string
	local segs = string.split(path, ".")
	return segs[#segs] or path
end

-- 目标 Model 内按 Part1 名找 Motor6D(R6 内唯一)。
local function findMotor(target: Instance, part1Name: string): Motor6D?
	for _, d in target:GetDescendants() do
		if d:IsA("Motor6D") and d.Part1 and d.Part1.Name == part1Name then
			return d
		end
	end
	return nil
end

function RigAnimTrack.new(track: CutsceneFormat.Track, target: Instance): RigAnimTrack?
	local jointTracks = track.jointTracks
	if not jointTracks or #jointTracks == 0 then
		return nil
	end
	local joints: { BoundJoint } = {}
	for _, jt in jointTracks do
		local motor = findMotor(target, pathTail(jt.path))
		if motor then
			table.insert(joints, { motor = motor, keyframes = jt.keyframes })
		else
			warn(`[anima] rigAnim:'{target.Name}' 内找不到关节 '{jt.path}'(按 Part1 名匹配),跳过`)
		end
	end
	if #joints == 0 then
		warn(`[anima] rigAnim 轨道 '{track.target}' 无可绑定关节`)
		return nil
	end
	return setmetatable({
		_joints = joints,
		_target = target,
		_began = false,
		_disabledAnimate = nil,
		_steppedConn = nil,
	}, RigAnimTrack)
end

-- 角色自带 Animate/Animator 每帧覆盖 Transform,rigAnim 生效期间必须压制:
-- 禁用 Animate 脚本 + 停掉在播动画轨;stop 时恢复。
local function suppressCharacterAnimations(self: RigAnimTrack)
	local animate = self._target:FindFirstChild("Animate")
	if animate and animate:IsA("LocalScript") and not animate.Disabled then
		animate.Disabled = true
		self._disabledAnimate = animate
	end
	local hum = self._target:FindFirstChildOfClass("Humanoid")
	local animator = hum and hum:FindFirstChildOfClass("Animator")
	if animator then
		for _, tr in animator:GetPlayingAnimationTracks() do
			pcall(function()
				tr:Stop(0)
			end)
		end
	end
end

function RigAnimTrack.update(self: RigAnimTrack, t: number)
	if not self._began then
		self._began = true
		suppressCharacterAnimations(self)
		-- 关键:Transform 只有在"动画阶段之后、物理之前"(Stepped 窗口)写入才被
		-- 物理应用;其余时机都会被 Animator 每帧扫写冲掉。故采样值缓存在 current,
		-- 由 Stepped 统一落地。
		self._steppedConn = RunService.Stepped:Connect(function()
			for _, j in self._joints do
				if j.current and j.motor.Parent then
					j.motor.Transform = j.current :: CFrame
				end
			end
		end)
	end
	for _, j in self._joints do
		j.current = Sampler.sampleCFrame(j.keyframes, t)
	end
end

function RigAnimTrack.stop(self: RigAnimTrack)
	if self._steppedConn then
		self._steppedConn:Disconnect()
		self._steppedConn = nil
	end
	for _, j in self._joints do
		j.current = nil
		if j.motor.Parent then
			j.motor.Transform = CFrame.identity
		end
	end
	self._began = false
	if self._disabledAnimate and self._disabledAnimate.Parent then
		self._disabledAnimate.Disabled = false
		self._disabledAnimate = nil
	end
end

return RigAnimTrack
