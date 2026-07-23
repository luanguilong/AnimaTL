--!strict
-- MediaPreview — 编辑 scrub 时预览音效/特效 cue(防抖,避免拖时间轴爆音)。

local SceneResolver = require(script.Parent.SceneResolver)
local CutsceneFormat = require(script.Parent.Shared.CutsceneFormat)
local SoundTrack = require(script.Parent.Runtime.SoundTrack)
local EffectTrack = require(script.Parent.Runtime.EffectTrack)

export type BindingResolver = CutsceneFormat.BindingResolver

export type StepOptions = {
	workspaceResolve: BindingResolver?,
	kinds: { sound: boolean?, effect: boolean? }?,
	cutsceneRevision: number?,
	viewportFrame: ViewportFrame?,
}

type ContextState = {
	lastT: number,
	previewSoundTracks: { any },
	previewEffectTracks: { any },
	cutsceneRevision: number?,
}

local MediaPreview = {}

local _contexts: { [string]: ContextState } = {}
local _warnedMissingEffectTarget: { [string]: boolean } = {}

local function trackIncludedInStep(kind: string, options: StepOptions?): boolean
	if not options or not options.kinds then
		return kind == "sound" or kind == "effect"
	end
	if kind == "sound" then
		return options.kinds.sound == true
	end
	if kind == "effect" then
		return options.kinds.effect == true
	end
	return false
end

local function getContext(contextId: string): ContextState
	local ctx = _contexts[contextId]
	if not ctx then
		ctx = {
			lastT = 0,
			previewSoundTracks = {},
			previewEffectTracks = {},
			cutsceneRevision = nil,
		}
		_contexts[contextId] = ctx
	end
	return ctx
end

local function resetPreviewTracks(
	ctx: ContextState,
	cutscene: CutsceneFormat.Cutscene,
	resolveBinding: BindingResolver,
	options: StepOptions?
)
	for _, st in ctx.previewSoundTracks do
		st:stop()
	end
	for _, ft in ctx.previewEffectTracks do
		ft:stop()
	end
	table.clear(ctx.previewSoundTracks)
	table.clear(ctx.previewEffectTracks)
	for _, track in cutscene.tracks do
		if not trackIncludedInStep(track.kind, options) then
			continue
		end
		if track.kind == "sound" then
			local target = resolveBinding(track.target)
			table.insert(ctx.previewSoundTracks, SoundTrack.new(track, target, SoundTrack.defaultHandler))
		elseif track.kind == "effect" then
			local target = resolveBinding(track.target)
			local mirror = if options and options.workspaceResolve
				then options.workspaceResolve(track.target)
				else nil
			if not target and not mirror and not _warnedMissingEffectTarget[track.target] then
				_warnedMissingEffectTarget[track.target] = true
				warn(`[anima] MediaPreview:找不到特效绑定 '{track.target}'`)
			end
			table.insert(
				ctx.previewEffectTracks,
				EffectTrack.newEditorPreview(track, target, mirror, {
					viewportFrame = options and options.viewportFrame or nil,
				})
			)
		end
	end
end

function MediaPreview.step(
	cutscene: CutsceneFormat.Cutscene,
	t: number,
	prevT: number,
	resolveBinding: BindingResolver?,
	contextId: string?,
	options: StepOptions?
)
	local ctx = getContext(contextId or "workspace")
	local resolveFn = resolveBinding or SceneResolver.resolve

	if options and options.cutsceneRevision and ctx.cutsceneRevision ~= options.cutsceneRevision then
		for _, ft in ctx.previewEffectTracks do
			ft:stop()
		end
		for _, st in ctx.previewSoundTracks do
			st:stop()
		end
		table.clear(ctx.previewEffectTracks)
		table.clear(ctx.previewSoundTracks)
		ctx.lastT = 0
		ctx.cutsceneRevision = options.cutsceneRevision
	end

	local function ensureTracks()
		if #ctx.previewSoundTracks > 0 or #ctx.previewEffectTracks > 0 then
			return
		end
		for _, tr in cutscene.tracks do
			if trackIncludedInStep(tr.kind, options) then
				resetPreviewTracks(ctx, cutscene, resolveFn, options)
				return
			end
		end
	end

	ensureTracks()

	if math.abs(t - prevT) > 0.75 then
		resetPreviewTracks(ctx, cutscene, resolveFn, options)
		for _, st in ctx.previewSoundTracks do
			st:update(t)
		end
		for _, ft in ctx.previewEffectTracks do
			ft:update(t)
		end
		ctx.lastT = t
		return
	end
	if t < prevT then
		resetPreviewTracks(ctx, cutscene, resolveFn, options)
	end
	for _, st in ctx.previewSoundTracks do
		st:update(t)
	end
	for _, ft in ctx.previewEffectTracks do
		ft:update(t)
	end
	ctx.lastT = t
end

function MediaPreview.reset(contextId: string?)
	if contextId then
		local ctx = _contexts[contextId]
		if not ctx then
			return
		end
		ctx.lastT = 0
		ctx.cutsceneRevision = nil
		for _, st in ctx.previewSoundTracks do
			st:stop()
		end
		for _, ft in ctx.previewEffectTracks do
			ft:stop()
		end
		table.clear(ctx.previewSoundTracks)
		table.clear(ctx.previewEffectTracks)
		return
	end
	for id in _contexts do
		MediaPreview.reset(id)
	end
end

return MediaPreview
