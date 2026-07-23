--!strict
-- CutscenePlayer — 运行时主调度。
--
-- 职责:管理 playhead(时间轴指针),每帧推进并驱动所有轨道求值:
--   camera/transform → 按时间插值设位姿
--   animation        → 到起播时刻 Play 一次
--   event            → 到点触发一次
--
-- 用法(client 端):
--   local player = CutscenePlayer.new(cutscene, {
--       resolver = function(name) ... end,   -- 逻辑名 → 真实实例("Player" 给真实 Character)
--       camera = workspace.CurrentCamera,
--       onEvent = function(event, target) ... end,
--   })
--   player:play(function() print("done") end)

local RunService = game:GetService("RunService")

local CutsceneFormat = require(script.Parent.Parent.Shared.CutsceneFormat)
local CharacterBinder = require(script.Parent.CharacterBinder)
local CameraTrack = require(script.Parent.CameraTrack)
local TransformTrack = require(script.Parent.TransformTrack)
local EventTrack = require(script.Parent.EventTrack)
local SoundTrack = require(script.Parent.SoundTrack)
local EffectTrack = require(script.Parent.EffectTrack)

local CutscenePlayer = {}
CutscenePlayer.__index = CutscenePlayer

export type Config = {
	resolver: CutsceneFormat.BindingResolver,
	camera: Camera?, -- 缺省用 workspace.CurrentCamera
	onEvent: EventTrack.EventHandler?, -- 事件处理器;缺省仅打印
	onSoundCue: SoundTrack.SoundCueHandler?,
	onEffectCue: EffectTrack.EffectCueHandler?,
	forgeVfxModule: ModuleScript?, -- 16: forge cue 默认 handler 用(例 ReplicatedStorage.ForgeVFX)
}

-- 单条动画片段的运行时状态
type ClipState = {
	clip: CutsceneFormat.AnimationClip,
	binder: CharacterBinder.CharacterBinder,
	started: boolean,
	ended: boolean,
}

export type CutscenePlayer = typeof(setmetatable(
	{} :: {
		cutscene: CutsceneFormat.Cutscene,
		camera: Camera,
		onEvent: EventTrack.EventHandler,
		_cameraTracks: { CameraTrack.CameraTrack },
		_transformTracks: { TransformTrack.TransformTrack },
		_eventTracks: { EventTrack.EventTrack },
		_soundTracks: { SoundTrack.SoundTrack },
		_effectTracks: { EffectTrack.EffectTrack },
		_clips: { ClipState },
		_binders: { [Model]: CharacterBinder.CharacterBinder },
		_conn: RBXScriptConnection?,
		_time: number,
		_playing: boolean,
	},
	CutscenePlayer
))

local function defaultEventHandler(event: CutsceneFormat.CutsceneEvent, _target: Instance?)
	print(`[anima] event '{event.name}' @ {event.t}s`)
end

