--!strict
-- Preview — scrub 时把过场在时间 t 的求值结果应用到编辑器场景。
-- 复用 runtime 的 Sampler(编辑&运行时同一套求值,保证所见即所得)。
--
-- camera:设 workspace.CurrentCamera.CFrame(编辑器视角随播放头移动)。
-- transform:门/Boss 等仍在 Workspace;带 Humanoid 的角色只在 PreviewViewport 克隆上预览(避免真身+多克隆叠影)。

local Sampler = require(script.Parent.Shared.Sampler)
local CutsceneFormat = require(script.Parent.Shared.CutsceneFormat)
local SceneResolver = require(script.Parent.SceneResolver)
local AnimationPreview = require(script.Parent.AnimationPreview)
local MediaPreview = require(script.Parent.MediaPreview)
local PropertyPreview = require(script.Parent.PropertyPreview)
local RigAnimPreview = require(script.Parent.RigAnimPreview)

local Preview = {}

local resolve = SceneResolver.resolve
local _animCache: AnimationPreview.TrackCache = {}
local _lastPreviewT = 0

-- 面板内 Viewport 预览开启时,音效/特效改在克隆上播,避免只打 Workspace 真身。
-- 小窗预览开启时仍单独推进 Workspace 特效(主视口可见)。
Preview.skipWorkspaceMedia = false
Preview.cutsceneRevision = 0
local _lastPreviewWsFxT = 0

local function isCharacterModel(inst: Instance): boolean
	return inst:IsA("Model") and inst:FindFirstChildOfClass("Humanoid") ~= nil
end

local function applyCFrame(target: Instance, cf: CFrame)
	if target:IsA("BasePart") or target:IsA("Camera") then
		(target :: any).CFrame = cf
	elseif target:IsA("Model") then
		target:PivotTo(cf)
	end
end

function Preview.clearAnimationCache()
	AnimationPreview.clearCache(_animCache)
	MediaPreview.reset()
	PropertyPreview.restore()
	RigAnimPreview.restore()
	_lastPreviewT = 0
	_lastPreviewWsFxT = 0
end

-- 在时间 t 应用一帧预览。includeCamera=false 时不动相机(避免抢视角)。
function Preview.applyAt(cutscene: CutsceneFormat.Cutscene, t: number, includeCamera: boolean)
	if Preview.skipWorkspaceMedia then
		MediaPreview.step(cutscene, t, _lastPreviewWsFxT, SceneResolver.resolve, "workspace-effects", {
			kinds = { effect = true },
			cutsceneRevision = Preview.cutsceneRevision,
		})
		_lastPreviewWsFxT = t
	end
	if not Preview.skipWorkspaceMedia then
		MediaPreview.step(cutscene, t, _lastPreviewT, nil, "workspace", {
			cutsceneRevision = Preview.cutsceneRevision,
		})
	end
	PropertyPreview.apply(cutscene, t, resolve, "workspace")
	RigAnimPreview.apply(cutscene, t, resolve)
	_lastPreviewT = t
	AnimationPreview.pruneCache(_animCache)
	for _, track in cutscene.tracks do
		if track.hidden then
			continue
		end
		if (track.kind == "camera" and includeCamera) or track.kind == "transform" then
			if track.keyframes and #track.keyframes > 0 then
				local cf = Sampler.sampleCFrame(track.keyframes, t)
				if cf then
					local target = resolve(track.target)
					if target and target:IsDescendantOf(workspace) and not isCharacterModel(target) then
						applyCFrame(target, cf)
					end
				end
			end
		end
	end
	for _, track in cutscene.tracks do
		if track.kind == "animation" and track.clips and not track.hidden then
			local target = resolve(track.target)
			if target and target:IsA("Model") and target:IsDescendantOf(workspace) then
				if isCharacterModel(target) then
					AnimationPreview.stopBinding(_animCache, track.target)
					continue
				end
				AnimationPreview.stepClipsOnModel(target, track.target, track.clips, t, _animCache)
			else
				AnimationPreview.stopBinding(_animCache, track.target)
			end
		end
	end
end

return Preview
