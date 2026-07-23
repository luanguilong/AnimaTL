--!strict
-- VCamPose — 求某台 vcam 在时刻 t 的相机位姿。
--   · 若存在 cameraMove 运动轨(target = 该 vcam 名)→ 采样它的关键帧(相机自己运动)
--   · 否则 → 回退静态机位 VCam.resolvePose(含 LookAt)
-- plugin 与 runtime 共用;由 CameraDirector 在独立相机轨无自身 keyframes 时调用。

local Sampler = require(script.Parent.Sampler)
local VCam = require(script.Parent.VCam)
local CutsceneFormat = require(script.Parent.CutsceneFormat)

local VCamPose = {}

function VCamPose.at(cutscene: CutsceneFormat.Cutscene, name: string, t: number): CFrame?
	for _, tr in cutscene.tracks do
		if tr.kind == "cameraMove" and tr.target == name and tr.keyframes and #tr.keyframes > 0 then
			return Sampler.sampleTrackCFrame(tr, t)
		end
	end
	return VCam.resolvePose(name)
end

return VCamPose
