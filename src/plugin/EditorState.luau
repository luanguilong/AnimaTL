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

local Value = Fusion.Value

local EditorState = {}
EditorState.__index = EditorState

local TimelineUnity = require(script.Parent.TimelineUnity)

type Snapshot = {
	name: string,
	duration: number,
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
			table.insert(kf, { t = k.t, value = k.value, easing = k.easing })
		end
	end
	local clips = nil
	if tr.clips then
		clips = {}
		for _, c in tr.clips do
			table.insert(clips, {
				animationId = c.animationId,
				startAt = c.startAt,
				fadeTime = c.fadeTime,
				speed = c.speed,
				looped = c.looped,
			})
		end
	end
	local events = nil
	if tr.events then
		events = {}
		for _, ev in tr.events do
			table.insert(events, { t = ev.t, name = ev.name, payload = ev.payload })
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
		segments = segments,
		from = if segments then nil else tr.from,
		to = if segments then nil else tr.to,
		smooth = tr.smooth,
		keyframes = kf,
		clips = clips,
		events = events,
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
	local track: CutsceneFormat.Track =
		{ kind = kind, target = target, name = name or TimelineUnity.defaultTrackName(kind), group = group }
	if kind == "transform" or kind == "cameraMove" then
		track.keyframes = {}
	elseif kind == "animation" then
		track.clips = {}
	elseif kind == "event" then
		track.events = {}
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

-- 在某相机轨的时刻 t 处新增一段(默认 2 秒,夹到总时长,尽量避开已有段)。
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
	table.insert(segs, { from = from, to = math.min(from + 2, nextFrom, dur) })
	table.sort(segs, function(a, b)
		return a.from < b.from
	end)
	self:commitTracks(true)
end

-- 删除某相机轨的第 index 段。
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
	table.sort(segs, function(a, b)
		return a.from < b.from
	end)
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

function EditorState.setDuration(self: EditorState, duration: number)
	self:pushUndo()
	self.duration:set(math.max(duration, 0.1))
	self:setTime(self.currentTime:get())
	self:commitTracks(true)
end

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

--========================= 动画片段(clip)编辑 =========================--

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
	table.insert(clips, {
		animationId = animationId,
		startAt = startAt or self.currentTime:get(),
		fadeTime = 0.1,
		speed = 1,
		looped = false,
	})
	sortClips(track)
	self:commitTracks(true)
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
	clip.startAt = math.clamp(newT, 0, self.duration:get())
	self:commitTracks(false)
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

-- 一段拖拽结束:重新排序涉及的轨道并做一次结构性提交(刷新预览/轨迹)。
function EditorState.finishDrag(self: EditorState)
	for _, tr in self.tracks:get() do
		sortKeyframes(tr)
		sortClips(tr)
		sortEvents(tr)
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

return EditorState
