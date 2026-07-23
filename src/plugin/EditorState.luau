--!strict
-- EditorState — 插件的可编辑数据模型(响应式)。
-- 把一个 Cutscene 载入成 Fusion Value,UI 从这里读、编辑操作往这里写。
--
-- 编辑 API 分两类:
--   · 离散操作(增删轨道 / 打帧 / 删帧 / 改缓动 …)自己压一次撤销快照;
--   · 拖拽操作(moveKeyframe 等)不压快照,由调用方在
--     拖拽开始时调一次 pushUndo(),整段拖拽算一步撤销。
--
-- 关键帧的编辑一律传"对象引用"而非索引,避免排序后索引漂移。

local Fusion = require(script.Parent.Packages.Fusion)
local CutsceneFormat = require(script.Parent.Shared.CutsceneFormat)
local Sampler = require(script.Parent.Shared.Sampler)
local FollowAnchor = require(script.Parent.Shared.FollowAnchor)
local SceneResolver = require(script.Parent.SceneResolver)

local Value = Fusion.Value

local EditorState = {}
EditorState.__index = EditorState

local TimelineUnity = require(script.Parent.TimelineUnity)

type Snapshot = {
	name: string,
	duration: number,
	fps: number,
	tracks: { CutsceneFormat.Track },
}

export type EditorState = typeof(setmetatable(
	{} :: {
		name: Fusion.Value<string>,
		duration: Fusion.Value<number>,
		fps: Fusion.Value<number>,
		currentTime: Fusion.Value<number>,
		tracks: Fusion.Value<{ CutsceneFormat.Track }>,
		selectedTrack: Fusion.Value<number?>,
		canUndo: Fusion.Value<boolean>,
		canRedo: Fusion.Value<boolean>,
		revision: Fusion.Value<number>, -- 每次结构性变更 +1,供外部(预览/轨迹)重建
		_undo: { Snapshot },
		_redo: { Snapshot },
	},
	EditorState
))

-- 深拷贝一条轨道(含 keyframes / clips / events)。
local function cloneTrack(tr: CutsceneFormat.Track): CutsceneFormat.Track
	local kf = nil
	if tr.keyframes then
		kf = {}
		for _, k in tr.keyframes do
			table.insert(kf, {
				t = k.t,
				value = k.value,
				easing = k.easing,
				outTangent = k.outTangent,
				inTangent = k.inTangent,
			})
		end
	end
	local fovKf = nil
	if tr.fovKeyframes then
		fovKf = {}
		for _, k in tr.fovKeyframes do
			table.insert(fovKf, { t = k.t, value = k.value, easing = k.easing })
		end
	end
	local clips = nil
	if tr.clips then
		clips = {}
		for _, c in tr.clips do
			table.insert(clips, {
				animationId = c.animationId,
				startAt = c.startAt,
				endAt = c.endAt,
				fadeTime = c.fadeTime,
				speed = c.speed,
				looped = c.looped,
				rigType = c.rigType,
			})
		end
	end
	local events = nil
	if tr.events then
		events = {}
		for _, ev in tr.events do
			table.insert(events, {
				t = ev.t,
				name = ev.name,
				-- 浅拷贝隔离 undo 快照(值全是标量;19 spec)
				payload = if ev.payload then table.clone(ev.payload) else nil,
			})
		end
	end
	local soundCues = nil
	if tr.soundCues then
		soundCues = {}
		for _, c in tr.soundCues do
			table.insert(soundCues, {
				t = c.t,
				soundId = c.soundId,
				volume = c.volume,
				playbackSpeed = c.playbackSpeed,
				looped = c.looped,
				maxDistance = c.maxDistance,
			})
		end
	end
	local effectCues = nil
	if tr.effectCues then
		effectCues = {}
		for _, c in tr.effectCues do
			table.insert(effectCues, {
				t = c.t,
				emitMode = c.emitMode,
				particleAssetId = c.particleAssetId,
				templateName = c.templateName,
				emitCount = c.emitCount,
				duration = c.duration,
				forgeRoot = c.forgeRoot,
				forgeScale = c.forgeScale,
			})
		end
	end
	local jointTracks = nil
	if tr.jointTracks then
		jointTracks = {}
		for _, jt in tr.jointTracks do
			local jkf = {}
			for _, k in jt.keyframes do
				table.insert(jkf, { t = k.t, value = k.value, easing = k.easing })
			end
			table.insert(jointTracks, { path = jt.path, keyframes = jkf })
		end
	end
	local propKf = nil
	if tr.propKeyframes then
		propKf = {}
		for _, k in tr.propKeyframes do
			table.insert(propKf, { t = k.t, value = k.value, easing = k.easing })
		end
	end
	-- 相机轨:深拷贝 segments;旧单 from/to 迁移成一段(之后 from/to 不再使用)。
	local segments = nil
	if tr.segments then
		segments = {}
		for _, s in tr.segments do
			table.insert(segments, { from = s.from, to = s.to })
		end
	elseif tr.kind == "camera" and tr.from and tr.to then
		segments = { { from = tr.from, to = tr.to } }
	end
	return {
		kind = tr.kind,
		target = tr.target,
		name = tr.name,
		group = tr.group,
		hidden = tr.hidden,
		segments = segments,
		from = if segments then nil else tr.from,
		to = if segments then nil else tr.to,
		smooth = tr.smooth,
		pathMode = tr.pathMode,
		followBinding = tr.followBinding,
		followPart = tr.followPart,
		keyframes = kf,
		fovKeyframes = fovKf,
		clips = clips,
		events = events,
		soundCues = soundCues,
		effectCues = effectCues,
		propertyName = tr.propertyName,
		propertyKind = tr.propertyKind,
		propKeyframes = propKf,
		keepOnDone = tr.keepOnDone,
		jointTracks = jointTracks,
	}
end

-- 深拷贝一份 tracks(避免直接改到源数据)。
local function cloneTracks(tracks: { CutsceneFormat.Track }): { CutsceneFormat.Track }
	local out = {}
	for _, tr in tracks do
		table.insert(out, cloneTrack(tr))
	end
	return out
end

function EditorState.new(cutscene: CutsceneFormat.Cutscene): EditorState
	return setmetatable({
		name = Value(cutscene.name),
		duration = Value(cutscene.duration),
		fps = Value(cutscene.fps or 30),
		currentTime = Value(0),
		tracks = Value(cloneTracks(cutscene.tracks)),
		selectedTrack = Value(nil),
		canUndo = Value(false),
		canRedo = Value(false),
		revision = Value(0),
		_undo = {},
		_redo = {},
	}, EditorState)
