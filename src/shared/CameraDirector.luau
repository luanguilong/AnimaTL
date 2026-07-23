--!strict
-- CameraDirector — 每相机独立轨模型:求 t 时刻该用哪台相机的位姿。
--   1) 覆盖 t 的 camera 轨(from<=t<=to)中取"时间轴最上层"(tracks 数组索引最小)那条上镜;
--      有自身 keyframes 则采样其运动(smooth 决定直线/曲线);否则回退 VCamPose.at
--      (若该 vcam 有 cameraMove 运动轨则采样之、否则静态机位)。
--   2) 回退兼容:无区间(无 from/to)的老 camera keyframes。
-- plugin 与 runtime 共用。

local Sampler = require(script.Parent.Sampler)
local VCamPose = require(script.Parent.VCamPose)
local CutsceneFormat = require(script.Parent.CutsceneFormat)
local FollowAnchor = require(script.Parent.FollowAnchor)

local CameraDirector = {}

-- 单条 camera 轨在 t 的世界位姿(不比较轨层级;段外返回 nil)。
function CameraDirector.poseForCameraTrack(
	cutscene: CutsceneFormat.Cutscene,
	tr: CutsceneFormat.Track,
	t: number,
	resolveBinding: CutsceneFormat.BindingResolver?
): CFrame?
	if tr.kind ~= "camera" or not CutsceneFormat.coversAt(tr, t) then
		return nil
	end
	if tr.keyframes and #tr.keyframes > 0 then
		local stored = Sampler.sampleTrackCFrame(tr, t)
		if stored and resolveBinding then
			return FollowAnchor.worldFromKeyframeCFrame(tr, stored, resolveBinding)
		end
		return stored
	end
	return VCamPose.at(cutscene, tr.target, t)
end

-- 返回 (相机 CFrame, 上镜相机名)。找不到返回 (nil, nil)。
function CameraDirector.evaluate(
	cutscene: CutsceneFormat.Cutscene,
	t: number,
	resolveBinding: CutsceneFormat.BindingResolver?
): (CFrame?, string?)
	-- 1) 覆盖 t 的独立相机轨(落在任一生效段内),层级最高(索引最小)那条
	local best: CutsceneFormat.Track? = nil
	local bestIdx: number? = nil
	for i, tr in cutscene.tracks do
		if tr.kind == "camera" and CutsceneFormat.coversAt(tr, t) then
			if not bestIdx or i < bestIdx then
				best, bestIdx = tr, i
			end
		end
	end
	if best then
		local cf = CameraDirector.poseForCameraTrack(cutscene, best, t, resolveBinding)
		if cf then
			return cf, best.target
		end
		return VCamPose.at(cutscene, best.target, t), best.target
	end

	-- 2) 回退:无生效段的老 camera keyframes(早期直接录 CFrame 的相机轨,如 boss_intro)
	for _, tr in cutscene.tracks do
		if
			tr.kind == "camera"
			and #CutsceneFormat.segmentsOf(tr) == 0
			and tr.keyframes
			and #tr.keyframes > 0
		then
			local stored = Sampler.sampleCFrame(tr.keyframes, t)
			if stored and resolveBinding then
				return FollowAnchor.worldFromKeyframeCFrame(tr, stored, resolveBinding), nil
			end
			return stored, nil
		end
	end

	return nil, nil
end

return CameraDirector
