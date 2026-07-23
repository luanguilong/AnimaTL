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
		warn("[anima] 无法解析动画长度:场景中没有带 Humanoid 的 Model,请先放入角色或选中 Rig")
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
	local len = track.Length
	pcall(function()
		track:Stop(0)
	end)
	if len <= 0 then
		return nil
	end
	lengthCache[key] = len
	return len
end

function AnimationAsset.clearCache()
	table.clear(lengthCache)
end

return AnimationAsset
