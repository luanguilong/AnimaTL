--!strict
-- Preview — scrub 时把过场在时间 t 的求值结果应用到编辑器场景。
-- 复用 runtime 的 Sampler(编辑&运行时同一套求值,保证所见即所得)。
--
-- camera:设 workspace.CurrentCamera.CFrame(编辑器视角随播放头移动)。
-- transform:按 target 名在 workspace 找物体,设其 CFrame/Pivot。

local Sampler = require(script.Parent.Shared.Sampler)
local CutsceneFormat = require(script.Parent.Shared.CutsceneFormat)
local SceneResolver = require(script.Parent.SceneResolver)

local Preview = {}

local resolve = SceneResolver.resolve

local function applyCFrame(target: Instance, cf: CFrame)
	if target:IsA("BasePart") or target:IsA("Camera") then
		(target :: any).CFrame = cf
	elseif target:IsA("Model") then
		target:PivotTo(cf)
	end
end

-- 在时间 t 应用一帧预览。includeCamera=false 时不动相机(避免抢视角)。
function Preview.applyAt(cutscene: CutsceneFormat.Cutscene, t: number, includeCamera: boolean)
	for _, track in cutscene.tracks do
		if (track.kind == "camera" and includeCamera) or track.kind == "transform" then
			if track.keyframes and #track.keyframes > 0 then
				local cf = Sampler.sampleCFrame(track.keyframes, t)
				if cf then
					local target = resolve(track.target)
					if target then
						applyCFrame(target, cf)
					end
				end
			end
		end
	end
end

return Preview
