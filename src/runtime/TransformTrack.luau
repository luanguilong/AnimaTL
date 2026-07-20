--!strict
-- TransformTrack — 逐帧把目标(门/Boss 等)的 CFrame 设为关键帧插值结果。
-- 目标可为 BasePart 或 Model(Model 用 PivotTo)。

local Sampler = require(script.Parent.Parent.Shared.Sampler)
local CutsceneFormat = require(script.Parent.Parent.Shared.CutsceneFormat)

local TransformTrack = {}
TransformTrack.__index = TransformTrack

export type TransformTrack = typeof(setmetatable(
	{} :: {
		keyframes: { CutsceneFormat.Keyframe },
		target: Instance,
	},
	TransformTrack
))

function TransformTrack.new(track: CutsceneFormat.Track, target: Instance): TransformTrack
	return setmetatable({
		keyframes = track.keyframes or {},
		target = target,
	}, TransformTrack)
end

local function applyCFrame(target: Instance, cf: CFrame)
	if target:IsA("BasePart") then
		target.CFrame = cf
	elseif target:IsA("Model") then
		target:PivotTo(cf)
	end
end

function TransformTrack.update(self: TransformTrack, t: number)
	local cf = Sampler.sampleCFrame(self.keyframes, t)
	if cf then
		applyCFrame(self.target, cf)
	end
end

return TransformTrack
