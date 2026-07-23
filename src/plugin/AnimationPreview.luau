--!strict
-- AnimationPreview — 编辑期在 Model 上按时间轴 clips 定帧动画(插件预览共用)。

local CutsceneFormat = require(script.Parent.Shared.CutsceneFormat)

local AnimationPreview = {}

local _warnedLoad: { [string]: boolean } = {}
local _warnedTarget: { [string]: boolean } = {}

function AnimationPreview.normalizeAnimId(raw: string): string
	if string.find(raw, "rbxassetid://", 1, true) then
		return raw
	end
	local digits = raw:match("^(%d+)$")
	if digits then
		return "rbxassetid://" .. digits
	end
	return raw
end

export type TrackCache = { [string]: AnimationTrack }

-- LoadAnimation 在 Viewport 克隆上常失败;短暂挂到 workspace 再挂回(DevForum 通用做法)。
local HIDDEN_PREVIEW_CF = CFrame.new(0, -5000, 0)
local DEFAULT_STEP_DT = 1 / 60

-- Workspace 真身 或 PreviewViewport 内 WorldModel 克隆(不在 workspace 下)。
local function isPreviewAnimModel(model: Model): boolean
	if model:IsDescendantOf(workspace) then
		return true
	end
	local vf = model:FindFirstAncestorOfClass("ViewportFrame")
	return vf ~= nil and model:IsDescendantOf(vf)
end

local function loadPreviewTrack(animator: Animator, anim: Animation, model: Model): AnimationTrack?
	local needReparent = not model:IsDescendantOf(workspace)
	local prevParent: Instance? = nil
	local prevPivot: CFrame? = nil
	if needReparent then
		prevParent = model.Parent
		prevPivot = model:GetPivot()
		model.Parent = workspace
		model:PivotTo(HIDDEN_PREVIEW_CF)
	end
	local ok, loaded = pcall(function()
		return animator:LoadAnimation(anim)
	end)
	if needReparent and prevParent then
		if prevPivot then
			model:PivotTo(prevPivot)
		end
		model.Parent = prevParent
	end
	if not ok or not loaded then
		return nil
	end
	return loaded
end

local function stopTrack(track: AnimationTrack)
	pcall(function()
		track:Stop(0)
	end)
end

function AnimationPreview.clearCache(cache: TrackCache)
	for _, track in cache do
		stopTrack(track)
	end
	table.clear(cache)
end

-- 目标消失 / 换绑时停止该逻辑名下的预览动画(避免删人后仍播放)。
function AnimationPreview.stopBinding(cache: TrackCache, bindingName: string)
	local prefix = bindingName .. "|"
	for key, track in cache do
		if string.sub(key, 1, #prefix) == prefix then
			stopTrack(track)
			cache[key] = nil
		end
	end
end

function AnimationPreview.pruneCache(cache: TrackCache)
	for key, track in cache do
		local keep = false
		local animator = track.Parent
		if animator and animator:IsA("Animator") then
			local model = animator.Parent
			if model and model:IsA("Model") and isPreviewAnimModel(model) then
				keep = true
			end
		end
		if not keep then
			stopTrack(track)
			cache[key] = nil
		end
	end
end

-- bindingName 用于 cache key(避免多个克隆 Model 同名冲突)。
function AnimationPreview.stepClipsOnModel(
	model: Model,
	bindingName: string,
	clips: { CutsceneFormat.AnimationClip },
	t: number,
	cache: TrackCache,
	stepDt: number?
)
	local dt = stepDt or DEFAULT_STEP_DT
	if not isPreviewAnimModel(model) then
		AnimationPreview.stopBinding(cache, bindingName)
		return
	end
	local hum = model:FindFirstChildOfClass("Humanoid")
	if not hum then
		if not _warnedTarget[bindingName] then
			_warnedTarget[bindingName] = true
			warn(`[anima] 动画目标 '{bindingName}' 没有 Humanoid,无法预览动作`)
		end
		AnimationPreview.stopBinding(cache, bindingName)
		return
	end
	local animator = hum:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = hum
	end
	local activeClips = CutsceneFormat.clipsForRig(clips, hum.RigType)
	local activeAnimIds: { [string]: boolean } = {}
	for _, clip in activeClips do
		if clip.animationId == "" or clip.animationId == "rbxassetid://0" then
			continue
		end
		activeAnimIds[AnimationPreview.normalizeAnimId(clip.animationId)] = true
	end
	local prefix = bindingName .. "|"
	for key, track in cache do
		if string.sub(key, 1, #prefix) == prefix then
			local animId = string.sub(key, #prefix + 1)
			if not activeAnimIds[animId] then
				stopTrack(track)
				cache[key] = nil
			end
		end
	end
	for _, clip in activeClips do
		if clip.animationId == "" or clip.animationId == "rbxassetid://0" then
			continue
		end
		local animId = AnimationPreview.normalizeAnimId(clip.animationId)
		local key = bindingName .. "|" .. animId
		local track = cache[key]
		if not track then
			local anim = Instance.new("Animation")
			anim.AnimationId = animId
			local loaded = loadPreviewTrack(animator :: Animator, anim, model)
			if not loaded then
				if not _warnedLoad[animId] then
					_warnedLoad[animId] = true
					local rig = hum.RigType.Name
					warn(
						`[anima] 无法加载动画 {animId} (目标={bindingName}, RigType={rig})。`
							.. "请确认: rbxassetid 正确、动画与 Rig 同为 R6 或 R15、且归当前 Place 账号/群组所有"
					)
				end
				continue
			end
			track = loaded
			track.Priority = Enum.AnimationPriority.Action4
			track:Play(0, 1, 0)
			cache[key] = track
		end
		if t >= clip.startAt then
			local len = track.Length
			local pos = CutsceneFormat.clipTimePositionAt(clip, t, if len > 0 then len else 0)
			if len > 0 and not clip.endAt and not clip.looped then
				pos = math.clamp(pos, 0, len)
			end
			track.TimePosition = pos
		else
			track.TimePosition = 0
		end
	end
	-- ViewportFrame/WorldModel 内不会自动推进 Animator,需手动 Step 才看得见定帧。
	pcall(function()
		(animator :: Animator):StepAnimations(dt)
	end)
end

return AnimationPreview
