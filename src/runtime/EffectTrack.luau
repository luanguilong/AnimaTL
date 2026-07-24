--!strict
-- EffectTrack — 到点触发特效 cue;stop 时清理克隆体 / Forge Clear。

local Debris = game:GetService("Debris")
local InsertService = game:GetService("InsertService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CutsceneFormat = require(script.Parent.Parent.Shared.CutsceneFormat)
local ForgeEffectPlay = require(script.Parent.Parent.Shared.ForgeEffectPlay)
local AnimaAssets = require(script.Parent.Parent.Shared.AnimaAssets)
local ForgeApproxFx = require(script.Parent.ForgeApproxFx)

local ViewportFxFeedback: any = nil
do
	local plug = script.Parent.Parent
	local mod = plug:FindFirstChild("ViewportFxFeedback")
	if mod and mod:IsA("ModuleScript") then
		ViewportFxFeedback = require(mod)
	end
end

local EffectTrack = {}
EffectTrack.__index = EffectTrack

export type EffectCueHandler = (cue: CutsceneFormat.EffectCue, target: Instance?) -> Instance?

type EditorForgeRestore = {
	inst: Instance,
	enabled: boolean,
}

export type EffectTrack = typeof(setmetatable(
	{} :: {
		cues: { CutsceneFormat.EffectCue },
		target: Instance?,
		handler: EffectCueHandler,
		_fired: { [number]: boolean },
		_spawned: { Instance },
		_forgeClears: { () -> () },
		_editorForgeRestore: { EditorForgeRestore },
		_editorDelayToken: number,
		_workspaceMirror: Instance?,
		_viewportFrame: ViewportFrame?,
	},
	EffectTrack
))

local function normalizeAssetId(raw: string): string
	if string.find(raw, "rbxassetid://", 1, true) then
		return raw
	end
	local digits = raw:match("^(%d+)$")
	if digits then
		return "rbxassetid://" .. digits
	end
	return raw
end

local function emitOnTarget(target: Instance?, templateName: string, emitCount: number)
	if not target then
		return
	end
	local node = target:FindFirstChild(templateName, true)
	if node and node:IsA("ParticleEmitter") then
		node:Emit(emitCount)
	end
end

local function defaultParentForEffect(target: Instance?): Instance
	if not target then
		return workspace
	end
	if target:IsA("BasePart") or target:IsA("Attachment") then
		return target
	end
	if target:IsA("Model") then
		local part = target.PrimaryPart or target:FindFirstChildWhichIsA("BasePart", true)
		if part then
			return part
		end
	end
	return workspace
end

local function resolveForgeEmitRoot(target: Instance?, forgeRoot: string?): Instance?
	if not target then
		return nil
	end
	if forgeRoot and forgeRoot ~= "" then
		return target:FindFirstChild(forgeRoot, true)
	end
	return target
end

function EffectTrack.particleHandler(cue: CutsceneFormat.EffectCue, target: Instance?): Instance?
	local emitCount = cue.emitCount or 1
	if cue.templateName and cue.templateName ~= "" then
		emitOnTarget(target, cue.templateName, emitCount)
		return nil
	end
	if
		cue.particleAssetId
		and cue.particleAssetId ~= ""
		and cue.particleAssetId ~= "rbxassetid://0"
	then
		local id = normalizeAssetId(cue.particleAssetId)
		local ok, asset = pcall(function()
			return InsertService:LoadAsset(tonumber(id:match("%d+")) or 0)
		end)
		if not ok or not asset then
			warn(`[anima] EffectTrack:无法加载粒子资源 {id}`)
			return nil
		end
		local emitter = asset:FindFirstChildWhichIsA("ParticleEmitter", true)
		if not emitter then
			asset:Destroy()
			warn(`[anima] EffectTrack:资源 {id} 内无 ParticleEmitter`)
			return nil
		end
		local clone = emitter:Clone()
		clone.Parent = defaultParentForEffect(target)
		clone:Emit(emitCount)
		local life = cue.duration or 3
		Debris:AddItem(clone, life)
		asset:Destroy()
		return clone
	end
	return nil
end

function EffectTrack.defaultHandler(cue: CutsceneFormat.EffectCue, target: Instance?): Instance?
	return EffectTrack.particleHandler(cue, target)
end

local EDITOR_FORGE_DEFAULT_EMIT = 24
local EDITOR_FORGE_BEAM_FLASH = 0.5

-- 记录原始 Enabled 以便 scrub 停止时还原;同一实例只记第一次(避免记到预览态)。
local function rememberForgeEnabled(track: EffectTrack, inst: Instance)
	if not (inst:IsA("ParticleEmitter") or inst:IsA("Beam") or inst:IsA("Trail")) then
		return
	end
	for _, entry in track._editorForgeRestore do
		if entry.inst == inst then
			return
		end
	end
	table.insert(track._editorForgeRestore, {
		inst = inst,
		enabled = (inst :: any).Enabled,
	})
end

local function forgeAttrNumber(inst: Instance, name: string): number?
	local v = inst:GetAttribute(name)
	if typeof(v) == "number" then
		return v
	end
	return nil
end

local function forgeApproxOpts(track: EffectTrack, token: number): ForgeApproxFx.EmitOpts
	return {
		isLive = function()
			return token == track._editorDelayToken
		end,
		addCleanup = function(fn: () -> ())
			table.insert(track._forgeClears, fn)
		end,
	}
end

local function insideViewport(inst: Instance): boolean
	return inst:FindFirstAncestorOfClass("ViewportFrame") ~= nil
end

-- 编辑期按 forge-vfx 属性约定逐实例回放(不 require 官方模块,遵守 VFX-DL):
-- ParticleEmitter:EmitDelay 后,若 EmitDuration>0 临时 Enabled 该时长,再 Emit(EmitCount)。
-- Beam:EmitDelay 后临时 Enabled(EmitDuration 或默认 0.5s)。Trail:Enabled 至 scrub 停止。
local function forgeEditorEmitInstance(
	track: EffectTrack,
	inst: Instance,
	token: number,
	fallbackCount: number
)
	local delay = forgeAttrNumber(inst, "EmitDelay") or 0

	if inst:IsA("ParticleEmitter") then
		local count = math.floor(forgeAttrNumber(inst, "EmitCount") or fallbackCount)
		local duration = forgeAttrNumber(inst, "EmitDuration") or 0
		if count <= 0 and duration <= 0 then
			return
		end
		local function fire()
			if token ~= track._editorDelayToken or not inst.Parent then
				return
			end
			if duration > 0 then
				rememberForgeEnabled(track, inst)
				inst.Enabled = true
				task.delay(duration, function()
					if token == track._editorDelayToken and inst.Parent then
						inst.Enabled = false
					end
				end)
			end
			if count > 0 then
				inst:Emit(count)
			end
			-- 小窗:真粒子渲染不了,用贴图面片模拟(持续型按 Rate×时长折算数量)
			if insideViewport(inst) then
				local simCount = if count > 0
					then count
					else math.min(30, math.max(1, math.floor(inst.Rate * duration)))
				ForgeApproxFx.simulateEmitterBurst(inst, simCount, forgeApproxOpts(track, token))
			end
		end
		if delay > 0 then
			task.delay(delay, fire)
		else
			fire()
		end
	elseif inst:IsA("Beam") then
		local duration = forgeAttrNumber(inst, "EmitDuration") or EDITOR_FORGE_BEAM_FLASH
		local function fire()
			if token ~= track._editorDelayToken or not inst.Parent then
				return
			end
			rememberForgeEnabled(track, inst)
			inst.Enabled = true
			task.delay(duration, function()
				if token == track._editorDelayToken and inst.Parent then
					inst.Enabled = false
				end
			end)
			-- 小窗:Beam 渲染不了,附着点之间拉贴图长条模拟
			if insideViewport(inst) then
				ForgeApproxFx.simulateBeamFlash(inst, duration, forgeApproxOpts(track, token))
			end
		end
		if delay > 0 then
			task.delay(delay, fire)
		else
			fire()
		end
	elseif inst:IsA("Trail") then
		rememberForgeEnabled(track, inst)
		inst.Enabled = true
	elseif inst:IsA("Sound") then
		local count = forgeAttrNumber(inst, "EmitCount") or 1
		if count <= 0 then
			return
		end
		local function fire()
			if token ~= track._editorDelayToken or not inst.Parent then
				return
			end
			pcall(function()
				inst:Play()
			end)
		end
		if delay > 0 then
			task.delay(delay, fire)
		else
			fire()
		end
	end
end

local function forgeEditorBurstOnRoot(track: EffectTrack, root: Instance, fallbackCount: number)
	local token = track._editorDelayToken
	local approxOpts: ForgeApproxFx.EmitOpts = {
		isLive = function()
			return token == track._editorDelayToken
		end,
		addCleanup = function(fn: () -> ())
			table.insert(track._forgeClears, fn)
		end,
		onSpawn = function(clone: BasePart)
			table.insert(track._spawned, clone)
			-- 克隆里的粒子随克隆一起触发(主视口可见;小窗渲染不了粒子)
			for _, desc in clone:GetDescendants() do
				forgeEditorEmitInstance(track, desc, token, fallbackCount)
			end
		end,
	}
	-- mesh 特效子树整棵交给克隆动画承载(小窗可渲染);RayValue 走属性 tweener。
	local function walk(inst: Instance)
		if ForgeApproxFx.isMeshVfx(inst) then
			ForgeApproxFx.emitMesh(inst :: Model, approxOpts)
			return
		end
		if inst:IsA("RayValue") then
			ForgeApproxFx.emitTweener(inst, approxOpts)
			return
		end
		forgeEditorEmitInstance(track, inst, token, fallbackCount)
		for _, c in inst:GetChildren() do
			walk(c)
		end
	end
	walk(root)
end

local function viewportForgeFlash(root: Instance)
	if not root:IsA("Instance") then
		return
	end
	if not root:FindFirstAncestorOfClass("ViewportFrame") then
		return
	end
	local anchor = if root:IsA("BasePart")
		then root
		else root:FindFirstChildWhichIsA("BasePart", true)
	if not anchor then
		return
	end
	local world = root:FindFirstAncestorOfClass("WorldModel") or root.Parent
	if not world then
		return
	end
	local flash = Instance.new("Part")
	flash.Name = "AnimaForgePreviewFlash"
	flash.Anchored = true
	flash.CanCollide = false
	flash.CanQuery = false
	flash.CastShadow = false
	flash.Material = Enum.Material.Neon
	flash.Color = Color3.fromRGB(255, 140, 60)
	flash.Size = Vector3.new(2.5, 2.5, 2.5)
	flash.CFrame = anchor.CFrame
	flash.Transparency = 0.15
	flash.Parent = world
	local light = Instance.new("PointLight")
	light.Brightness = 4
	light.Range = 14
	light.Parent = flash
	Debris:AddItem(flash, 1.5)
end

function EffectTrack.restoreEditorForgePreview(track: EffectTrack)
	track._editorDelayToken += 1
	for _, entry in track._editorForgeRestore do
		local inst = entry.inst
		if inst.Parent and (inst:IsA("ParticleEmitter") or inst:IsA("Beam")) then
			inst.Enabled = entry.enabled
		end
	end
	table.clear(track._editorForgeRestore)
end

local function findForgeModuleInGame(): ModuleScript?
	local rs = ReplicatedStorage:FindFirstChild("ForgeVFX")
	if rs and rs:IsA("ModuleScript") then
		return rs
	end
	return nil
end

-- Play / 已 init 的 shared.vfx:走 forge-vfx 官方 emit;编辑 scrub 仍用近似预览。
function EffectTrack.tryOfficialForgeEmit(
	track: EffectTrack,
	cue: CutsceneFormat.EffectCue,
	target: Instance?,
	forgeVfxModule: ModuleScript?
): boolean
	if not RunService:IsClient() then
		return false
	end
	local mod = forgeVfxModule
	if not mod and RunService:IsRunning() then
		mod = findForgeModuleInGame()
	end
	local api = ForgeEffectPlay.resolveApi(mod)
	if not api then
		return false
	end

	local roots: { Instance } = {}
	local function addRoot(base: Instance?)
		if not base then
			return
		end
		local r = resolveForgeEmitRoot(base, cue.forgeRoot)
		if not r then
			return
		end
		for _, existing in roots do
			if existing == r then
				return
			end
		end
		table.insert(roots, r)
	end
	addRoot(target)
	addRoot(track._workspaceMirror)
	if #roots == 0 then
		return false
	end

	local scale = cue.forgeScale or 1
	local token = track._editorDelayToken

	local function emitRoot(root: Instance)
		local delayRaw = root:GetAttribute("EmitDelay")
		local delay = if typeof(delayRaw) == "number" then delayRaw else 0
		local function doEmit()
			if token ~= track._editorDelayToken then
				return
			end
			local okEmit, result = ForgeEffectPlay.emitOnRoot(api, root, scale)
			if okEmit then
				ForgeEffectPlay.registerClear(track._forgeClears, result)
				print(
					`[anima] forge emit @ {string.format("%.2f", cue.t)}s · {root:GetFullName()}`
				)
			else
				warn(`[anima] EffectTrack:forge emit 失败 · {root:GetFullName()}`)
			end
		end
		if delay > 0 then
			task.delay(delay, doEmit)
		else
			doEmit()
		end
	end

	for _, root in roots do
		emitRoot(root)
	end
	return true
end

function EffectTrack.runForgeEditorPreview(
	track: EffectTrack,
	cue: CutsceneFormat.EffectCue,
	target: Instance?
)
	if EffectTrack.tryOfficialForgeEmit(track, cue, target, nil) then
		return
	end

	local roots: { Instance } = {}
	local function addRoot(base: Instance?)
		if not base then
			return
		end
		local r = resolveForgeEmitRoot(base, cue.forgeRoot)
		if not r then
			return
		end
		for _, existing in roots do
			if existing == r then
				return
			end
		end
		table.insert(roots, r)
	end
	addRoot(target)
	addRoot(track._workspaceMirror)
	if #roots == 0 then
		-- 25 spec:目标下没挂包 → 从 AnimaAssets 找到模板临时 clone 到目标,
		-- 登记进 _spawned(stop 统一销毁,不污染场景),编辑期预览与运行时对齐。
		local packName = cue.forgeRoot or ""
		if packName ~= "" and target then
			local template = AnimaAssets.findPack(packName)
			if template then
				local clone = template:Clone()
				clone.Archivable = false
				clone.Parent = target
				table.insert(track._spawned, clone)
				table.insert(roots, clone)
			end
		end
	end
	if #roots == 0 then
		warn(
			`[anima] EffectTrack:forge 预览无有效目标(forgeRoot='{cue.forgeRoot or ""}',AnimaAssets 中也未找到同名包)`
		)
		return
	end
	-- 仅当 emitter 自身无 EmitCount 属性时,才退回 cue.emitCount / 默认值。
	local emitCount = math.max(1, math.floor(cue.emitCount or EDITOR_FORGE_DEFAULT_EMIT))
	local token = track._editorDelayToken
	local function burst()
		if token ~= track._editorDelayToken then
			return
		end
		for _, root in roots do
			local delayRaw = root:GetAttribute("EmitDelay")
			local delay = if typeof(delayRaw) == "number" then delayRaw else 0
			local function doBurst()
				if token ~= track._editorDelayToken then
					return
				end
				forgeEditorBurstOnRoot(track, root, emitCount)
				viewportForgeFlash(root)
				print(
					`[anima] forge 近似预览 @ {string.format("%.2f", cue.t)}s · {root:GetFullName()}`
				)
				if ViewportFxFeedback and track._viewportFrame then
					ViewportFxFeedback.pulse(track._viewportFrame)
				end
			end
			if delay > 0 then
				task.delay(delay, doBurst)
			else
				doBurst()
			end
		end
	end
	burst()
end

-- 编辑 scrub:无 Forge 时用 Enable+Emit 近似;F5 Play 且 shared.vfx 可用时走官方 emit。
function EffectTrack.buildEditorPreviewHandler(track: EffectTrack): EffectCueHandler
	return function(cue: CutsceneFormat.EffectCue, target: Instance?): Instance?
		if CutsceneFormat.effectEmitMode(cue) == "forge" then
			EffectTrack.runForgeEditorPreview(track, cue, target)
			return nil
		end
		return EffectTrack.particleHandler(cue, target)
	end
end

function EffectTrack.newEditorPreview(
	track: CutsceneFormat.Track,
	target: Instance?,
	workspaceMirror: Instance?,
	previewOpts: { viewportFrame: ViewportFrame? }?
): EffectTrack
	if not target and not workspaceMirror then
		warn(`[anima] EffectTrack:特效轨 '{track.target}' 预览找不到场景/克隆目标`)
	end
	local self = setmetatable({
		cues = track.effectCues or {},
		target = target or workspaceMirror,
		handler = function() end,
		_fired = {},
		_spawned = {},
		_forgeClears = {},
		_editorForgeRestore = {},
		_editorDelayToken = 0,
		_workspaceMirror = workspaceMirror,
		_viewportFrame = if previewOpts then previewOpts.viewportFrame else nil,
	}, EffectTrack)
	self.handler = EffectTrack.buildEditorPreviewHandler(self)
	return self
end

function EffectTrack.buildDefaultHandler(
	track: EffectTrack,
	forgeVfxModule: ModuleScript?
): EffectCueHandler
	local warnedNoForge = false

	return function(cue: CutsceneFormat.EffectCue, target: Instance?): Instance?
		if CutsceneFormat.effectEmitMode(cue) ~= "forge" then
			return EffectTrack.particleHandler(cue, target)
		end

		if not RunService:IsClient() then
			if not warnedNoForge then
				warnedNoForge = true
				warn("[anima] EffectTrack:forge cue 仅在客户端执行,已跳过")
			end
			return nil
		end

		local mod = forgeVfxModule or findForgeModuleInGame()
		if not ForgeEffectPlay.resolveApi(mod) then
			if not warnedNoForge then
				warnedNoForge = true
				warn(
					"[anima] EffectTrack:forge cue 需要 ReplicatedStorage.ForgeVFX 或 CutscenePlayer.forgeVfxModule"
				)
			end
			return nil
		end

		EffectTrack.tryOfficialForgeEmit(track, cue, target, mod)
		return nil
	end
end

function EffectTrack.new(
	track: CutsceneFormat.Track,
	target: Instance?,
	handler: EffectCueHandler?,
	forgeVfxModule: ModuleScript?
): EffectTrack
	local self = setmetatable({
		cues = track.effectCues or {},
		target = target,
		handler = handler,
		_fired = {},
		_spawned = {},
		_forgeClears = {},
		_editorForgeRestore = {},
		_editorDelayToken = 0,
	}, EffectTrack)
	if handler then
		self.handler = handler
	else
		self.handler = EffectTrack.buildDefaultHandler(self, forgeVfxModule)
	end
	return self
end

function EffectTrack.update(self: EffectTrack, t: number)
	for i, cue in self.cues do
		if not self._fired[i] and t >= cue.t then
			self._fired[i] = true
			local inst = self.handler(cue, self.target)
			if inst then
				table.insert(self._spawned, inst)
			end
		end
	end
end

function EffectTrack.stop(self: EffectTrack)
	EffectTrack.restoreEditorForgePreview(self)
	for _, clearFn in self._forgeClears do
		pcall(clearFn)
	end
	table.clear(self._forgeClears)
	for _, inst in self._spawned do
		pcall(function()
			inst:Destroy()
		end)
	end
	table.clear(self._spawned)
	self._fired = {}
end

return EffectTrack
