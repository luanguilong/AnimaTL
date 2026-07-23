--!strict
-- RigAnimPreview — 编辑 scrub 时把 rigAnim 轨(Moon 关节动画)应用到场景 rig(20 spec)。
-- Motor6D.Transform 是运行时瞬态属性(不落盘),restore 归 identity 即干净。

local Sampler = require(script.Parent.Shared.Sampler)
local CutsceneFormat = require(script.Parent.Shared.CutsceneFormat)

local RigAnimPreview = {}

local _touched: { [Motor6D]: boolean } = {}
local _warnedJoint: { [string]: boolean } = {}

local function pathTail(path: string): string
	local segs = string.split(path, ".")
	return segs[#segs] or path
end

local function findMotor(target: Instance, part1Name: string): Motor6D?
	for _, d in target:GetDescendants() do
		if d:IsA("Motor6D") and d.Part1 and d.Part1.Name == part1Name then
			return d
		end
	end
	return nil
end

function RigAnimPreview.apply(
	cutscene: CutsceneFormat.Cutscene,
	t: number,
	resolveBinding: CutsceneFormat.BindingResolver
)
	for _, track in cutscene.tracks do
		if track.kind ~= "rigAnim" or track.hidden or not track.jointTracks then
			continue
		end
		local target = resolveBinding(track.target)
		if not target then
			continue
		end
		for _, jt in track.jointTracks do
			local motor = findMotor(target, pathTail(jt.path))
			if not motor then
				local key = track.target .. "|" .. jt.path
				if not _warnedJoint[key] then
					_warnedJoint[key] = true
					warn(`[anima] rigAnim 预览:'{track.target}' 内找不到关节 '{jt.path}'`)
				end
				continue
			end
			local cf = Sampler.sampleCFrame(jt.keyframes, t)
			if cf then
				_touched[motor] = true
				motor.Transform = cf
			end
		end
	end
end

function RigAnimPreview.restore()
	for motor in _touched do
		if motor.Parent then
			motor.Transform = CFrame.identity
		end
	end
	table.clear(_touched)
end

return RigAnimPreview
