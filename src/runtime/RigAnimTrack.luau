--!strict
-- RigAnimTrack — Moon 导入的关节动画:逐帧把各 Motor6D.Transform 设为关键帧插值(20 spec)。
-- Transform 是运行时瞬态属性(不序列化进 place),stop 归 identity 即还原。

local Sampler = require(script.Parent.Parent.Shared.Sampler)
local CutsceneFormat = require(script.Parent.Parent.Shared.CutsceneFormat)

local RigAnimTrack = {}
RigAnimTrack.__index = RigAnimTrack

type BoundJoint = {
	motor: Motor6D,
	keyframes: { CutsceneFormat.Keyframe },
}

export type RigAnimTrack = typeof(setmetatable(
	{} :: {
		_joints: { BoundJoint },
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
	return setmetatable({ _joints = joints }, RigAnimTrack)
end

function RigAnimTrack.update(self: RigAnimTrack, t: number)
	for _, j in self._joints do
		if not j.motor.Parent then
			continue
		end
		local cf = Sampler.sampleCFrame(j.keyframes, t)
		if cf then
			j.motor.Transform = cf
		end
	end
end

function RigAnimTrack.stop(self: RigAnimTrack)
	for _, j in self._joints do
		if j.motor.Parent then
			j.motor.Transform = CFrame.identity
		end
	end
end

return RigAnimTrack
