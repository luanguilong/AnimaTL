--!strict
-- AnimationAsset — Studio 插件内解析 AnimationId 源时长(Length),带缓存。

local AnimationPreview = require(script.Parent.AnimationPreview)
local CutsceneFormat = require(script.Parent.Shared.CutsceneFormat)

local AnimationAsset = {}

local lengthCache: { [string]: number } = {}

local HIDDEN_PREVIEW_CF = CFrame.new(0, -5000, 0)

local function cacheKey(animId: string, rigName: string): string
	return rigName .. "|" .. animId
end

local function findHumanoidModel(preferRig: Enum.HumanoidRigType?): Model?
	local best: Model? = nil
	for _, inst in workspace:GetDescendants() do
		if inst:IsA("Model") then
			local hum = inst:FindFirstChildOfClass("Humanoid")
			if hum then
				if preferRig and hum.RigType == preferRig then
					return inst
				end
				if not best then
					best = inst
				end
			end
		end
	end
	return best
end

local function rigTypeFromClip(clip: CutsceneFormat.AnimationClip?): Enum.HumanoidRigType?
	if not clip or not clip.rigType then
		return nil
	end
	if clip.rigType == "R6" then
		return Enum.HumanoidRigType.R6
	end
	return Enum.HumanoidRigType.R15
end

export type ResolveOpts = {
	clip: CutsceneFormat.AnimationClip?,
	model: Model?,
}

-- 返回源动画 Length(秒);失败 nil。优先 opts.model,否则 workspace 内带 Humanoid 的 Model。
function AnimationAsset.resolveSourceLength(animationId: string, opts: ResolveOpts?): number?
	local raw = animationId
	if raw == "" or raw == "rbxassetid://0" then
		return nil
	end
	local animId = AnimationPreview.normalizeAnimId(raw)
	local preferRig = if opts and opts.clip then rigTypeFromClip(opts.clip) else nil
	local rigName = if preferRig then preferRig.Name else "Any"
	local key = cacheKey(animId, rigName)
	local cached = lengthCache[key]
	if cached then
		return cached
	end

	local model = if opts and opts.model then opts.model else findHumanoidModel(preferRig)
	if not model then
		warn(
			"[anima] 无法解析动画长度:场景中没有带 Humanoid 的 Model,请先放入角色或选中 Rig"
		)
		return nil
	end
	local hum = model:FindFirstChildOfClass("Humanoid")
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
	local needReparent = not model:IsDescendantOf(workspace)
	local prevParent = model.Parent
	local prevPivot = model:GetPivot()
	if needReparent then
		model.Parent = workspace
		model:PivotTo(HIDDEN_PREVIEW_CF)
	end
	local ok, track = pcall(function()
		return (animator :: Animator):LoadAnimation(anim)
	end)
	if needReparent then
		model:PivotTo(prevPivot)
		model.Parent = prevParent
	end
	if not ok or not track then
		return nil
	end
	-- Length 在 KeyframeSequence 未下载完成时为 0:有界等待(18 spec)
	local len = track.Length
	local waited = 0
	while len <= 0 and waited < 3 do
		task.wait(0.1)
		waited += 0.1
		len = track.Length
	end
	pcall(function()
		track:Stop(0)
	end)
	if len <= 0 then
		return nil
	end
	lengthCache[key] = len
	return len
end

-- 只查缓存,不触发解析(UI 每帧调用安全)。
function AnimationAsset.cachedLength(
	animationId: string,
	clip: CutsceneFormat.AnimationClip?
): number?
	if animationId == "" or animationId == "rbxassetid://0" then
		return nil
	end
	local animId = AnimationPreview.normalizeAnimId(animationId)
	local preferRig = rigTypeFromClip(clip)
	local rigName = if preferRig then preferRig.Name else "Any"
	return lengthCache[cacheKey(animId, rigName)]
end

local _prefetching = false

-- 后台解析过场里所有 clip 的源时长(缓存命中/无效 id 跳过)。
-- 有任何新解析成功时调用一次 onResolved(调用方借此重绘时间轴宽度)。
function AnimationAsset.prefetchCutscene(cutscene: CutsceneFormat.Cutscene, onResolved: (() -> ())?)
	if _prefetching then
		return
	end
	_prefetching = true
	task.spawn(function()
		local resolvedAny = false
		for _, tr in cutscene.tracks do
			if tr.kind ~= "animation" or not tr.clips then
				continue
			end
			for _, clip in tr.clips do
				if AnimationAsset.cachedLength(clip.animationId, clip) then
					continue
				end
				if AnimationAsset.resolveSourceLength(clip.animationId, { clip = clip }) then
					resolvedAny = true
				end
			end
		end
		_prefetching = false
		if resolvedAny and onResolved then
			onResolved()
		end
	end)
end

function AnimationAsset.clearCache()
	table.clear(lengthCache)
end

return AnimationAsset