end

-- 设置播放头时间(夹到 [0, duration])
function EditorState.setTime(self: EditorState, t: number)
	local dur = self.duration:get()
	self.currentTime:set(math.clamp(t, 0, dur))
end

-- 触发一次 tracks 变更通知(改完内部数组后调用)。
-- 必须换成新的外层表引用,否则 Fusion 认为值未变、不会重渲染。
-- structural=true 时同时 +revision,让预览/轨迹重建克隆与轨道集合。
function EditorState.commitTracks(self: EditorState, structural: boolean?)
	self.tracks:set(table.clone(self.tracks:get()))
	if structural then
		self.revision:set(self.revision:get() + 1)
	end
end

--========================= 撤销 / 重做 =========================--

local UNDO_LIMIT = 60

function EditorState.snapshot(self: EditorState): Snapshot
	return {
		name = self.name:get(),
		duration = self.duration:get(),
		fps = self.fps:get(),
		tracks = cloneTracks(self.tracks:get()),
	}
end

-- 在做一步"可撤销"的改动之前调用:把当前状态压入 undo 栈,清空 redo。
function EditorState.pushUndo(self: EditorState)
	table.insert(self._undo, self:snapshot())
	if #self._undo > UNDO_LIMIT then
		table.remove(self._undo, 1)
	end
	table.clear(self._redo)
	self.canUndo:set(true)
	self.canRedo:set(false)
end

local function applySnapshot(self: EditorState, snap: Snapshot)
	self.name:set(snap.name)
	self.duration:set(snap.duration)
	self.fps:set(snap.fps or 30)
	self.tracks:set(snap.tracks)
	self.revision:set(self.revision:get() + 1)
	-- 播放头夹回新时长
	self:setTime(self.currentTime:get())
end

