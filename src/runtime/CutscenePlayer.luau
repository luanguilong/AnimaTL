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
local PropertyTrack = require(script.Parent.PropertyTrack)
local RigAnimTrack = require(script.Parent.RigAnimTrack)
local EventTrack = require(script.Parent.EventTrack)
local SoundTrack = require(script.Parent.SoundTrack)
local EffectTrack = require(script.Parent.EffectTrack)
local ScreenTrack = require(script.Parent.ScreenTrack)
local ScreenOverlay = require(script.Parent.ScreenOverlay)

local CutscenePlayer = {}
CutscenePlayer.__index = CutscenePlayer

export type Config = {
	resolver: CutsceneFormat.BindingResolver,
	camera: Camera?, -- 缺省用 workspace.CurrentCamera
	onEvent: EventTrack.EventHandler?, -- 事件处理器;缺省仅打印
	onSoundCue: SoundTrack.SoundCueHandler?,
	onEffectCue: EffectTrack.EffectCueHandler?,
	forgeVfxModule: ModuleScript?, -- 16: forge cue 默认 handler 用(例 ReplicatedStorage.ForgeVFX)
	screenDisplayOrder: number?, -- 22: 屏幕演出层 ScreenGui.DisplayOrder;缺省 999
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
		_propertyTracks: { PropertyTrack.PropertyTrack },
		_rigAnimTracks: { RigAnimTrack.RigAnimTrack },
		_eventTracks: { EventTrack.EventTrack },
		_soundTracks: { SoundTrack.SoundTrack },
		_effectTracks: { EffectTrack.EffectTrack },
		_screenTrackData: { CutsceneFormat.Track },
		_screenTracks: { ScreenTrack.ScreenTrack },
		_overlay: ScreenOverlay.ScreenOverlay?,
		_screenDisplayOrder: number?,
		_clips: { ClipState },
		_binders: { [Model]: CharacterBinder.CharacterBinder },
		_conn: RBXScriptConnection?,
		_renderBindId: string?,
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
		_propertyTracks = {},
		_rigAnimTracks = {},
		_eventTracks = {},
		_soundTracks = {},
		_effectTracks = {},
		_screenTrackData = {},
		_screenTracks = {},
		_overlay = nil,
		_screenDisplayOrder = config.screenDisplayOrder,
		_clips = {},
		_binders = {},
		_conn = nil,
		_renderBindId = nil,
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
		if track.hidden then
			continue
		end
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
		elseif track.kind == "property" then
			local target = config.resolver(track.target)
			if target then
				local pt = PropertyTrack.new(track, target)
				if pt then
					table.insert(self._propertyTracks, pt)
				end
			else
				warn(`[anima] property 轨道找不到目标 '{track.target}'`)
			end
		elseif track.kind == "rigAnim" then
			local target = config.resolver(track.target)
			if target then
				local rt = RigAnimTrack.new(track, target)
				if rt then
					table.insert(self._rigAnimTracks, rt)
				end
			else
				warn(`[anima] rigAnim 轨道找不到目标 '{track.target}'`)
			end
		elseif track.kind == "event" then
			local target = config.resolver(track.target)
			table.insert(self._eventTracks, EventTrack.new(track, target, self.onEvent))
		elseif track.kind == "sound" then
			local target = config.resolver(track.target)
			table.insert(self._soundTracks, SoundTrack.new(track, target, config.onSoundCue))
		elseif track.kind == "screen" then
			-- 屏幕层仅客户端;overlay 在 play() 时才创建,这里只收数据
			if RunService:IsClient() then
				table.insert(self._screenTrackData, track)
			else
				warn("[anima] screen 轨仅客户端生效,server 播放跳过")
			end
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
						table.insert(
							self._clips,
							{ clip = clip, binder = binder, started = false, ended = false }
						)
					end
				elseif binder and not hum then
					warn(
						`[anima] animation 轨道目标 '{track.target}' 没有 Humanoid,跳过 clips`
					)
				end
			else
				warn(`[anima] animation 轨道目标 '{track.target}' 不是有效角色 Model`)
			end
		end
	end

	return self
end

-- 单帧推进到时间 t,驱动所有轨道。
-- skipMedia(跳过语义,22 spec):true = 只推进世界状态(相机/变换/属性/关节)与逻辑事件,
-- **静默跳过** sound/effect/screen cue 与新起的动画 clip——玩家按跳过时不该炸响一串音效;
-- transform/property 仍步进到位,保证"门开着"这类终态与正常播完一致(property 的
-- keepOnDone 依赖终值,必须先步进再 stop)。
function CutscenePlayer._step(self: CutscenePlayer, t: number, skipMedia: boolean?)
	self._time = t
	for _, ct in self._cameraTracks do
		ct:update(t)
	end
	for _, tt in self._transformTracks do
		tt:update(t)
	end
	for _, pt in self._propertyTracks do
		pt:update(t)
	end
	for _, rt in self._rigAnimTracks do
		rt:update(t)
	end
	for _, et in self._eventTracks do
		et:update(t)
	end
	if skipMedia then
		return
	end
	for _, st in self._soundTracks do
		st:update(t)
	end
	for _, ft in self._effectTracks do
		ft:update(t)
	end
	for _, sc in self._screenTracks do
		sc:update(t)
	end
	for _, cs in self._clips do
		if not cs.started and t >= cs.clip.startAt then
			cs.started = true
			cs.binder:playClip(cs.clip)
		end
		if
			cs.started
			and not cs.ended
			and cs.clip.endAt
			and t > cs.clip.endAt
			and cs.clip.looped ~= true
		then
			cs.ended = true
			cs.binder:stopClip(cs.clip.animationId, cs.clip.fadeTime)
		end
	end
end

-- 开始播放。onComplete 在到达 duration(或跳过)时调用一次;skipped=true 表示玩家跳过。
-- startAt:起播时刻(秒,缺省 0);全员同步 / 迟到进场用(22 spec,事件轨支持跳跃补发)。
function CutscenePlayer.play(
	self: CutscenePlayer,
	onComplete: ((skipped: boolean?) -> ())?,
	startAt: number?
)
	if self._playing then
		return
	end
	self._playing = true
	self._time = math.clamp(startAt or 0, 0, self.cutscene.duration)

	local takeCamera = self.cutscene.takeCameraControl ~= false
	if takeCamera then
		for _, ct in self._cameraTracks do
			ct:begin()
		end
	end

	-- 22: 屏幕演出层(screen 轨 / 跳过按钮共用一个 overlay),仅客户端
	local needOverlay = #self._screenTrackData > 0 or self.cutscene.skippable == true
	if needOverlay and RunService:IsClient() then
		local overlay = ScreenOverlay.new({ displayOrder = self._screenDisplayOrder })
		if overlay then
			self._overlay = overlay
			for _, trackData in self._screenTrackData do
				table.insert(self._screenTracks, ScreenTrack.new(trackData, overlay))
			end
			if self.cutscene.skippable == true then
				overlay:showSkipButton(self.cutscene.skipHoldSec or 0, function()
					if not self._playing then
						return
					end
					-- skipMedia=true:补发逻辑事件、世界终态到位,静默跳过音效/特效/屏幕 cue
					self:_step(self.cutscene.duration, true)
					self:stop()
					if onComplete then
						onComplete(true)
					end
				end)
			end
		end
	end

	self:_step(self._time)

	-- 用 BindToRenderStep(Last) 而非 RenderStepped 事件:排在引擎动画步进之后,
	-- 否则 Animator/Humanoid 每帧会把 rigAnim 写的 Motor6D.Transform 冲掉(Moonlite 同款)。
	local function onFrame(dt: number)
		if not self._playing then
			return
		end
		local t = self._time + dt
		if t >= self.cutscene.duration then
			self:_step(self.cutscene.duration)
			self:stop()
			if onComplete then
				onComplete(false)
			end
		else
			self:_step(t)
		end
	end
	if RunService:IsClient() then
		local bindId = "AnimaCutscene_" .. self.cutscene.name .. "_" .. tostring(os.clock())
		self._renderBindId = bindId
		RunService:BindToRenderStep(bindId, Enum.RenderPriority.Last.Value, onFrame)
	else
		self._conn = RunService.Heartbeat:Connect(onFrame)
	end
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
	if self._renderBindId then
		RunService:UnbindFromRenderStep(self._renderBindId)
		self._renderBindId = nil
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
	for _, pt in self._propertyTracks do
		pt:stop()
	end
	for _, rt in self._rigAnimTracks do
		rt:stop()
	end
	for _, sc in self._screenTracks do
		sc:reset()
	end
	self._screenTracks = {}
	if self._overlay then
		self._overlay:destroy()
		self._overlay = nil
	end
end

return CutscenePlayer