function CutscenePlayer.new(cutscene: CutsceneFormat.Cutscene, config: Config): CutscenePlayer
	local camera = config.camera or workspace.CurrentCamera
	assert(camera, "[anima] 没有可用的 Camera")

	local self = setmetatable({
		cutscene = cutscene,
		camera = camera,
		onEvent = config.onEvent or defaultEventHandler,
		_cameraTracks = {},
		_transformTracks = {},
		_eventTracks = {},
		_soundTracks = {},
		_effectTracks = {},
		_clips = {},
		_binders = {},
		_conn = nil,
		_time = 0,
		_playing = false,
	}, CutscenePlayer)

	-- 复用同一 Model 的 binder
	local function binderFor(model: Model): CharacterBinder.CharacterBinder?
		local existing = self._binders[model]
		if existing then
			return existing
		end
		local b = CharacterBinder.new(model)
		if b then
			self._binders[model] = b
		end
		return b
	end

	-- 从数据构建各轨道运行时对象。相机走 CameraDirector 择一,整场只建一个 CameraTrack。
	local cameraBuilt = false
	for _, track in cutscene.tracks do
		if track.kind == "camera" then
			if not cameraBuilt then
				table.insert(self._cameraTracks, CameraTrack.new(cutscene, camera, config.resolver))
				cameraBuilt = true
			end
		elseif track.kind == "transform" then
			local target = config.resolver(track.target)
			if target then
				table.insert(self._transformTracks, TransformTrack.new(track, target))
			else
				warn(`[anima] transform 轨道找不到目标 '{track.target}'`)
			end
		elseif track.kind == "event" then
			local target = config.resolver(track.target)
			table.insert(self._eventTracks, EventTrack.new(track, target, self.onEvent))
		elseif track.kind == "sound" then
			local target = config.resolver(track.target)
			table.insert(
				self._soundTracks,
				SoundTrack.new(track, target, config.onSoundCue)
			)
		elseif track.kind == "effect" then
			local target = config.resolver(track.target)
			table.insert(
				self._effectTracks,
				EffectTrack.new(track, target, config.onEffectCue, config.forgeVfxModule)
			)
		elseif track.kind == "animation" then
			local target = config.resolver(track.target)
			if target and target:IsA("Model") and track.clips then
				local hum = target:FindFirstChildOfClass("Humanoid")
				local binder = binderFor(target)
				if binder and hum then
					local filtered = CutsceneFormat.clipsForRig(track.clips, hum.RigType)
					for _, clip in filtered do
						table.insert(self._clips, { clip = clip, binder = binder, started = false, ended = false })
					end
				elseif binder and not hum then
					warn(`[anima] animation 轨道目标 '{track.target}' 没有 Humanoid,跳过 clips`)
				end
			else
				warn(`[anima] animation 轨道目标 '{track.target}' 不是有效角色 Model`)
			end
		end
	end

	return self
end

-- 单帧推进到时间 t,驱动所有轨道。
function CutscenePlayer._step(self: CutscenePlayer, t: number)
	self._time = t
	for _, ct in self._cameraTracks do
		ct:update(t)
	end
	for _, tt in self._transformTracks do
		tt:update(t)
	end
	for _, et in self._eventTracks do
		et:update(t)
	end
	for _, st in self._soundTracks do
		st:update(t)
	end
	for _, ft in self._effectTracks do
		ft:update(t)
	end
	for _, cs in self._clips do
		if not cs.started and t >= cs.clip.startAt then
			cs.started = true
			cs.binder:playClip(cs.clip)
		end
		if cs.started and not cs.ended and cs.clip.endAt and t > cs.clip.endAt and cs.clip.looped ~= true then
			cs.ended = true
			cs.binder:stopClip(cs.clip.animationId, cs.clip.fadeTime)
		end
	end
end

-- 开始播放。onComplete 在到达 duration 时调用一次。
function CutscenePlayer.play(self: CutscenePlayer, onComplete: (() -> ())?)
	if self._playing then
		return
	end
	self._playing = true
	self._time = 0

	local takeCamera = self.cutscene.takeCameraControl ~= false
	if takeCamera then
		for _, ct in self._cameraTracks do
			ct:begin()
		end
	end

	self:_step(0)

	self._conn = RunService.RenderStepped:Connect(function(dt: number)
		if not self._playing then
			return
		end
		local t = self._time + dt
		if t >= self.cutscene.duration then
			self:_step(self.cutscene.duration)
			self:stop()
			if onComplete then
				onComplete()
			end
		else
			self:_step(t)
		end
	end)
end

-- 停止并清理(相机归还、动画淡出)。
function CutscenePlayer.stop(self: CutscenePlayer)
	if not self._playing then
		return
	end
	self._playing = false
	if self._conn then
		self._conn:Disconnect()
		self._conn = nil
	end
	for _, ct in self._cameraTracks do
		ct:finish()
	end
	for _, binder in self._binders do
		binder:stopAll()
	end
	for _, st in self._soundTracks do
		st:stop()
	end
	for _, ft in self._effectTracks do
		ft:stop()
	end
end

return CutscenePlayer