function EditorState.undo(self: EditorState)
	local snap = table.remove(self._undo)
	if not snap then
		return
	end
	table.insert(self._redo, self:snapshot())
	applySnapshot(self, snap)
	self.canUndo:set(#self._undo > 0)
	self.canRedo:set(true)
end

function EditorState.redo(self: EditorState)
	local snap = table.remove(self._redo)
	if not snap then
		return
	end
	table.insert(self._undo, self:snapshot())
	applySnapshot(self, snap)
	self.canRedo:set(#self._redo > 0)
	self.canUndo:set(true)
end

--========================= 排序 helper =========================--

local function sortKeyframes(track: CutsceneFormat.Track)
	if track.keyframes then
		table.sort(track.keyframes, function(a, b)
			return a.t < b.t
		end)
	end
end

--========================= 轨道查找 / 管理 =========================--

-- 新增一条轨道。返回其索引。group 为所属对象分组名(可空)。
function EditorState.addTrack(
	self: EditorState,
	kind: CutsceneFormat.TrackKind,
	target: string,
	name: string?,
	group: string?
): number
	self:pushUndo()
	local tracks = self.tracks:get()
	local track: CutsceneFormat.Track = {
		kind = kind,
		target = target,
		name = name or TimelineUnity.defaultTrackName(kind),
		group = group,
	}
	if kind == "transform" or kind == "cameraMove" then
		track.keyframes = {}
	elseif kind == "animation" then
		track.clips = {}
	elseif kind == "event" then
		track.events = {}
	elseif kind == "sound" then
		track.soundCues = {}
	elseif kind == "effect" then
		track.effectCues = {}
	elseif kind == "property" then
		track.propKeyframes = {}
	elseif kind == "rigAnim" then
		track.jointTracks = {}
	end
	-- 注:kind == "camera" 走 addCameraTrack(独立轨,含 from/to);此处不再造 shots 轨。
	table.insert(tracks, track)
	self:commitTracks(true)
	return #tracks
end

-- 新建一条"每相机独立轨"(camera:vcam + 生效区间 + 运动关键帧)。
function EditorState.addCameraTrack(
	self: EditorState,
	vcamName: string,
	from: number,
	to: number,
	group: string?
): number
	self:pushUndo()
	local tracks = self.tracks:get()
	table.insert(tracks, {
		kind = "camera",
		target = vcamName,
		name = TimelineUnity.defaultTrackName("camera"),
		group = group,
		segments = { { from = from, to = to } },
		keyframes = {},
	})
	self:commitTracks(true)
	return #tracks
end

-- 切换某轨道关键帧插值:直线(false) / 平滑曲线(true)。
function EditorState.setTrackSmooth(self: EditorState, track: CutsceneFormat.Track, smooth: boolean)
	self:pushUndo()
	track.smooth = smooth
	if smooth then
		track.pathMode = nil
	end
	self:commitTracks(true)
end

-- 路径模式:直线 / 贝塞尔(07)。切到 bezier 时可拟合初始切线。
function EditorState.setTrackPathMode(
	self: EditorState,
	track: CutsceneFormat.Track,
	mode: CutsceneFormat.PathMode
)
	if track.kind ~= "camera" and track.kind ~= "cameraMove" then
		return
	end
	self:pushUndo()
	if mode == "linear" then
		track.pathMode = nil
	else
		track.pathMode = "bezier"
		track.smooth = false
		EditorState.fitTrackToBezierTangents(track, false)
	end
	self:commitTracks(true)
end

-- 从当前 Catmull/直线形状拟合各段切线(保留形状);onlyIfEmpty 时跳过已有切线。
function EditorState.fitTrackToBezierTangents(track: CutsceneFormat.Track, onlyIfEmpty: boolean?)
	local kfs = track.keyframes
	if not kfs or #kfs < 2 then
		return
	end
	local n = #kfs
	for i = 1, n - 1 do
		local a = kfs[i]
		local b = kfs[i + 1]
		if not a.value or not b.value then
			continue
		end
		local p1 = a.value.Position
		local p2 = b.value.Position
		local p0 = if kfs[i - 1] and kfs[i - 1].value then kfs[i - 1].value :: CFrame else a.value
		local p3 = if kfs[i + 2] and kfs[i + 2].value then kfs[i + 2].value :: CFrame else b.value
		local outOff = (p2 - p0.Position) / 6
		local inOff = (p3.Position - p1) / 6
		if not onlyIfEmpty or not a.outTangent then
			a.outTangent = outOff
		end
		if not onlyIfEmpty or not b.inTangent then
			b.inTangent = inOff
		end
	end
end

function EditorState.resetTrackTangents(self: EditorState, track: CutsceneFormat.Track)
	if not track.keyframes then
		return
	end
	self:pushUndo()
	for _, kf in track.keyframes do
		kf.outTangent = nil
		kf.inTangent = nil
	end
	self:commitTracks(true)
end

function EditorState.setKeyframeTangents(
	self: EditorState,
	kf: CutsceneFormat.Keyframe,
	outTangent: Vector3?,
	inTangent: Vector3?
)
	self:pushUndo()
	kf.outTangent = outTangent
	kf.inTangent = inTangent
	self:commitTracks(true)
end

--========================= 相机段(segment)编辑 =========================--

-- 确保相机轨有 segments 数组(迁移旧 from/to),返回该数组。
local function ensureSegments(track: CutsceneFormat.Track): { CutsceneFormat.CameraSegment }
	if not track.segments then
		if track.from and track.to then
			track.segments = { { from = track.from, to = track.to } }
		else
			track.segments = {}
		end
		track.from = nil
		track.to = nil
	end
	return track.segments :: { CutsceneFormat.CameraSegment }
end

local DEFAULT_SEGMENT_LEN = 1 -- 新建生效段默认长度(秒)

-- 同轨多段不允许重叠:后段起点不得早于前段终点,删去零长度段。
local MIN_SEGMENT_SEC = 1 / 30

local function resolveSegmentOverlaps(segs: { CutsceneFormat.CameraSegment }, dur: number)
	table.sort(segs, function(a, b)
		return a.from < b.from
	end)
	local i = 1
	while i <= #segs do
		local s = segs[i]
		s.from = math.clamp(s.from, 0, dur)
		s.to = math.clamp(s.to, 0, dur)
		if s.to < s.from then
			s.from, s.to = s.to, s.from
		end
		if s.to <= s.from then
			s.to = math.min(dur, s.from + MIN_SEGMENT_SEC)
		end
		if s.to <= s.from then
			table.remove(segs, i)
			continue
		end
		if i > 1 then
			local prev = segs[i - 1]
			if s.from < prev.to then
				s.from = prev.to
				if s.to <= s.from then
					table.remove(segs, i)
					continue
				end
			end
		end
		i += 1
	end
end

-- 在某相机轨的时刻 t 处新增一段(默认 1 秒,夹到总时长,不与已有段重叠)。
function EditorState.addSegment(self: EditorState, track: CutsceneFormat.Track, t: number)
	self:pushUndo()
	local dur = self.duration:get()
	local segs = ensureSegments(track)
	-- 不越过后面最近一段的起点
	local nextFrom = dur
	for _, s in segs do
		if s.from > t + 1e-3 then
			nextFrom = math.min(nextFrom, s.from)
		end
	end
	local from = math.clamp(t, 0, dur)
	table.insert(segs, { from = from, to = math.min(from + DEFAULT_SEGMENT_LEN, nextFrom, dur) })
	resolveSegmentOverlaps(segs, dur)
	self:commitTracks(true)
end

-- 相机段拖拽结束后:消重叠并提交(蓝条平移/改长度共用)。
function EditorState.finishCameraSegmentDrag(self: EditorState, track: CutsceneFormat.Track)
	if track.kind == "camera" and track.segments then
		resolveSegmentOverlaps(track.segments, self.duration:get())
	end
	self:finishDrag()
end

function EditorState.removeSegment(self: EditorState, track: CutsceneFormat.Track, index: number)
	local segs = track.segments
	if not segs or not segs[index] then
		return
	end
	self:pushUndo()
	table.remove(segs, index)
	self:commitTracks(true)
end

-- 直接设某段的起止(数值编辑用;夹到 [0,dur] 且 from<to)。
function EditorState.setSegmentRange(
	self: EditorState,
	track: CutsceneFormat.Track,
	index: number,
	from: number,
	to: number
)
	local segs = track.segments
	if not segs or not segs[index] then
		return
	end
	self:pushUndo()
	local dur = self.duration:get()
	from = math.clamp(from, 0, dur)
	to = math.clamp(to, 0, dur)
	if to < from then
		from, to = to, from
	end
	segs[index] = { from = from, to = math.max(to, from + 0.05) }
	resolveSegmentOverlaps(segs, dur)
	self:commitTracks(true)
end

-- 删除整个分组(其下所有轨道)。
function EditorState.removeGroup(self: EditorState, group: string)
	self:pushUndo()
	local tracks = self.tracks:get()
	for i = #tracks, 1, -1 do
		if (tracks[i].group or "") == group then
			table.remove(tracks, i)
		end
	end
	self:commitTracks(true)
end

-- 分组改名(改其下所有轨道的 group)。
function EditorState.renameGroup(self: EditorState, old: string, new: string)
	self:pushUndo()
	for _, tr in self.tracks:get() do
		if (tr.group or "") == old then
			tr.group = new
		end
	end
	self:commitTracks(true)
end

function EditorState.removeTrack(self: EditorState, track: CutsceneFormat.Track)
	local tracks = self.tracks:get()
	for i, tr in tracks do
		if tr == track then
			self:pushUndo()
			table.remove(tracks, i)
			self:commitTracks(true)
			return
		end
	end
end

-- 隐藏/显示轨道(隐藏 = 预览与运行时都跳过;数据保留)。
function EditorState.setTrackHidden(self: EditorState, track: CutsceneFormat.Track, hidden: boolean)
	self:pushUndo()
	track.hidden = if hidden then true else nil
	self:commitTracks(true)
end

-- 上下移动轨道顺序(delta=-1 上移 / 1 下移)。相机轨顺序即上镜优先级(越上层越优先)。
function EditorState.moveTrack(self: EditorState, track: CutsceneFormat.Track, delta: number)
	local tracks = self.tracks:get()
	local idx = table.find(tracks, track)
	if not idx then
		return
	end
	local newIdx = idx + delta
	if newIdx < 1 or newIdx > #tracks then
		return
	end
	self:pushUndo()
	table.remove(tracks, idx)
	table.insert(tracks, newIdx, track)
	local sel = self.selectedTrack:get()
	if sel == idx then
		self.selectedTrack:set(newIdx)
	elseif sel == newIdx then
		self.selectedTrack:set(idx)
	end
	self:commitTracks(true)
end

function EditorState.renameTrack(self: EditorState, track: CutsceneFormat.Track, name: string)
	self:pushUndo()
	track.name = name
	self:commitTracks(true)
end

function EditorState.setTrackTarget(self: EditorState, track: CutsceneFormat.Track, target: string)
	self:pushUndo()
	track.target = target
	self:commitTracks(true)
end

-- 相机轨跟随绑定(轨级;一步 undo)。绑定时迁移 key/切线空间,与 FollowAnchor 求值一致。
function EditorState.setCameraFollow(
	self: EditorState,
	track: CutsceneFormat.Track,
	followBinding: string?,
	followPart: string?
)
	if track.kind ~= "camera" then
		return
	end
	self:pushUndo()

	local resolver: CutsceneFormat.BindingResolver = SceneResolver.resolve
	local kfs = track.keyframes
	local hadFollow = FollowAnchor.hasFollowBinding(track)

	local function keyframesToWorld()
		if not kfs then
			return
		end
		for _, kf in kfs do
			if kf.value then
				kf.value = FollowAnchor.worldFromKeyframeCFrame(track, kf.value, resolver)
			end
			if kf.outTangent then
				kf.outTangent =
					FollowAnchor.storedOffsetToWorldDelta(track, kf.outTangent, resolver)
			end
			if kf.inTangent then
				kf.inTangent = FollowAnchor.storedOffsetToWorldDelta(track, kf.inTangent, resolver)
			end
		end
	end

	local function keyframesToRelative()
		if not kfs then
			return
		end
		for _, kf in kfs do
			if kf.value then
				kf.value = FollowAnchor.storeKeyframeCFrame(track, kf.value, resolver)
			end
			if kf.outTangent then
				kf.outTangent =
					FollowAnchor.worldDeltaToStoredOffset(track, kf.outTangent, resolver)
			end
			if kf.inTangent then
				kf.inTangent = FollowAnchor.worldDeltaToStoredOffset(track, kf.inTangent, resolver)
			end
		end
	end

	if followBinding == nil or followBinding == "" then
		if hadFollow then
			keyframesToWorld()
		end
		track.followBinding = nil
		track.followPart = nil
	else
		local prevBinding = track.followBinding
		local switchingAnchor = hadFollow
			and prevBinding ~= nil
			and prevBinding ~= ""
			and prevBinding ~= followBinding

		if switchingAnchor then
			-- 换绑(Rig1→Player 等):保持 key / 切线相对数值不变,只改逻辑名;求值变为 anchor_new * relative。
			track.followBinding = followBinding
			track.followPart = followPart or "HumanoidRootPart"
		else
			if hadFollow then
				keyframesToWorld()
			end
			track.followBinding = followBinding
			track.followPart = followPart or "HumanoidRootPart"
			keyframesToRelative()
		end
	end

	self:commitTracks(true)
end

-- setDuration / fitDurationToContent 见「动画片段」段后的 clamp  helpers

--========================= 关键帧编辑 =========================--

-- 在某轨道按时间有序插入/覆盖一个 CFrame 关键帧(内部用,不压快照)
local function upsertKeyframe(track: CutsceneFormat.Track, t: number, cf: CFrame, easing: string?)
	local kfs = track.keyframes
	if not kfs then
		kfs = {}
		track.keyframes = kfs
	end
	assert(kfs, "keyframes 初始化失败")
	for _, k in kfs do
		if math.abs(k.t - t) < 1e-3 then
			k.value = cf
			k.easing = easing or k.easing
			return
		end
	end
	table.insert(kfs, { t = t, value = cf, easing = easing })
	table.sort(kfs, function(a, b)
		return a.t < b.t
	end)
end

-- 在 transform / cameraMove 轨道打一个 CFrame 关键帧(t 缺省 = 当前播放头时间)
function EditorState.captureFrame(
	self: EditorState,
	track: CutsceneFormat.Track,
	cf: CFrame,
	t: number?
)
	if track.kind ~= "transform" and track.kind ~= "cameraMove" and track.kind ~= "camera" then
		return
	end
	self:pushUndo()
	upsertKeyframe(track, t or self.currentTime:get(), cf, "cubicInOut")
	self:commitTracks(true)
end

-- 录制专用打帧:不压快照(整段录制由 Recorder 在开始时压一次,算一步撤销)。
function EditorState.captureFrameNoUndo(self: EditorState, track: CutsceneFormat.Track, cf: CFrame)
	if track.kind ~= "transform" and track.kind ~= "cameraMove" and track.kind ~= "camera" then
		return
	end
	upsertKeyframe(track, self.currentTime:get(), cf, "cubicInOut")
	self:commitTracks(true)
end

-- 播放头是否落在两关键帧之间(贝塞尔段内插 K 用)。
function EditorState.bracketKeyframeInterval(
	track: CutsceneFormat.Track,
	t: number
): (CutsceneFormat.Keyframe?, CutsceneFormat.Keyframe?)
	local kfs = track.keyframes
	if not kfs or #kfs < 2 then
		return nil
	end
	sortKeyframes(track)
	for i = 1, #kfs - 1 do
		local a = kfs[i]
		local b = kfs[i + 1]
		if t > a.t + 1e-4 and t < b.t - 1e-4 then
			return a, b
		end
	end
	return nil
end

-- 在路径段内 t 处插入关键帧(采样当前曲线位姿;新 key 切线默认 0)。需 pathMode=bezier。
function EditorState.insertPathKeyframeAt(self: EditorState, track: CutsceneFormat.Track, t: number)
	if track.kind ~= "camera" and track.kind ~= "cameraMove" then
		return
	end
	if track.pathMode ~= "bezier" then
		return
	end
	local left, right = EditorState.bracketKeyframeInterval(track, t)
	if not left or not right then
		return
	end
	local sampled = Sampler.sampleTrackCFrame(track, t)
	if not sampled then
		return
	end
	self:pushUndo()
	local kfs = track.keyframes
	if not kfs then
		kfs = {}
		track.keyframes = kfs
	end
	assert(kfs, "keyframes 初始化失败")
	table.insert(kfs, {
		t = t,
		value = sampled,
		easing = right.easing or "cubicInOut",
	})
	sortKeyframes(track)
	self:commitTracks(true)
end

function EditorState.insertPathKeyframeMidpoint(
	self: EditorState,
	track: CutsceneFormat.Track,
	leftKf: CutsceneFormat.Keyframe,
	rightKf: CutsceneFormat.Keyframe
)
	local fps = self.fps:get()
	local t = math.round((leftKf.t + rightKf.t) * 0.5 * fps) / fps
	self:insertPathKeyframeAt(track, t)
end

-- 删除某关键帧(对象引用)
function EditorState.removeKeyframe(
	self: EditorState,
	track: CutsceneFormat.Track,
	kf: CutsceneFormat.Keyframe
)
	if not track.keyframes then
		return
	end
	for i, k in track.keyframes do
		if k == kf then
			self:pushUndo()
			table.remove(track.keyframes, i)
			self:commitTracks(true)
			return
		end
	end
end

-- 复制某关键帧到 +0.5s 处
function EditorState.duplicateKeyframe(
	self: EditorState,
	track: CutsceneFormat.Track,
	kf: CutsceneFormat.Keyframe
)
	if not track.keyframes then
		return
	end
	self:pushUndo()
	local t = math.min(kf.t + 0.5, self.duration:get())
	upsertKeyframe(track, t, kf.value or CFrame.new(), kf.easing)
	self:commitTracks(true)
end

-- 拖拽:移动关键帧时间(不压快照;不排序,拖拽结束再 finishDrag 排序)
function EditorState.moveKeyframe(self: EditorState, kf: CutsceneFormat.Keyframe, newT: number)
	kf.t = math.clamp(newT, 0, self.duration:get())
	self:commitTracks(false)
end

--========================= 缓动 =========================--

-- 设置某关键帧/片段的缓动名
function EditorState.setEasing(
	self: EditorState,
	obj: { easing: CutsceneFormat.EasingName? },
	easing: CutsceneFormat.EasingName
)
	self:pushUndo()
	obj.easing = easing
	self:commitTracks(true)
end

--========================= 属性轨(17 spec) =========================--

local SUPPORTED_PROP_TYPES: { [string]: boolean } = {
	number = true,
	boolean = true,
	Vector3 = true,
	Color3 = true,
}

-- 读目标实例上的属性当前值;失败返回 nil + 原因。
function EditorState.readPropertyValue(
	target: string,
	propertyName: string
): (CutsceneFormat.PropValue?, string?)
	local inst = SceneResolver.resolve(target)
	if not inst then
		return nil, `找不到绑定 '{target}'`
	end
	local ok, v = pcall(function()
		return (inst :: any)[propertyName]
	end)
	if not ok then
		return nil, `'{inst.Name}' 上读不到属性 '{propertyName}'`
	end
	if not SUPPORTED_PROP_TYPES[typeof(v)] then
		return nil, `属性 '{propertyName}' 类型 {typeof(v)} 暂不支持(V1:number/boolean/Vector3/Color3)`
	end
	return v :: CutsceneFormat.PropValue, nil
end

-- 新建属性轨。建轨即校验:属性读不到/类型不支持就地拒绝(17 spec)。
-- 返回 (索引, nil) 或 (nil, 错误信息)。
function EditorState.addPropertyTrack(
	self: EditorState,
	target: string,
	propertyName: string,
	group: string?
): (number?, string?)
	if propertyName == "FieldOfView" then
		return nil, "相机 FOV 请用相机轨的 FOV 关键帧,不走属性轨"
	end
	local value, err = EditorState.readPropertyValue(target, propertyName)
	if err then
		return nil, err
	end
	self:pushUndo()
	local tracks = self.tracks:get()
	table.insert(tracks, {
		kind = "property" :: CutsceneFormat.TrackKind,
		target = target,
		name = TimelineUnity.defaultTrackName("property"),
		group = group,
		propertyName = propertyName,
		propKeyframes = {
			-- 首帧 = 当前值:轨道一建立即有可见语义(t=0 保持原状)
			{ t = 0, value = value :: CutsceneFormat.PropValue },
		},
	})
	self:commitTracks(true)
	return #tracks, nil
end

local function sortPropKeyframes(track: CutsceneFormat.Track)
	if track.propKeyframes then
		table.sort(track.propKeyframes, function(a, b)
			return a.t < b.t
		end)
	end
end

local function upsertPropKeyframe(
	track: CutsceneFormat.Track,
	t: number,
	value: CutsceneFormat.PropValue,
	easing: CutsceneFormat.EasingName?
)
	local kfs = track.propKeyframes
	if not kfs then
		kfs = {}
		track.propKeyframes = kfs
	end
	assert(kfs, "propKeyframes 初始化失败")
	for _, k in kfs do
		if math.abs(k.t - t) < 1e-3 then
			k.value = value
			k.easing = easing or k.easing
			return
		end
	end
	table.insert(kfs, { t = t, value = value, easing = easing })
	sortPropKeyframes(track)
end

-- 属性轨打帧。value=nil → 读目标当前值("以当前值打帧",Record 式手感)。
function EditorState.capturePropFrame(
	self: EditorState,
	track: CutsceneFormat.Track,
	value: CutsceneFormat.PropValue?,
	t: number?
): string?
	if track.kind ~= "property" or not track.propertyName then
		return "非属性轨"
	end
	local v = value
	if v == nil then
		local read, err = EditorState.readPropertyValue(track.target, track.propertyName)
		if err then
			return err
		end
		v = read
	end
	self:pushUndo()
	upsertPropKeyframe(track, t or self.currentTime:get(), v :: CutsceneFormat.PropValue, nil)
	self:commitTracks(true)
	return nil
end

function EditorState.removePropKeyframe(
	self: EditorState,
	track: CutsceneFormat.Track,
	kf: CutsceneFormat.PropKeyframe
)
	if not track.propKeyframes then
		return
	end
	for i, k in track.propKeyframes do
		if k == kf then
			self:pushUndo()
			table.remove(track.propKeyframes, i)
			self:commitTracks(true)
			return
		end
	end
end

function EditorState.duplicatePropKeyframe(
	self: EditorState,
	track: CutsceneFormat.Track,
	kf: CutsceneFormat.PropKeyframe
)
	if not track.propKeyframes then
		return
	end
	self:pushUndo()
	local t = math.min(kf.t + 0.5, self.duration:get())
	upsertPropKeyframe(track, t, kf.value, kf.easing)
	self:commitTracks(true)
end

-- 拖拽:移动属性关键帧时间(不压快照;结束调 finishPropDrag 排序)
function EditorState.movePropKeyframe(
	self: EditorState,
	kf: CutsceneFormat.PropKeyframe,
	newT: number
)
	kf.t = math.clamp(newT, 0, self.duration:get())
	self:commitTracks(false)
end

function EditorState.finishPropDrag(self: EditorState, track: CutsceneFormat.Track)
	sortPropKeyframes(track)
	self:commitTracks(true)
end

function EditorState.setTrackKeepOnDone(
	self: EditorState,
	track: CutsceneFormat.Track,
	keep: boolean
)
	self:pushUndo()
	track.keepOnDone = if keep then true else nil
	self:commitTracks(true)
end

function EditorState.setPropKeyframeValue(
	self: EditorState,
	_track: CutsceneFormat.Track,
	kf: CutsceneFormat.PropKeyframe,
	value: CutsceneFormat.PropValue
)
	self:pushUndo()
	kf.value = value
	self:commitTracks(true)
end

--========================= 动画片段(clip)编辑 =========================--

local AnimationAsset = require(script.Parent.AnimationAsset)

local function minClipSec(fps: number): number
	return 1 / math.max(fps, 1)
end

-- 同轨 clip 不重叠;保证 endAt > startAt。
local function resolveClipOverlaps(
	clips: { CutsceneFormat.AnimationClip },
	dur: number,
	fps: number
)
	table.sort(clips, function(a, b)
		return a.startAt < b.startAt
	end)
	local minLen = minClipSec(fps)
	local i = 1
	while i <= #clips do
		local c = clips[i]
		c.startAt = math.clamp(c.startAt, 0, dur)
		if not c.endAt then
			c.endAt = math.min(dur, c.startAt + 1.5)
		end
		c.endAt = math.clamp(c.endAt, 0, dur)
		if c.endAt < c.startAt + minLen then
			c.endAt = math.min(dur, c.startAt + minLen)
		end
		if i > 1 then
			local prev = clips[i - 1]
			local prevEnd = prev.endAt or prev.startAt + 1.5
			if c.startAt < prevEnd then
				c.startAt = prevEnd
				if c.endAt < c.startAt + minLen then
					c.endAt = math.min(dur, c.startAt + minLen)
				end
			end
		end
		if c.endAt <= c.startAt then
			table.remove(clips, i)
			continue
		end
		i += 1
	end
end

local CONTENT_TAIL_SEC = 0.5

local function trackContentEnd(tr: CutsceneFormat.Track): number
	local maxT = 0
	if tr.keyframes then
		for _, k in tr.keyframes do
			maxT = math.max(maxT, k.t)
		end
	end
	if tr.clips then
		for _, c in tr.clips do
			local endT = c.endAt or (c.startAt + 1.5)
			maxT = math.max(maxT, c.startAt, endT)
		end
	end
	if tr.propKeyframes then
		for _, k in tr.propKeyframes do
			maxT = math.max(maxT, k.t)
		end
	end
	if tr.jointTracks then
		for _, jt in tr.jointTracks do
			local last = jt.keyframes[#jt.keyframes]
			if last then
				maxT = math.max(maxT, last.t)
			end
		end
	end
	if tr.segments then
		for _, s in tr.segments do
			maxT = math.max(maxT, s.from, s.to)
		end
	end
	if tr.from then
		maxT = math.max(maxT, tr.from)
	end
	if tr.to then
		maxT = math.max(maxT, tr.to)
	end
	if tr.events then
		for _, ev in tr.events do
			maxT = math.max(maxT, ev.t)
		end
	end
	if tr.soundCues then
		for _, c in tr.soundCues do
			maxT = math.max(maxT, c.t)
		end
	end
	if tr.effectCues then
		for _, c in tr.effectCues do
			maxT = math.max(maxT, c.t)
			if c.duration then
				maxT = math.max(maxT, c.t + c.duration)
			end
		end
	end
	return maxT
end

local function clampAllTracksToDuration(tracks: { CutsceneFormat.Track }, dur: number, fps: number)
	for _, tr in tracks do
		if tr.keyframes then
			for _, k in tr.keyframes do
				k.t = math.clamp(k.t, 0, dur)
			end
		end
		if tr.clips then
			local i = 1
			while i <= #tr.clips do
				local c = tr.clips[i]
				c.startAt = math.clamp(c.startAt, 0, dur)
				if c.startAt >= dur - 1e-6 then
					table.remove(tr.clips, i)
					continue
				end
				if c.endAt then
					c.endAt = math.clamp(c.endAt, 0, dur)
				else
					c.endAt = math.min(dur, c.startAt + 1.5)
				end
				if c.endAt <= c.startAt then
					table.remove(tr.clips, i)
					continue
				end
				i += 1
			end
			resolveClipOverlaps(tr.clips, dur, fps)
		end
		if tr.segments then
			for _, s in tr.segments do
				s.from = math.clamp(s.from, 0, dur)
				s.to = math.clamp(s.to, 0, dur)
			end
			resolveSegmentOverlaps(tr.segments, dur)
		end
		if tr.from then
			tr.from = math.clamp(tr.from, 0, dur)
		end
		if tr.to then
			tr.to = math.clamp(tr.to, 0, dur)
		end
		if tr.events then
			for _, ev in tr.events do
				ev.t = math.clamp(ev.t, 0, dur)
			end
		end
		if tr.soundCues then
			for _, c in tr.soundCues do
				c.t = math.clamp(c.t, 0, dur)
			end
		end
		if tr.effectCues then
			for _, c in tr.effectCues do
				c.t = math.clamp(c.t, 0, dur)
			end
		end
		if tr.propKeyframes then
			for _, k in tr.propKeyframes do
				k.t = math.clamp(k.t, 0, dur)
			end
		end
		if tr.jointTracks then
			for _, jt in tr.jointTracks do
				for _, k in jt.keyframes do
					k.t = math.clamp(k.t, 0, dur)
				end
			end
		end
	end
end

-- 过场总时长(秒),量化到帧;缩短时 clamp 全部轨道内容。
function EditorState.setDuration(self: EditorState, duration: number)
	self:pushUndo()
	local fps = math.max(self.fps:get(), 1)
	local minDur = 1 / fps
	local dur = math.max(math.round(duration * fps) / fps, minDur)
	local old = self.duration:get()
	local tracks = self.tracks:get()
	if dur < old - 1e-6 then
		clampAllTracksToDuration(tracks, dur, fps)
	end
	self.duration:set(dur)
	self:setTime(self.currentTime:get())
	self:commitTracks(true)
end

function EditorState.setTotalFrames(self: EditorState, totalFrames: number)
	local fps = math.max(self.fps:get(), 1)
	self:setDuration(math.max(totalFrames, 1) / fps)
end

function EditorState.computeContentEnd(self: EditorState, selectedTrackIndex: number?): number
	if selectedTrackIndex then
		local tr = self.tracks:get()[selectedTrackIndex]
		if not tr then
			return 0
		end
		return trackContentEnd(tr)
	end
	local maxT = 0
	for _, tr in self.tracks:get() do
		maxT = math.max(maxT, trackContentEnd(tr))
	end
	return maxT
end

-- selectedOnly: true = 仅选中轨;无选中则 warn 并 return
function EditorState.fitDurationToContent(self: EditorState, selectedOnly: boolean)
	local fps = math.max(self.fps:get(), 1)
	local idx = self.selectedTrack:get()
	if selectedOnly then
		if not idx then
			warn("[anima] 请先选中一条轨道,或使用「适应全部内容」")
			return
		end
	else
		idx = nil
	end
	local contentEnd = self:computeContentEnd(idx)
	local newDur = math.max(1 / fps, math.round((contentEnd + CONTENT_TAIL_SEC) * fps) / fps)
	self:setDuration(newDur)
end

local function sortClips(track: CutsceneFormat.Track)
	if track.clips then
		table.sort(track.clips, function(a, b)
			return a.startAt < b.startAt
		end)
	end
end

-- 在 animation 轨道当前时间加一个动画片段。
function EditorState.addClip(
	self: EditorState,
	track: CutsceneFormat.Track,
	animationId: string,
	startAt: number?
)
	if track.kind ~= "animation" then
		return
	end
	self:pushUndo()
	local clips = track.clips
	if not clips then
		clips = {}
		track.clips = clips
	end
	assert(clips, "clips 初始化失败")
	local start = startAt or self.currentTime:get()
	local fps = self.fps:get()
	local endAt = math.min(self.duration:get(), start + math.max(1.5, minClipSec(fps) * 2))
	table.insert(clips, {
		animationId = animationId,
		startAt = start,
		endAt = endAt,
		fadeTime = 0.1,
		speed = 1,
		looped = false,
	})
	sortClips(track)
	resolveClipOverlaps(clips, self.duration:get(), fps)
	self:commitTracks(true)
	if animationId ~= "" and animationId ~= "rbxassetid://0" then
		task.defer(function()
			self:syncClipLengthFromAsset(clips[#clips], track, nil)
		end)
	end
end

function EditorState.removeClip(
	self: EditorState,
	track: CutsceneFormat.Track,
	clip: CutsceneFormat.AnimationClip
)
	if not track.clips then
		return
	end
	for i, c in track.clips do
		if c == clip then
			self:pushUndo()
			table.remove(track.clips, i)
			self:commitTracks(true)
			return
		end
	end
end

-- 设置片段某字段(animationId / speed / looped / fadeTime)。
function EditorState.setClipField(
	self: EditorState,
	clip: CutsceneFormat.AnimationClip,
	field: string,
	value: any
)
	self:pushUndo();
	(clip :: any)[field] = value
	self:commitTracks(true)
end

-- 拖拽:移动片段起播时间(不压快照;不排序)
function EditorState.moveClip(self: EditorState, clip: CutsceneFormat.AnimationClip, newT: number)
	local dur = self.duration:get()
	local len = (clip.endAt or clip.startAt + 1.5) - clip.startAt
	newT = math.clamp(newT, 0, math.max(0, dur - len))
	clip.startAt = newT
	if clip.endAt then
		clip.endAt = math.min(dur, newT + len)
	end
	self:commitTracks(false)
end

function EditorState.setClipEndAt(
	self: EditorState,
	clip: CutsceneFormat.AnimationClip,
	endAt: number
)
	local dur = self.duration:get()
	local fps = self.fps:get()
	local minLen = minClipSec(fps)
	clip.endAt = math.clamp(endAt, clip.startAt + minLen, dur)
	self:commitTracks(false)
end

function EditorState.finishClipDrag(self: EditorState, track: CutsceneFormat.Track)
	if track.clips then
		resolveClipOverlaps(track.clips, self.duration:get(), self.fps:get())
	end
	self:finishDrag()
end

-- 改 AnimationId 并按源动画 Length 写入 endAt(不改变过场总时长)。
function EditorState.syncClipLengthFromAsset(
	self: EditorState,
	clip: CutsceneFormat.AnimationClip,
	track: CutsceneFormat.Track,
	model: Model?
)
	local sourceLen =
		AnimationAsset.resolveSourceLength(clip.animationId, { clip = clip, model = model })
	if not sourceLen or sourceLen <= 0 then
		warn(`[anima] 无法读取动画时长:{clip.animationId}`)
		return
	end
	local fps = math.max(self.fps:get(), 1)
	local speed = clip.speed or 1
	local window = sourceLen / speed
	window = math.round(window * fps) / fps
	local dur = self.duration:get()
	clip.endAt = math.min(dur, clip.startAt + math.max(window, minClipSec(fps)))
	if track.clips then
		resolveClipOverlaps(track.clips, dur, fps)
	end
	self:commitTracks(true)
end

function EditorState.applyClipAnimationId(
	self: EditorState,
	track: CutsceneFormat.Track,
	clip: CutsceneFormat.AnimationClip,
	animationId: string,
	model: Model?
)
	if animationId == "" then
		return
	end
	self:pushUndo()
	clip.animationId = animationId
	self:commitTracks(true)
	task.defer(function()
		self:syncClipLengthFromAsset(clip, track, model)
	end)
end

--========================= 事件(event)编辑 =========================--

local function sortEvents(track: CutsceneFormat.Track)
	if track.events then
		table.sort(track.events, function(a, b)
			return a.t < b.t
		end)
	end
end

-- 在 event 轨道当前时间加一个事件。
-- 整表替换事件 payload(nil = 清除)。不原地改,配合撤销快照。19 spec。
function EditorState.setEventPayload(
	self: EditorState,
	_track: CutsceneFormat.Track,
	ev: CutsceneFormat.CutsceneEvent,
	payload: { [string]: any }?
)
	self:pushUndo()
	ev.payload = payload
	self:commitTracks(true)
end

function EditorState.addEvent(
	self: EditorState,
	track: CutsceneFormat.Track,
	name: string,
	t: number?
)
	if track.kind ~= "event" then
		return
	end
	self:pushUndo()
	local events = track.events
	if not events then
		events = {}
		track.events = events
	end
	assert(events, "events 初始化失败")
	table.insert(events, { t = t or self.currentTime:get(), name = name })
	sortEvents(track)
	self:commitTracks(true)
end

function EditorState.removeEvent(
	self: EditorState,
	track: CutsceneFormat.Track,
	event: CutsceneFormat.CutsceneEvent
)
	if not track.events then
		return
	end
	for i, ev in track.events do
		if ev == event then
			self:pushUndo()
			table.remove(track.events, i)
			self:commitTracks(true)
			return
		end
	end
end

function EditorState.renameEvent(
	self: EditorState,
	event: CutsceneFormat.CutsceneEvent,
	name: string
)
	self:pushUndo()
	event.name = name
	self:commitTracks(true)
end

-- 拖拽:移动事件时间(不压快照;不排序)
function EditorState.moveEvent(self: EditorState, event: CutsceneFormat.CutsceneEvent, newT: number)
	event.t = math.clamp(newT, 0, self.duration:get())
	self:commitTracks(false)
end

--========================= 音效(sound) / 特效(effect) cue =========================--

local function sortSoundCues(track: CutsceneFormat.Track)
	if track.soundCues then
		table.sort(track.soundCues, function(a, b)
			return a.t < b.t
		end)
	end
end

local function sortEffectCues(track: CutsceneFormat.Track)
	if track.effectCues then
		table.sort(track.effectCues, function(a, b)
			return a.t < b.t
		end)
	end
end

function EditorState.addSoundCue(
	self: EditorState,
	track: CutsceneFormat.Track,
	soundId: string,
	t: number?
)
	if track.kind ~= "sound" then
		return
	end
	self:pushUndo()
	local cues = track.soundCues
	if not cues then
		cues = {}
		track.soundCues = cues
	end
	table.insert(cues, {
		t = t or self.currentTime:get(),
		soundId = soundId,
		volume = 1,
	})
	sortSoundCues(track)
	self:commitTracks(true)
end

function EditorState.removeSoundCue(
	self: EditorState,
	track: CutsceneFormat.Track,
	cue: CutsceneFormat.SoundCue
)
	if not track.soundCues then
		return
	end
	for i, c in track.soundCues do
		if c == cue then
			self:pushUndo()
			table.remove(track.soundCues, i)
			self:commitTracks(true)
			return
		end
	end
end

function EditorState.setSoundCueField(
	self: EditorState,
	cue: CutsceneFormat.SoundCue,
	field: string,
	value: any
)
	self:pushUndo();
	(cue :: any)[field] = value
	self:commitTracks(true)
end

function EditorState.moveSoundCue(self: EditorState, cue: CutsceneFormat.SoundCue, newT: number)
	cue.t = math.clamp(newT, 0, self.duration:get())
	self:commitTracks(false)
end

function EditorState.addEffectCue(
	self: EditorState,
	track: CutsceneFormat.Track,
	templateName: string?,
	particleAssetId: string?,
	t: number?,
	emitMode: CutsceneFormat.EffectEmitMode?,
	forgeRoot: string?
)
	if track.kind ~= "effect" then
		return
	end
	self:pushUndo()
	local cues = track.effectCues
	if not cues then
		cues = {}
		track.effectCues = cues
	end
	local mode = emitMode or "particle"
	table.insert(cues, {
		t = t or self.currentTime:get(),
		emitMode = if mode == "particle" then nil else mode,
		templateName = templateName,
		particleAssetId = particleAssetId,
		emitCount = 1,
		duration = 3,
		forgeRoot = if mode == "forge" then forgeRoot else nil,
		forgeScale = if mode == "forge" then 1 else nil,
	})
	sortEffectCues(track)
	self:commitTracks(true)
end

function EditorState.removeEffectCue(
	self: EditorState,
	track: CutsceneFormat.Track,
	cue: CutsceneFormat.EffectCue
)
	if not track.effectCues then
		return
	end
	for i, c in track.effectCues do
		if c == cue then
			self:pushUndo()
			table.remove(track.effectCues, i)
			self:commitTracks(true)
			return
		end
	end
end

function EditorState.setEffectCueField(
	self: EditorState,
	cue: CutsceneFormat.EffectCue,
	field: string,
	value: any
)
	self:pushUndo();
	(cue :: any)[field] = value
	self:commitTracks(true)
end

function EditorState.moveEffectCue(self: EditorState, cue: CutsceneFormat.EffectCue, newT: number)
	cue.t = math.clamp(newT, 0, self.duration:get())
	self:commitTracks(false)
end

-- 一段拖拽结束:重新排序涉及的轨道并做一次结构性提交(刷新预览/轨迹)。
function EditorState.finishDrag(self: EditorState)
	for _, tr in self.tracks:get() do
		sortKeyframes(tr)
		sortPropKeyframes(tr)
		sortClips(tr)
		sortEvents(tr)
		sortSoundCues(tr)
		sortEffectCues(tr)
	end
	self:commitTracks(true)
end

--========================= 导出 =========================--

-- 导出成纯 Cutscene 数据(供序列化 / 预览求值)
function EditorState.toCutscene(self: EditorState): CutsceneFormat.Cutscene
	return {
		name = self.name:get(),
		duration = self.duration:get(),
		fps = self.fps:get(),
		takeCameraControl = true,
		tracks = self.tracks:get(),
	}
end

-- 整表替换(导入 / 新建 / 恢复草稿);清空撤销栈并重建预览。
function EditorState.loadCutscene(self: EditorState, cutscene: CutsceneFormat.Cutscene)
	-- 整体替换也压一步撤销:误点「新建/导入/打开」可 Ctrl+Z 找回原内容。
	self:pushUndo()
	self.name:set(cutscene.name)
	self.duration:set(cutscene.duration)
	self.fps:set(cutscene.fps or 30)
	self.tracks:set(cloneTracks(cutscene.tracks))
	self.selectedTrack:set(nil)
	self:setTime(0)
	self.revision:set(self.revision:get() + 1)
end

function EditorState.emptyUntitled(): CutsceneFormat.Cutscene
	return {
		name = "untitled",
		duration = 5,
		tracks = {},
	}
end

return EditorState
