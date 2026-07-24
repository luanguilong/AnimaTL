--!strict
-- App — Timeline 面板根组件(Fusion)。
-- 结构:顶部工具条 / 内嵌预览横条(可折叠) / vcam 管理条 / 左轨道名列 / 右时间轴。
--
-- 交互(时间轴内统一长按拖拽:按住 HOLD_SEC 后跟随;全程须按住左键,松开即放下;Alt=自由不吸附):
--   相机段块 — 中间长按整段平移;左右缘长按改 from/to;松手 finishCameraSegmentDrag;短按中间选中
--   关键帧/片段/事件(6) — 拖改时间,右键菜单
--   播放头(10) + 标尺(11) — 仅标尺行拖/长按 scrub;红线纯点击不跳
--   轨道空白 — 点击取消选中,不移动播放头
--   关键帧/片段/事件 — 点击不跳播放头(定位见右键菜单);相机类关键帧双击菱形=播放头+主视口跳转
-- 时间轴内容套横向 ScrollingFrame,宽度=zoom×视口(右下角缩放按钮);时间按帧(fps)显示与吸附。
-- 数据编辑直接调 EditorState(含撤销栈);vcam / 相机等 DataModel 副作用走回调。

local UserInputService = game:GetService("UserInputService")
local Selection = game:GetService("Selection")

local Fusion = require(script.Parent.Packages.Fusion)
local Theme = require(script.Parent.Theme)
local EditorState = require(script.Parent.EditorState)
local DragController = require(script.Parent.DragController)
local ContextMenu = require(script.Parent.ContextMenu)
local InputPrompt = require(script.Parent.InputPrompt)
local CutsceneFormat = require(script.Parent.Shared.CutsceneFormat)
local VCam = require(script.Parent.Shared.VCam)
local Sampler = require(script.Parent.Shared.Sampler)
local TimelineUnity = require(script.Parent.TimelineUnity)
local AnimationAsset = require(script.Parent.AnimationAsset)
local Easing = require(script.Parent.Shared.Easing)
local OverlayHost = require(script.Parent.OverlayHost)
local BindingDrop = require(script.Parent.BindingDrop)
local BindingFromInstance = require(script.Parent.BindingFromInstance)

local New = Fusion.New
local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local Computed = Fusion.Computed

-- 缓动菜单中文标签(仅显示层;数据仍存英文名,见 Easing.names)
local EASING_CN: { [string]: string } = {
	linear = "匀速",
	quadIn = "缓入(慢起步)",
	quadOut = "缓出(慢收尾)",
	quadInOut = "缓入缓出",
	cubicInOut = "缓入缓出(更强)",
	sine = "正弦(柔和)",
	expoIn = "急加速",
	expoOut = "急减速",
	expoInOut = "急进急出",
	backIn = "回拉起步",
	backOut = "过冲回落",
	backInOut = "回拉+过冲",
	elasticOut = "弹性(橡皮筋)",
	bounceOut = "弹跳落地",
}

local function easingMenuText(ez: string): string
	local cn = EASING_CN[ez]
	return if cn then "  " .. cn .. " · " .. ez else "  " .. ez
end

local SNAP_PX = 8 -- 吸附像素阈值
local HOLD_SEC = 0.1 -- 时间轴:按住满此时长后进入拖拽;拖动全程须保持按住,松开即放下
local SEGMENT_EDGE_PX = 10 -- 蓝条左右改长度热区(像素)
local SEGMENT_EDGE_BAR_PX = 3 -- 缘上可见竖条宽(原 6,减半)

-- 正在拖动播放头(scrub)时为 true,供把手时间提示条显示
local playheadScrubbing = Fusion.Value(false)
local playheadHandleHover = Fusion.Value(false)

local function beginTimelineDrag(
	gui: PluginGui,
	handlers: DragController.Handlers,
	feedback: GuiObject?,
	pressInput: InputObject?
)
	handlers.holdTime = HOLD_SEC
	handlers.holdDrag = true
	handlers.feedbackElement = feedback
	handlers.pressInput = pressInput
	if feedback and not handlers.pressSource then
		handlers.pressSource = feedback
	end
	DragController.begin(gui, handlers)
end

-- 轨道名双击重命名(两次点击间隔 < 0.35s)
local renameDbl: { track: CutsceneFormat.Track?, at: number } = { track = nil, at = 0 }

-- 相机类关键帧菱形:双击跳转视口(间隔 < 0.35s,与轨道重命名一致)
local kfJumpDbl: {
	track: CutsceneFormat.Track?,
	kf: CutsceneFormat.Keyframe?,
	at: number,
} =
	{ track = nil, kf = nil, at = 0 }

local CAMERA_CREATE_HINT = "🎥 相机轨请用顶栏「＋ 相机」"

local function onTrackTitleClick(
	gui: PluginGui,
	state: EditorState.EditorState,
	track: CutsceneFormat.Track,
	trackIndex: number?
)
	if trackIndex then
		state.selectedTrack:set(trackIndex)
	end
	local now = os.clock()
	if renameDbl.track == track and now - renameDbl.at < 0.35 then
		renameDbl.track = nil
		InputPrompt.show(gui, {
			title = "轨道名称",
			default = TimelineUnity.trackTitle(track),
			onSubmit = function(txt)
				if txt ~= "" then
					state:renameTrack(track, txt)
				end
			end,
		})
	else
		renameDbl.track = track
		renameDbl.at = now
	end
end

local App = {}

export type Callbacks = {
	isPlaying: Fusion.Value<boolean>,
	loop: Fusion.Value<boolean>,
	mainPreviewActive: Fusion.Value<boolean>,
	recordActive: Fusion.Value<boolean>,
	onPlayPause: () -> (),
	onToStart: () -> (),
	onToggleLoop: () -> (),
	onToggleRecord: () -> (),
	onToggleMainPreview: () -> (),
	onAddVcam: () -> (),
	onLookThrough: () -> (),
	onExport: (gui: PluginGui) -> (),
	onNewDocument: () -> (),
	onRestoreDraft: () -> (),
	onImportMenu: (gui: PluginGui) -> (),
	onSaveAsModule: (gui: PluginGui) -> (),
	mountPreview: (container: Instance) -> (),
	-- vcam / 场景相关副作用
	onSelectVcam: (name: string) -> (),
	onDeleteVcam: (name: string) -> (),
	onRenameVcam: (old: string, new: string) -> (),
	onSetVcamFov: (name: string, fov: number) -> (),
	onSetVcamLookAt: (name: string, target: string) -> (),
	onRecaptureVcam: (name: string) -> (),
	onCaptureTransform: (track: CutsceneFormat.Track, t: number?) -> (),
	onCaptureCameraMove: (track: CutsceneFormat.Track, t: number?) -> (),
	onCaptureCameraTrack: (track: CutsceneFormat.Track, t: number?) -> (),
	onCaptureAtPlayhead: () -> (), -- 顶栏/快捷键 K:当前选中 camera 轨
	-- 实时预览(跟随主视口):开启后内嵌预览 = 主视口位姿 + 选中轨自己的 FOV,K 全局打帧
	viewportFollow: Fusion.Value<boolean>,
	authoringMode: Fusion.Value<boolean>,
	recordingCam: Fusion.Value<string?>, -- 正在录制的相机轨 target(nil=无)
	onCameraRecord: (track: CutsceneFormat.Track) -> (),
	-- 双击相机关键帧:播放头 + 主视口一次性跳到该帧位姿(非 KeyframeAdjust)
	onJumpToCameraKeyframe: (track: CutsceneFormat.Track, kf: CutsceneFormat.Keyframe) -> (),
	targetCandidates: () -> { string },
	characterCandidates: () -> { string }, -- 动画轨用:带 Humanoid 骨骼的候选
	-- 视口对帧调整(相机类关键帧反向编辑)
	adjustingKf: Fusion.Value<CutsceneFormat.Keyframe?>, -- 正在调整的关键帧(nil=无)
	onAdjustKeyframe: (track: CutsceneFormat.Track, kf: CutsceneFormat.Keyframe) -> (), -- 开/关
	onStopAdjust: () -> (),
	appendPathPreviewMenuItems: (gui: PluginGui, items: { ContextMenu.Item }) -> (),
}

local function e(class: string)
	return New(class)
end

local function button(text: any, color: any, onClick: () -> ()): Instance
	return e("TextButton")({
		BackgroundColor3 = color,
		Size = UDim2.fromScale(1, 1),
		Text = text,
		TextColor3 = Theme.color.text,
		Font = Theme.font.bold,
		TextSize = 13,
		AutoButtonColor = true,
		[OnEvent("Activated")] = onClick,
		[Children] = e("UICorner")({ CornerRadius = UDim.new(0, 4) }),
	})
end

type SnapSkip = {
	keyframe: CutsceneFormat.Keyframe?,
	propKeyframe: CutsceneFormat.PropKeyframe?,
	clip: CutsceneFormat.AnimationClip?,
	event: CutsceneFormat.CutsceneEvent?,
	segment: CutsceneFormat.CameraSegment?,
}

type SnapDragOpts = {
	edgeMode: ("from" | "to")?,
}

-- 收集单轨上的时间点(供拖拽吸附);默认不含其它轨道。
local function markTimesForTrack(track: CutsceneFormat.Track, skip: SnapSkip?): { number }
	local out: { number } = {}
	if track.keyframes then
		for _, kf in track.keyframes do
			if not (skip and skip.keyframe == kf) then
				table.insert(out, kf.t)
			end
		end
	end
	if track.propKeyframes then
		for _, kf in track.propKeyframes do
			if not (skip and skip.propKeyframe == kf) then
				table.insert(out, kf.t)
			end
		end
	end
	if track.clips then
		for _, c in track.clips do
			if not (skip and skip.clip == c) then
				table.insert(out, c.startAt)
				if c.endAt then
					table.insert(out, c.endAt)
				end
			end
		end
	end
	if track.events then
		for _, ev in track.events do
			if not (skip and skip.event == ev) then
				table.insert(out, ev.t)
			end
		end
	end
	if track.soundCues then
		for _, c in track.soundCues do
			table.insert(out, c.t)
		end
	end
	if track.effectCues then
		for _, c in track.effectCues do
			table.insert(out, c.t)
		end
	end
	if track.segments then
		for _, s in track.segments do
			if not (skip and skip.segment == s) then
				table.insert(out, s.from)
				table.insert(out, s.to)
			end
		end
	end
	return out
end

-- V2:按住 Shift 时合并其它轨时间候选(本轨仍走 skip)。
local function markTimesOtherTracks(
	state: EditorState.EditorState,
	homeTrack: CutsceneFormat.Track
): { number }
	local out: { number } = {}
	for _, tr in state.tracks:get() do
		if tr ~= homeTrack then
			local part = markTimesForTrack(tr, nil)
			for _, t in part do
				table.insert(out, t)
			end
		end
	end
	return out
end

-- 同轨头尾接龙:左缘优先邻居 end,右缘优先邻居 start(同距离胜整秒/播放头)。
local function edgePriorityCandidates(
	track: CutsceneFormat.Track,
	skip: SnapSkip?,
	edgeMode: "from" | "to"
): { number }
	local out: { number } = {}
	if edgeMode == "from" then
		if track.clips then
			for _, c in track.clips do
				if not (skip and skip.clip == c) and c.endAt then
					table.insert(out, c.endAt)
				end
			end
		end
		if track.segments then
			for _, s in track.segments do
				if not (skip and skip.segment == s) then
					table.insert(out, s.to)
				end
			end
		end
	else
		if track.clips then
			for _, c in track.clips do
				if not (skip and skip.clip == c) then
					table.insert(out, c.startAt)
				end
			end
		end
		if track.segments then
			for _, s in track.segments do
				if not (skip and skip.segment == s) then
					table.insert(out, s.from)
				end
			end
		end
	end
	return out
end

local function snapCandidateTimes(
	state: EditorState.EditorState,
	track: CutsceneFormat.Track,
	skip: SnapSkip?,
	crossTrack: boolean
): { number }
	local out = markTimesForTrack(track, skip)
	table.insert(out, state.currentTime:get())
	if crossTrack then
		local other = markTimesOtherTracks(state, track)
		for _, t in other do
			table.insert(out, t)
		end
	end
	return out
end

local function modifierAltDown(): boolean
	return UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightAlt)
end

local function modifierShiftDown(): boolean
	return UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
end

-- 标尺 / 播放头把手:长按后跟随 scrub;纯点击不跳时间(onClick 可选)。
-- grab=true 时记录按下点与播放头的时间差,拖动保持相对位置不跳(播放头把手用)。
local function mouseInTimelineRuler(
	gui: PluginGui,
	timelineArea: GuiObject,
	mouse: Vector2
): boolean
	local areaTop = timelineArea.AbsolutePosition.Y - gui.AbsolutePosition.Y
	local relY = mouse.Y - areaTop
	return relY >= 0 and relY <= Theme.size.rulerHeight
end

local function beginScrub(
	gui: PluginGui,
	state: EditorState.EditorState,
	area: GuiObject,
	onClick: (() -> ())?,
	grab: boolean?,
	pressSource: GuiObject?,
	pressInput: InputObject?
)
	local offset = 0
	if grab then
		local m = gui:GetRelativeMousePosition()
		offset = DragController.fracInArea(area, m, gui) * state.duration:get()
			- state.currentTime:get()
	end
	local function applyScrub(mouse: Vector2)
		if not mouseInTimelineRuler(gui, area, mouse) then
			return
		end
		local dur = state.duration:get()
		state:setTime(
			math.clamp(DragController.fracInArea(area, mouse, gui) * dur - offset, 0, dur)
		)
	end
	beginTimelineDrag(gui, {
		onBegin = function()
			playheadScrubbing:set(true)
		end,
		onMove = applyScrub,
		onEnd = function()
			playheadScrubbing:set(false)
		end,
		onClick = function()
			playheadScrubbing:set(false)
			if onClick then
				onClick()
			end
		end,
		pressSource = pressSource,
	}, pressSource, pressInput)
end

-- 先磁吸(整秒 + 本轨标记 + 播放头;缘拖优先头尾接龙),再量化到帧(1/fps);Alt = 自由(不吸附/不量化);Shift = 跨轨候选(V2)。
local function draggedTime(
	gui: PluginGui,
	state: EditorState.EditorState,
	area: GuiObject,
	mouse: Vector2,
	offsetSec: number?,
	track: CutsceneFormat.Track,
	skip: SnapSkip?,
	snapOpts: SnapDragOpts?
): number
	local dur = state.duration:get()
	local t =
		math.clamp(DragController.fracInArea(area, mouse, gui) * dur - (offsetSec or 0), 0, dur)
	local alt = modifierAltDown()
	local thr = SNAP_PX / math.max(area.AbsoluteSize.X, 1) * dur
	local candidates = snapCandidateTimes(state, track, skip, modifierShiftDown())
	local priority = if snapOpts and snapOpts.edgeMode
		then edgePriorityCandidates(track, skip, snapOpts.edgeMode)
		else nil
	local snapped = DragController.snapTime(t, dur, candidates, thr, alt, priority)
	if not alt then
		local fps = state.fps:get()
		snapped = math.clamp(math.round(snapped * fps) / fps, 0, dur)
	end
	return snapped
end

-- 弹出"选目标"菜单:列出候选名 + 自定义输入,选中回调 onPick。
-- 加动画/变换轨、绑定芯片换绑、轨道菜单换目标共用(Timeline 的 binding 槽交互)。
local function pickTarget(
	gui: PluginGui,
	title: string,
	candidates: { string },
	onPick: (target: string) -> ()
)
	local items: { ContextMenu.Item } = { { kind = "header", text = title } }
	for _, tgt in candidates do
		table.insert(items, {
			text = tgt,
			onClick = function()
				onPick(tgt)
			end,
		})
	end
	table.insert(items, { kind = "sep" })
	table.insert(items, {
		text = "自定义名字…",
		onClick = function()
			InputPrompt.show(gui, {
				title = "目标名(逻辑绑定名,运行时由 resolver 解析)",
				placeholder = "如 Boss / Door",
				onSubmit = function(txt)
					if txt ~= "" then
						onPick(txt)
					end
				end,
			})
		end,
	})
	ContextMenu.show(gui, items)
end

-- 相机 / cameraMove 路径菜单(轨道行、时间轴段条、空白处右键共用)。
local function cameraPathMenuItems(
	gui: PluginGui,
	cb: Callbacks,
	state: EditorState.EditorState,
	track: CutsceneFormat.Track,
	atTime: number?,
	suffix: string
): { ContextMenu.Item }
	local items: { ContextMenu.Item } = {}
	local isBezier = track.pathMode == "bezier"
	table.insert(items, {
		text = if isBezier then "✓ 贝塞尔曲线" else "贝塞尔曲线",
		onClick = function()
			if isBezier then
				state:setTrackPathMode(track, "linear")
			else
				state:pushUndo()
				track.pathMode = "bezier"
				track.smooth = false
				EditorState.fitTrackToBezierTangents(track, true)
				state:commitTracks(true)
			end
		end,
	})
	if isBezier then
		table.insert(items, {
			text = "  重置切线(直线段)",
			onClick = function()
				state:resetTrackTangents(track)
			end,
		})
		local playT = atTime or state.currentTime:get()
		local _, rightAtPlay = EditorState.bracketKeyframeInterval(track, playT)
		if rightAtPlay then
			table.insert(items, {
				text = "  在播放头插入路径关键帧" .. suffix,
				onClick = function()
					state:insertPathKeyframeAt(track, playT)
				end,
			})
		end
	end
	table.insert(items, {
		text = "  直线插值",
		onClick = function()
			state:setTrackPathMode(track, "linear")
		end,
	})
	table.insert(items, {
		text = "  平滑 Catmull-Rom(旧)",
		onClick = function()
			state:setTrackSmooth(track, true)
		end,
	})
	cb.appendPathPreviewMenuItems(gui, items)
	return items
end

-- 关键帧剪贴板(23 spec):单槽;右键复制,轨道右键在类型兼容时出现"粘贴"。
type KfClipboard = {
	kind: "cframe" | "prop" | "event",
	value: any?,
	easing: CutsceneFormat.EasingName?,
	outTangent: Vector3?,
	inTangent: Vector3?,
	name: string?,
	payload: { [string]: any }?,
}
local _kfClipboard: KfClipboard? = nil

-- 事件 payload ↔ 文本:`k=v; k2=v2`,值自动转型(number/true/false/string)。19 spec。
local function payloadToText(payload: { [string]: any }): string
	local keys = {}
	for k in payload do
		table.insert(keys, k)
	end
	table.sort(keys)
	local parts = {}
	for _, k in keys do
		table.insert(parts, k .. "=" .. tostring(payload[k]))
	end
	return table.concat(parts, "; ")
end

-- 解析失败返回 (nil, 错误);空输入返回 (nil, nil) = 清除 payload。
local function payloadFromText(txt: string): ({ [string]: any }?, string?)
	local trimmed = (txt:gsub("^%s+", ""):gsub("%s+$", ""))
	if trimmed == "" then
		return nil, nil
	end
	local out: { [string]: any } = {}
	local n = 0
	for pair in trimmed:gmatch("[^;]+") do
		local body = (pair:gsub("^%s+", ""):gsub("%s+$", ""))
		if body == "" then
			continue
		end
		local k, v = body:match("^([%w_]+)%s*=%s*(.*)$")
		if not k or not v or v == "" then
			return nil, `无法解析 '{body}'(应为 k=v)`
		end
		local num = tonumber(v)
		if num then
			out[k] = num
		elseif v == "true" then
			out[k] = true
		elseif v == "false" then
			out[k] = false
		else
			out[k] = v
		end
		n += 1
	end
	if n == 0 then
		return nil, nil
	end
	return out, nil
end

-- 属性值 ↔ 文本(属性轨改值输入用)
local function propValueToText(v: CutsceneFormat.PropValue): string
	local tn = typeof(v)
	if tn == "number" then
		return string.format("%.4g", v :: number)
	elseif tn == "boolean" then
		return tostring(v)
	elseif tn == "Vector3" then
		local vec = v :: Vector3
		return string.format("%.4g, %.4g, %.4g", vec.X, vec.Y, vec.Z)
	elseif tn == "Color3" then
		local c = v :: Color3
		return string.format(
			"%d, %d, %d",
			math.round(c.R * 255),
			math.round(c.G * 255),
			math.round(c.B * 255)
		)
	end
	return tostring(v)
end

-- 按样本值的类型解析输入文本;失败返回 nil。Color3 用 0–255 RGB。
local function propValueFromText(
	txt: string,
	sample: CutsceneFormat.PropValue
): CutsceneFormat.PropValue?
	local tn = typeof(sample)
	local trimmed = (txt:gsub("^%s+", ""):gsub("%s+$", ""))
	if tn == "number" then
		return tonumber(trimmed)
	elseif tn == "boolean" then
		if trimmed == "true" or trimmed == "1" then
			return true
		end
		if trimmed == "false" or trimmed == "0" then
			return false
		end
		return nil
	elseif tn == "Vector3" or tn == "Color3" then
		local a, b, c = trimmed:match("^([%-%.%d]+)[,%s]+([%-%.%d]+)[,%s]+([%-%.%d]+)$")
		local x, y, z = tonumber(a), tonumber(b), tonumber(c)
		if not (x and y and z) then
			return nil
		end
		if tn == "Vector3" then
			return Vector3.new(x, y, z)
		end
		return Color3.fromRGB(math.clamp(x, 0, 255), math.clamp(y, 0, 255), math.clamp(z, 0, 255))
	end
	return nil
end

-- 轨道右键菜单(左栏行 / 时间轴行共用):按类型的快捷操作 + 改名 / 换目标 / 删除。
-- atTime:时间轴行右键时传入点击处对应的时间,创建项在该时间点生效;
-- 不传(左栏行)则沿用当前播放头时间。
local function showTrackMenu(
	gui: PluginGui,
	state: EditorState.EditorState,
	cb: Callbacks,
	track: CutsceneFormat.Track,
	atTime: number?
)
	local suffix = if atTime then string.format(" @ %.2fs", atTime) else ""
	local items: { ContextMenu.Item } = { { kind = "header", text = track.name or track.kind } }
	if track.kind == "camera" or track.kind == "cameraMove" then
		local following = cb.viewportFollow:get()
		table.insert(items, {
			text = (if following then "✓ " else "") .. "实时预览(跟随主视口,K 打帧)",
			onClick = function()
				cb.viewportFollow:set(not following)
				-- 开启即选中本轨(跟手预览/K 打帧都作用于选中轨)
				if not following then
					for i, tr in state.tracks:get() do
						if tr == track then
							state.selectedTrack:set(i)
							break
						end
					end
				end
			end,
		})
		-- 视野 FOV:基础值(vcam attribute)+ FOV 关键帧(变焦,仅 camera 轨)
		local at = atTime or state.currentTime:get()
		local vcamPart = VCam.find(track.target)
		local baseFov = vcamPart and vcamPart:GetAttribute("FOV")
		local baseFovNum = if typeof(baseFov) == "number" then baseFov :: number else 70
		table.insert(items, {
			text = string.format("视野 FOV(基础)… (%d)", math.floor(baseFovNum)),
			onClick = function()
				InputPrompt.show(gui, {
					title = "vcam 基础 FOV(1–120;无 FOV 帧时全程用它)",
					default = tostring(baseFovNum),
					onSubmit = function(txt)
						local n = tonumber(txt)
						if n then
							cb.onSetVcamFov(track.target, math.clamp(n, 1, 120))
						end
					end,
				})
			end,
		})
		if track.kind == "camera" then
			local sampled = if track.fovKeyframes and #track.fovKeyframes > 0
				then Sampler.sampleNumber(track.fovKeyframes, at)
				else nil
			table.insert(items, {
				text = string.format("K FOV 帧(变焦)…%s", suffix),
				onClick = function()
					InputPrompt.show(gui, {
						title = string.format("FOV 关键帧 @ %.2fs(1–120)", at),
						default = tostring(math.floor((sampled or baseFovNum) + 0.5)),
						onSubmit = function(txt)
							local n = tonumber(txt)
							if n then
								state:addOrSetFovKeyframe(track, at, math.clamp(n, 1, 120))
							end
						end,
					})
				end,
			})
			local fovKfs = track.fovKeyframes
			if fovKfs and #fovKfs > 0 then
				local fps = state.fps:get()
				table.insert(
					items,
					{ kind = "header", text = "FOV 帧(点击改值,留空删除)" }
				)
				for _, kf in fovKfs do
					local this = kf
					table.insert(items, {
						text = string.format(
							"  %df · FOV %d",
							math.round(this.t * fps),
							math.floor(this.value)
						),
						onClick = function()
							InputPrompt.show(gui, {
								title = string.format(
									"FOV @ %df(留空 = 删除该帧)",
									math.round(this.t * fps)
								),
								default = tostring(math.floor(this.value)),
								onSubmit = function(txt)
									if txt == "" then
										state:removeFovKeyframe(track, this)
										return
									end
									local n = tonumber(txt)
									if n then
										state:setFovKeyframeValue(this, math.clamp(n, 1, 120))
									end
								end,
							})
						end,
					})
				end
			end
		end
		table.insert(items, { kind = "sep" })
		for _, pathItem in cameraPathMenuItems(gui, cb, state, track, atTime, suffix) do
			table.insert(items, pathItem)
		end
		table.insert(items, { kind = "sep" })
	end
	if track.kind == "animation" then
		table.insert(items, {
			text = "＋ 动画片段…" .. suffix,
			onClick = function()
				InputPrompt.show(gui, {
					title = "动画 AnimationId",
					placeholder = "rbxassetid://…",
					onSubmit = function(txt)
						if txt ~= "" then
							state:addClip(track, txt, atTime)
						end
					end,
				})
			end,
		})
	elseif track.kind == "event" then
		table.insert(items, {
			text = "＋ 事件…" .. suffix,
			onClick = function()
				InputPrompt.show(gui, {
					title = "事件名(供 onEvent 分发)",
					placeholder = "如 cutscene_start / boss_reveal",
					onSubmit = function(txt)
						if txt ~= "" then
							state:addEvent(track, txt, atTime)
						end
					end,
				})
			end,
		})
	elseif track.kind == "sound" then
		table.insert(items, {
			text = "＋ 音效…" .. suffix,
			onClick = function()
				InputPrompt.show(gui, {
					title = "SoundId",
					placeholder = "rbxassetid://…",
					onSubmit = function(txt)
						if txt ~= "" then
							state:addSoundCue(track, txt, atTime)
						end
					end,
				})
			end,
		})
	elseif track.kind == "effect" then
		table.insert(items, {
			text = "＋ Forge 特效…" .. suffix,
			onClick = function()
				InputPrompt.show(gui, {
					title = "forgeRoot(绑定下子 Model 名,留空=整绑定)",
					placeholder = "如 Slash;留空 emit 整个绑定",
					onSubmit = function(txt)
						local root = if txt ~= "" then txt else nil
						state:addEffectCue(track, nil, nil, atTime, "forge", root)
					end,
				})
			end,
		})
		table.insert(items, {
			text = "＋ 粒子特效…" .. suffix,
			onClick = function()
				InputPrompt.show(gui, {
					title = "ParticleEmitter 模板名(目标下)",
					placeholder = "如 DustEmitter;留空则用资源 id",
					onSubmit = function(txt)
						local name = if txt ~= "" then txt else nil
						if name then
							state:addEffectCue(track, name, nil, atTime)
						else
							InputPrompt.show(gui, {
								title = "粒子 rbxassetid",
								placeholder = "rbxassetid://…",
								onSubmit = function(id)
									if id ~= "" then
										state:addEffectCue(track, nil, id, atTime)
									end
								end,
							})
						end
					end,
				})
			end,
		})
	elseif track.kind == "screen" then
		table.insert(items, {
			text = "＋ 淡入淡出" .. suffix,
			onClick = function()
				state:addScreenCue(track, "fade", atTime)
			end,
		})
		table.insert(items, {
			text = "＋ 黑边(letterbox)" .. suffix,
			onClick = function()
				state:addScreenCue(track, "letterbox", atTime)
			end,
		})
		table.insert(items, {
			text = "＋ 受击红屏(tint)" .. suffix,
			onClick = function()
				state:addScreenCue(track, "tint", atTime)
			end,
		})
		table.insert(items, {
			text = "＋ 溅血贴图(splash)…" .. suffix,
			onClick = function()
				InputPrompt.show(gui, {
					title = "溅血贴图 rbxassetid(项目自备素材)",
					placeholder = "rbxassetid://…",
					onSubmit = function(txt)
						state:addScreenCue(
							track,
							"splash",
							atTime,
							if txt ~= "" then { imageId = txt } else nil
						)
					end,
				})
			end,
		})
	elseif track.kind == "transform" then
		table.insert(items, {
			text = (if atTime
				then "在此处打帧(采集目标位姿)"
				else "在此刻打帧(采集目标位姿)") .. suffix,
			onClick = function()
				cb.onCaptureTransform(track, atTime)
			end,
		})
	elseif track.kind == "property" then
		table.insert(items, {
			text = (if atTime
				then "在此处打帧(读当前值)"
				else "在此刻打帧(读当前值)") .. suffix,
			onClick = function()
				local err = state:capturePropFrame(track, nil, atTime)
				if err then
					warn("[anima] 属性打帧失败:" .. err)
				end
			end,
		})
		table.insert(items, {
			text = "输值打帧…" .. suffix,
			onClick = function()
				local kfs = track.propKeyframes
				local sample: CutsceneFormat.PropValue? = if kfs and kfs[#kfs]
					then kfs[#kfs].value
					else nil
				if sample == nil then
					local read =
						EditorState.readPropertyValue(track.target, track.propertyName or "")
					sample = read
				end
				if sample == nil then
					warn(
						`[anima] 属性轨 '{track.target}.{track.propertyName or "?"}' 读不到样本值`
					)
					return
				end
				InputPrompt.show(gui, {
					title = string.format(
						"%s 的值(%s)",
						track.propertyName or "?",
						typeof(sample)
					),
					default = propValueToText(sample :: CutsceneFormat.PropValue),
					onSubmit = function(txt)
						local v = propValueFromText(txt, sample :: CutsceneFormat.PropValue)
						if v ~= nil then
							local err = state:capturePropFrame(track, v, atTime)
							if err then
								warn("[anima] 属性打帧失败:" .. err)
							end
						else
							warn(`[anima] 属性值解析失败:'{txt}'({typeof(sample)})`)
						end
					end,
				})
			end,
		})
		table.insert(items, {
			text = if track.keepOnDone
				then "✓ 播完保留终值(点击改为还原)"
				else "播完保留终值(当前:还原原值)",
			onClick = function()
				state:setTrackKeepOnDone(track, not track.keepOnDone)
			end,
		})
	elseif track.kind == "cameraMove" then
		table.insert(items, {
			text = "采集相机位姿打帧" .. suffix,
			onClick = function()
				cb.onCaptureCameraMove(track, atTime)
			end,
		})
	elseif track.kind == "camera" then
		table.insert(items, {
			text = "＋ 添加生效段（无关键帧）" .. suffix,
			onClick = function()
				local t = atTime or state.currentTime:get()
				state:addSegment(track, t)
			end,
		})
		table.insert(items, {
			text = (
				if atTime then "在此处采集视口打帧" else "在此刻采集视口打帧"
			) .. suffix,
			onClick = function()
				cb.onCaptureCameraTrack(track, atTime)
			end,
		})
	end
	-- 粘贴关键帧(23 spec):剪贴板与轨道类型兼容时出现
	do
		local clip = _kfClipboard
		local pasteT = atTime or state.currentTime:get()
		local compatible = clip ~= nil
			and (
				(
					clip.kind == "cframe"
					and (
						track.kind == "camera"
						or track.kind == "cameraMove"
						or track.kind == "transform"
					)
				)
				or (clip.kind == "prop" and track.kind == "property")
				or (clip.kind == "event" and track.kind == "event")
			)
		if clip and compatible then
			table.insert(items, {
				text = string.format("📋 粘贴关键帧 @ %.2fs", pasteT),
				onClick = function()
					if clip.kind == "cframe" then
						state:pasteCFrameKeyframe(
							track,
							pasteT,
							clip.value :: CFrame,
							clip.easing,
							clip.outTangent,
							clip.inTangent
						)
					elseif clip.kind == "prop" then
						local kfs = track.propKeyframes
						local sample = if kfs and kfs[1] then kfs[1].value else nil
						if sample ~= nil and typeof(sample) ~= typeof(clip.value) then
							warn(
								`[anima] 粘贴取消:剪贴板值类型 {typeof(clip.value)} 与该轨 {typeof(
									sample
								)} 不符`
							)
							return
						end
						local err = state:capturePropFrame(track, clip.value, pasteT, clip.easing)
						if err then
							warn("[anima] 粘贴失败:" .. err)
						end
					elseif clip.kind == "event" and clip.name then
						state:addEvent(
							track,
							clip.name,
							pasteT,
							if clip.payload then table.clone(clip.payload) else nil
						)
					end
				end,
			})
		end
	end
	table.insert(items, { kind = "sep" })
	table.insert(items, {
		text = if track.hidden
			then "👁 显示轨道"
			else "🙈 隐藏轨道(预览/播放跳过)",
		onClick = function()
			state:setTrackHidden(track, not track.hidden)
		end,
	})
	table.insert(items, {
		text = "⬆ 上移一层"
			.. (if track.kind == "camera" then "(相机优先级↑)" else ""),
		onClick = function()
			state:moveTrack(track, -1)
		end,
	})
	table.insert(items, {
		text = "⬇ 下移一层",
		onClick = function()
			state:moveTrack(track, 1)
		end,
	})
	table.insert(items, {
		text = "改名…",
		onClick = function()
			InputPrompt.show(gui, {
				title = "轨道名",
				placeholder = "轨道显示名",
				default = track.name or track.target,
				onSubmit = function(txt)
					if txt ~= "" then
						state:renameTrack(track, txt)
					end
				end,
			})
		end,
	})
	table.insert(items, {
		text = "换目标…",
		onClick = function()
			local cands = if track.kind == "animation"
				then cb.characterCandidates()
				else cb.targetCandidates()
			pickTarget(gui, "设为目标", cands, function(tgt)
				state:setTrackTarget(track, tgt)
			end)
		end,
	})
	table.insert(items, { kind = "sep" })
	table.insert(items, {
		text = "删除轨道",
		color = Theme.color.danger,
		onClick = function()
			state:removeTrack(track)
		end,
	})
	ContextMenu.show(gui, items)
end

-- 新增轨道菜单:左列 ＋轨道 按钮与时间轴/左列空白右键共用。
local function showAddTrackMenu(
	gui: PluginGui,
	state: EditorState.EditorState,
	cb: Callbacks,
	menuOpts: ContextMenu.ShowOpts?
)
	local items: { ContextMenu.Item } = { { kind = "header", text = "添加轨道" } }
	table.insert(items, {
		text = CAMERA_CREATE_HINT,
		onClick = function()
			print("[anima] 请使用顶栏「＋ 相机」创建虚拟相机与独立相机轨")
		end,
	})
	table.insert(items, {
		text = "动画轨道 → 选择绑定…",
		onClick = function()
			pickTarget(gui, "绑定角色", cb.characterCandidates(), function(tgt)
				state:addTrack("animation", tgt, TimelineUnity.defaultTrackName("animation"))
			end)
		end,
	})
	table.insert(items, {
		text = "控制轨道 → 选择绑定…",
		onClick = function()
			pickTarget(gui, "绑定目标", cb.targetCandidates(), function(tgt)
				state:addTrack("transform", tgt, TimelineUnity.defaultTrackName("transform"))
			end)
		end,
	})
	table.insert(items, {
		text = "标记轨道",
		onClick = function()
			state:addTrack("event", "Player", TimelineUnity.defaultTrackName("event"))
		end,
	})
	table.insert(items, {
		text = "音效轨道 → 选择绑定…",
		onClick = function()
			pickTarget(gui, "绑定发声位置", cb.targetCandidates(), function(tgt)
				state:addTrack("sound", tgt, TimelineUnity.defaultTrackName("sound"))
			end)
		end,
	})
	table.insert(items, {
		text = "特效轨道 → 选择绑定…",
		onClick = function()
			pickTarget(gui, "绑定特效挂点", cb.targetCandidates(), function(tgt)
				state:addTrack("effect", tgt, TimelineUnity.defaultTrackName("effect"))
			end)
		end,
	})
	table.insert(items, {
		text = "属性轨道 → 选择绑定…",
		onClick = function()
			pickTarget(gui, "绑定目标", cb.targetCandidates(), function(tgt)
				InputPrompt.show(gui, {
					title = string.format("'%s' 的属性名", tgt),
					placeholder = "如 Transparency / Color / Brightness",
					onSubmit = function(prop)
						if prop == "" then
							return
						end
						local idx, err = state:addPropertyTrack(tgt, prop)
						if err then
							warn("[anima] 属性轨创建失败:" .. err)
						elseif idx then
							state.selectedTrack:set(idx)
						end
					end,
				})
			end)
		end,
	})
	do
		-- 演出轨(屏幕)单例:已存在则不再新建(22 spec)
		local hasScreen = false
		for _, tr in state.tracks:get() do
			if tr.kind == "screen" then
				hasScreen = true
				break
			end
		end
		table.insert(items, {
			text = if hasScreen then "演出轨道(已存在)" else "演出轨道(屏幕效果)",
			color = if hasScreen then Theme.color.textDim else nil,
			onClick = function()
				if hasScreen then
					return
				end
				local idx = state:addTrack("screen", "Screen")
				state.selectedTrack:set(idx)
			end,
		})
	end
	table.insert(items, { kind = "sep" })
	table.insert(items, {
		text = "轨道组…",
		onClick = function()
			pickTarget(gui, "轨道组根绑定", cb.targetCandidates(), function(tgt)
				state:addTrack("transform", tgt, TimelineUnity.defaultTrackName("transform"), tgt)
			end)
		end,
	})
	ContextMenu.show(gui, items, menuOpts)
end

--========================= 顶部工具条 =========================--

local function topbar(
	gui: PluginGui,
	state: EditorState.EditorState,
	cb: Callbacks,
	previewCollapsed: Fusion.Value<boolean>
): Instance
	local timeLabel = Computed(function()
		local fps = state.fps:get()
		local cur = math.round(state.currentTime:get() * fps)
		local total = math.round(state.duration:get() * fps)
		return string.format("帧 %d/%d · %.2fs", cur, total, state.duration:get())
	end)

	local function showDurationMenu()
		local fps = math.max(state.fps:get(), 1)
		local totalFrames = math.round(state.duration:get() * fps)
		ContextMenu.show(gui, {
			{ kind = "header", text = "过场总时长" },
			{
				text = "改总帧数…",
				onClick = function()
					InputPrompt.show(gui, {
						title = string.format("总帧数(fps=%d)", math.floor(fps)),
						placeholder = "如 120",
						default = tostring(totalFrames),
						onSubmit = function(txt)
							local f = tonumber(txt)
							if f and f >= 1 then
								state:setTotalFrames(math.floor(f))
							end
						end,
					})
				end,
			},
			{
				text = "改总时长(秒)…",
				onClick = function()
					InputPrompt.show(gui, {
						title = "总时长(秒)",
						placeholder = "如 5 / 8.5",
						default = string.format("%.2f", state.duration:get()),
						onSubmit = function(txt)
							local n = tonumber(txt)
							if n and n > 0 then
								state:setDuration(n)
							end
						end,
					})
				end,
			},
			{ kind = "sep" },
			{
				text = "时长适应全部内容",
				onClick = function()
					state:fitDurationToContent(false)
				end,
			},
			{
				text = "时长适应选中轨",
				onClick = function()
					state:fitDurationToContent(true)
				end,
			},
			{ kind = "sep" },
			{
				text = if state.skippable:get()
					then "✓ 可跳过(内建按钮)"
					else "可跳过(内建按钮)",
				onClick = function()
					state.skippable:set(not state.skippable:get())
				end,
			},
			{
				text = string.format("跳过按住时长… (%.1fs)", state.skipHoldSec:get()),
				onClick = function()
					InputPrompt.show(gui, {
						title = "按住跳过时长(秒,0 = 点按即跳)",
						default = tostring(state.skipHoldSec:get()),
						onSubmit = function(txt)
							local n = tonumber(txt)
							if n then
								state.skipHoldSec:set(math.max(n, 0))
							end
						end,
					})
				end,
			},
		}, { width = 220 })
	end
	local playText = Computed(function()
		return if cb.isPlaying:get() then "⏸" else "▶"
	end)
	local loopColor = Computed(function()
		return if cb.loop:get() then Theme.color.accent else Theme.color.panel
	end)
	local mainText = Computed(function()
		return if cb.mainPreviewActive:get() then "🖥 跟随中" else "🖥 跟随"
	end)
	local mainColor = Computed(function()
		return if cb.mainPreviewActive:get() then Theme.color.playhead else Theme.color.panelAlt
	end)
	local undoColor = Computed(function()
		return if state.canUndo:get() then Theme.color.panel else Theme.color.bg
	end)
	local redoColor = Computed(function()
		return if state.canRedo:get() then Theme.color.panel else Theme.color.bg
	end)
	local previewText = Computed(function()
		return if previewCollapsed:get() then "▼ 预览" else "▲ 预览"
	end)
	local recText = Computed(function()
		return if cb.recordActive:get() then "● 录制中" else "● 录制"
	end)
	local recColor = Computed(function()
		return if cb.recordActive:get() then Theme.color.danger else Color3.fromRGB(96, 48, 52)
	end)
	local captureKEnabled = Computed(function()
		local idx = state.selectedTrack:get()
		if not idx then
			return false
		end
		local tr = state.tracks:get()[idx]
		return tr ~= nil and (tr.kind == "camera" or tr.kind == "cameraMove")
	end)
	local captureKColor = Computed(function()
		return if captureKEnabled:get() then Theme.color.track.camera else Theme.color.bg
	end)

	local function slot(order: number, width: number, child: Instance): Instance
		return e("Frame")({
			LayoutOrder = order,
			BackgroundTransparency = 1,
			Size = UDim2.new(0, width, 1, -10),
			[Children] = child,
		})
	end

	return e("Frame")({
		BackgroundColor3 = Theme.color.panelAlt,
		Size = UDim2.new(1, 0, 0, Theme.size.topbar),
		BorderSizePixel = 0,
		[Children] = {
			e("UIListLayout")({
				FillDirection = Enum.FillDirection.Horizontal,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0, 5),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			e("UIPadding")({ PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }),
			e("TextLabel")({
				LayoutOrder = 1,
				BackgroundTransparency = 1,
				Size = UDim2.new(0, 120, 1, 0),
				Text = Computed(function()
					return "🎬 " .. state.name:get()
				end),
				TextColor3 = Theme.color.text,
				TextXAlignment = Enum.TextXAlignment.Left,
				Font = Theme.font.bold,
				TextSize = 14,
			}),
			e("TextButton")({
				LayoutOrder = 2,
				BackgroundTransparency = 1,
				Size = UDim2.new(0, 128, 1, 0),
				Text = timeLabel,
				TextColor3 = Theme.color.text,
				Font = Theme.font.main,
				TextSize = 12,
				AutoButtonColor = false,
				[OnEvent("Activated")] = function()
					showDurationMenu()
				end,
			}),
			slot(3, 32, button("⏮", Theme.color.panel, cb.onToStart)),
			slot(5, 36, button("🔁", loopColor, cb.onToggleLoop)),
			slot(4, 40, button(playText, Theme.color.accent, cb.onPlayPause)),
			slot(4, 70, button(recText, recColor, cb.onToggleRecord)),
			slot(13, 56, button("打帧 K", captureKColor, cb.onCaptureAtPlayhead)),
			slot(
				6,
				34,
				button("↶", undoColor, function()
					state:undo()
				end)
			),
			slot(
				7,
				34,
				button("↷", redoColor, function()
					state:redo()
				end)
			),
			slot(8, 78, button("＋ 相机", Theme.color.track.camera, cb.onAddVcam)),
			slot(9, 60, button("👁 透视", Theme.color.panel, cb.onLookThrough)),
			slot(10, 78, button(mainText, mainColor, cb.onToggleMainPreview)),
			slot(
				11,
				84,
				button(previewText, Theme.color.panel, function()
					previewCollapsed:set(not previewCollapsed:get())
				end)
			),
			slot(14, 44, button("📄 新建", Theme.color.panelAlt, cb.onNewDocument)),
			slot(
				15,
				44,
				button("📂 导入", Theme.color.panelAlt, function()
					cb.onImportMenu(gui)
				end)
			),
			slot(
				16,
				48,
				button("📁 另存", Theme.color.panelAlt, function()
					cb.onSaveAsModule(gui)
				end)
			),
			slot(17, 52, button("↺ 草稿", Theme.color.panelAlt, cb.onRestoreDraft)),
			slot(
				18,
				60,
				button("💾 导出", Theme.color.track.animation, function()
					cb.onExport(gui)
				end)
			),
		},
	})
end

--========================= vcam 管理条 =========================--

local function vcamBar(gui: PluginGui, state: EditorState.EditorState, cb: Callbacks): Instance
	local chips = Computed(function()
		-- 依赖 revision:vcam 变动(增删/改名/改属性)后走结构性 commit 触发重建
		state.revision:get()
		local kids: { Instance } = {
			e("TextLabel")({
				LayoutOrder = 0,
				BackgroundTransparency = 1,
				Size = UDim2.new(0, 44, 1, 0),
				Text = "相机:",
				TextColor3 = Theme.color.textDim,
				Font = Theme.font.bold,
				TextSize = 11,
				TextXAlignment = Enum.TextXAlignment.Left,
			}),
		}
		local names = VCam.list()
		if #names == 0 then
			table.insert(
				kids,
				e("TextLabel")({
					LayoutOrder = 1,
					BackgroundTransparency = 1,
					Size = UDim2.new(0, 200, 1, 0),
					Text = "还没有虚拟相机 — 点『＋ 相机』",
					TextColor3 = Theme.color.textDim,
					Font = Theme.font.main,
					TextSize = 11,
					TextXAlignment = Enum.TextXAlignment.Left,
				})
			)
		end
		for i, name in names do
			local part = VCam.find(name)
			local fov = part and part:GetAttribute("FOV")
			local la = part and part:GetAttribute("LookAt")
			local label = "🎥 " .. name
			if typeof(fov) == "number" then
				label ..= string.format(" ·%d", fov)
			end
			if typeof(la) == "string" and la ~= "" then
				label ..= " →" .. la
			end
			table.insert(
				kids,
				e("TextButton")({
					LayoutOrder = i,
					BackgroundColor3 = Theme.color.panel,
					AutomaticSize = Enum.AutomaticSize.X,
					Size = UDim2.new(0, 0, 1, -6),
					Text = label,
					TextColor3 = Theme.color.track.camera,
					Font = Theme.font.main,
					TextSize = 11,
					AutoButtonColor = true,
					[OnEvent("Activated")] = function()
						cb.onSelectVcam(name)
					end,
					[OnEvent("MouseButton2Click")] = function()
						local items: { ContextMenu.Item } = {
							{ kind = "header", text = "虚拟相机 " .. name },
							{
								text = "选中(定位 gizmo)",
								onClick = function()
									cb.onSelectVcam(name)
								end,
							},
							{
								text = "用当前视口位姿更新",
								onClick = function()
									cb.onRecaptureVcam(name)
								end,
							},
							{ kind = "header", text = "视野 FOV" },
						}
						for _, f in { 40, 50, 60, 70, 80, 90 } do
							table.insert(items, {
								text = "  " .. f,
								onClick = function()
									cb.onSetVcamFov(name, f)
								end,
							})
						end
						table.insert(items, {
							text = "  自定义…",
							onClick = function()
								InputPrompt.show(gui, {
									title = "FOV(1–120)",
									onSubmit = function(txt)
										local n = tonumber(txt)
										if n then
											cb.onSetVcamFov(name, math.clamp(n, 1, 120))
										end
									end,
								})
							end,
						})
						table.insert(items, { kind = "header", text = "看向 LookAt" })
						table.insert(items, {
							text = "  (清除)",
							onClick = function()
								cb.onSetVcamLookAt(name, "")
							end,
						})
						for _, tgt in cb.targetCandidates() do
							table.insert(items, {
								text = "  " .. tgt,
								onClick = function()
									cb.onSetVcamLookAt(name, tgt)
								end,
							})
						end
						table.insert(items, { kind = "sep" })
						table.insert(items, {
							text = "改名…",
							onClick = function()
								InputPrompt.show(gui, {
									title = "虚拟相机改名",
									default = name,
									onSubmit = function(txt)
										cb.onRenameVcam(name, txt)
									end,
								})
							end,
						})
						table.insert(items, {
							text = "删除",
							color = Theme.color.danger,
							onClick = function()
								cb.onDeleteVcam(name)
							end,
						})
						ContextMenu.show(gui, items)
					end,
					[Children] = {
						e("UICorner")({ CornerRadius = UDim.new(0, 3) }),
						e("UIPadding")({
							PaddingLeft = UDim.new(0, 6),
							PaddingRight = UDim.new(0, 6),
						}),
					},
				})
			)
		end
		return kids
	end)

	return e("Frame")({
		BackgroundColor3 = Theme.color.bg,
		Size = UDim2.new(1, 0, 0, Theme.size.vcamBar),
		BorderSizePixel = 0,
		[Children] = {
			e("UIListLayout")({
				FillDirection = Enum.FillDirection.Horizontal,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0, 5),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			e("UIPadding")({ PaddingLeft = UDim.new(0, 8) }),
			e("Frame")({
				BackgroundTransparency = 1,
				Size = UDim2.fromScale(1, 1),
				[Children] = chips,
			}),
		},
	})
end

--========================= 时间轴内容 =========================--

-- 关键帧 / clip / event 菱形标记:长按拖动改时间、右键菜单编辑。
local function markDiamond(
	gui: PluginGui,
	state: EditorState.EditorState,
	cb: Callbacks,
	area: () -> GuiObject,
	track: CutsceneFormat.Track,
	kf: CutsceneFormat.Keyframe
): Instance
	local dur = state.duration:get()
	local sz = Theme.size.keyframe
	local diamond
	diamond = e("TextButton")({
		BackgroundColor3 = Theme.trackColor(track.kind),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(kf.t / dur, 0.5),
		Size = UDim2.fromOffset(sz, sz),
		Rotation = 45,
		Text = "",
		AutoButtonColor = true,
		ZIndex = 6,
		[OnEvent("InputBegan")] = function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				local grab = DragController.fracInArea(area(), gui:GetRelativeMousePosition(), gui)
						* state.duration:get()
					- kf.t
				beginTimelineDrag(gui, {
					onBegin = function()
						state:pushUndo()
					end,
					onMove = function(mouse)
						kf.t =
							draggedTime(gui, state, area(), mouse, grab, track, { keyframe = kf })
						diamond.Position = UDim2.fromScale(kf.t / state.duration:get(), 0.5)
					end,
					onEnd = function()
						state:finishDrag()
					end,
					onClick = function()
						if track.kind ~= "camera" and track.kind ~= "cameraMove" then
							return
						end
						local cf = kf.value
						if typeof(cf) ~= "CFrame" then
							return
						end
						local now = os.clock()
						if
							kfJumpDbl.kf == kf
							and kfJumpDbl.track == track
							and now - kfJumpDbl.at < 0.35
						then
							kfJumpDbl.kf = nil
							cb.onJumpToCameraKeyframe(track, kf)
						else
							kfJumpDbl.track = track
							kfJumpDbl.kf = kf
							kfJumpDbl.at = now
						end
					end,
				}, diamond, input)
			elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
				local items: { ContextMenu.Item } = {
					{ kind = "header", text = string.format("关键帧 @ %.2fs", kf.t) },
					{
						text = "定位到此帧",
						onClick = function()
							state:setTime(kf.t)
						end,
					},
					{
						text = "改时间(帧)…",
						onClick = function()
							local fps = state.fps:get()
							InputPrompt.show(gui, {
								title = "关键帧时间(帧)",
								default = tostring(math.round(kf.t * fps)),
								onSubmit = function(txt)
									local f = tonumber(txt)
									if f then
										state:pushUndo()
										kf.t = math.clamp(f / fps, 0, state.duration:get())
										state:finishDrag()
									end
								end,
							})
						end,
					},
				}
				-- 相机类关键帧:视口对帧调整(跳进该帧视角,自由取景实时写回)
				if (track.kind == "camera" or track.kind == "cameraMove") and kf.value then
					local adjusting = cb.adjustingKf:get() == kf
					table.insert(items, {
						text = if adjusting
							then "⏹ 结束视口调整"
							else "🎥 视口调整此帧",
						onClick = function()
							cb.onAdjustKeyframe(track, kf)
						end,
					})
					if track.pathMode == "bezier" and track.keyframes then
						for i, k in track.keyframes do
							if k == kf and track.keyframes[i + 1] then
								local nextKf = track.keyframes[i + 1]
								table.insert(items, {
									text = string.format(
										"在 %.2f–%.2fs 段中插入关键帧",
										kf.t,
										nextKf.t
									),
									onClick = function()
										state:insertPathKeyframeMidpoint(track, kf, nextKf)
									end,
								})
								break
							end
						end
					end
				end
				table.insert(items, {
					text = "复制(+0.5s)",
					onClick = function()
						state:duplicateKeyframe(track, kf)
					end,
				})
				if kf.value then
					table.insert(items, {
						text = "复制到剪贴板",
						onClick = function()
							_kfClipboard = {
								kind = "cframe",
								value = kf.value,
								easing = kf.easing,
								outTangent = kf.outTangent,
								inTangent = kf.inTangent,
							}
						end,
					})
				end
				table.insert(items, { kind = "header", text = "缓动" })
				for _, ez in Easing.names do
					table.insert(items, {
						text = easingMenuText(ez),
						onClick = function()
							state:setEasing(kf, ez :: any)
						end,
					})
				end
				table.insert(items, { kind = "sep" })
				table.insert(items, {
					text = "删除关键帧",
					color = Theme.color.danger,
					onClick = function()
						state:removeKeyframe(track, kf)
					end,
				})
				ContextMenu.show(gui, items)
			end
		end,
		[Children] = e("UICorner")({ CornerRadius = UDim.new(0, 2) }),
	})
	return diamond
end

-- 属性关键帧菱形:长按拖时间、右键 定位/改时间/改值/缓动/删除(17 spec)。
local function propDiamond(
	gui: PluginGui,
	state: EditorState.EditorState,
	area: () -> GuiObject,
	track: CutsceneFormat.Track,
	kf: CutsceneFormat.PropKeyframe
): Instance
	local dur = state.duration:get()
	local sz = Theme.size.keyframe
	local diamond
	diamond = e("TextButton")({
		BackgroundColor3 = Theme.trackColor("property"),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(kf.t / dur, 0.5),
		Size = UDim2.fromOffset(sz, sz),
		Rotation = 45,
		Text = "",
		AutoButtonColor = true,
		ZIndex = 6,
		[OnEvent("InputBegan")] = function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				local grab = DragController.fracInArea(area(), gui:GetRelativeMousePosition(), gui)
						* state.duration:get()
					- kf.t
				beginTimelineDrag(gui, {
					onBegin = function()
						state:pushUndo()
					end,
					onMove = function(mouse)
						kf.t = draggedTime(
							gui,
							state,
							area(),
							mouse,
							grab,
							track,
							{ propKeyframe = kf }
						)
						diamond.Position = UDim2.fromScale(kf.t / state.duration:get(), 0.5)
					end,
					onEnd = function()
						state:finishDrag()
					end,
				}, diamond, input)
			elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
				local items: { ContextMenu.Item } = {
					{
						kind = "header",
						text = string.format(
							"%s = %s @ %.2fs",
							track.propertyName or "?",
							propValueToText(kf.value),
							kf.t
						),
					},
					{
						text = "定位到此帧",
						onClick = function()
							state:setTime(kf.t)
						end,
					},
					{
						text = "改时间(帧)…",
						onClick = function()
							local fps = state.fps:get()
							InputPrompt.show(gui, {
								title = "关键帧时间(帧)",
								default = tostring(math.round(kf.t * fps)),
								onSubmit = function(txt)
									local f = tonumber(txt)
									if f then
										state:pushUndo()
										kf.t = math.clamp(f / fps, 0, state.duration:get())
										state:finishDrag()
									end
								end,
							})
						end,
					},
					{
						text = "改值…",
						onClick = function()
							InputPrompt.show(gui, {
								title = string.format(
									"%s 的值(%s)",
									track.propertyName or "?",
									typeof(kf.value)
								),
								default = propValueToText(kf.value),
								onSubmit = function(txt)
									local v = propValueFromText(txt, kf.value)
									if v ~= nil then
										state:setPropKeyframeValue(track, kf, v)
									else
										warn(
											`[anima] 属性值解析失败:'{txt}'({typeof(kf.value)})`
										)
									end
								end,
							})
						end,
					},
					{
						text = "复制(+0.5s)",
						onClick = function()
							state:duplicatePropKeyframe(track, kf)
						end,
					},
					{
						text = "复制到剪贴板",
						onClick = function()
							_kfClipboard = { kind = "prop", value = kf.value, easing = kf.easing }
						end,
					},
				}
				if CutsceneFormat.propValueLerpable(kf.value) then
					table.insert(items, { kind = "header", text = "缓动" })
					for _, ez in Easing.names do
						table.insert(items, {
							text = easingMenuText(ez),
							onClick = function()
								state:setEasing(kf, ez :: any)
							end,
						})
					end
				end
				table.insert(items, { kind = "sep" })
				table.insert(items, {
					text = "删除关键帧",
					color = Theme.color.danger,
					onClick = function()
						state:removePropKeyframe(track, kf)
					end,
				})
				ContextMenu.show(gui, items)
			end
		end,
		[Children] = e("UICorner")({ CornerRadius = UDim.new(0, 2) }),
	})
	return diamond
end

-- 动画 Clip 条:中间平移;左右缘改 startAt/endAt;录入 id 后自动匹配源时长。
local function clipBlock(
	gui: PluginGui,
	state: EditorState.EditorState,
	area: () -> GuiObject,
	track: CutsceneFormat.Track,
	clip: CutsceneFormat.AnimationClip,
	clipIndex: number,
	nextT: number
): Instance
	local function minClipDur(): number
		return 1 / math.max(state.fps:get(), 1)
	end

	-- endAt=nil 时用已缓存的源动画时长(÷speed),宽度即真实时长(18 spec)
	local function clipEndVisual(_d: number): number
		return CutsceneFormat.clipTimelineEnd(
			clip,
			nextT,
			AnimationAsset.cachedLength(clip.animationId, clip)
		)
	end

	local block
	local function refresh()
		local d = state.duration:get()
		local endT = clipEndVisual(d)
		block.Position = UDim2.new(clip.startAt / d, 1, 0, 4)
		block.Size = UDim2.new(math.max((endT - clip.startAt) / d, 0.02), -2, 1, -8)
		local lbl = block:FindFirstChild("ClipLabel")
		if lbl and lbl:IsA("TextLabel") then
			local primary = TimelineUnity.clipPrimaryTitle(track, clipIndex)
			local secondary = TimelineUnity.clipSecondaryLine(clip, state.fps:get())
			lbl.Text = primary .. "\n" .. secondary
		end
	end

	local function beginClipEdgeDrag(
		mode: "from" | "to",
		pressInput: InputObject,
		feedback: GuiObject
	)
		local grab = DragController.fracInArea(area(), gui:GetRelativeMousePosition(), gui)
				* state.duration:get()
			- (if mode == "from" then clip.startAt else (clip.endAt or clip.startAt + 1.5))
		local snapStart, snapEnd = clip.startAt, clip.endAt
		beginTimelineDrag(gui, {
			onBegin = function()
				snapStart, snapEnd = clip.startAt, clip.endAt
				state:pushUndo()
			end,
			onMove = function(mouse)
				local t = draggedTime(
					gui,
					state,
					area(),
					mouse,
					grab,
					track,
					{ clip = clip },
					{ edgeMode = mode }
				)
				local minLen = minClipDur()
				if mode == "from" then
					local endFix = clip.endAt or clip.startAt + 1.5
					clip.startAt = math.min(t, endFix - minLen)
				else
					clip.endAt = math.max(t, clip.startAt + minLen)
				end
				refresh()
			end,
			onEnd = function()
				state:finishClipDrag(track)
			end,
			onCancel = function()
				clip.startAt = snapStart
				clip.endAt = snapEnd
				refresh()
			end,
		}, feedback, pressInput)
	end

	local function beginClipBodyDrag(pressInput: InputObject)
		local mouse = gui:GetRelativeMousePosition()
		local blockLeft = block.AbsolutePosition.X
		local relX = mouse.X - blockLeft
		local w = math.max(block.AbsoluteSize.X, 1)
		if relX < SEGMENT_EDGE_PX or relX > w - SEGMENT_EDGE_PX then
			return
		end
		local grab = DragController.fracInArea(area(), mouse, gui) * state.duration:get()
			- clip.startAt
		local len0 = (clip.endAt or clip.startAt + 1.5) - clip.startAt
		local snapStart, snapEnd = clip.startAt, clip.endAt
		beginTimelineDrag(gui, {
			onBegin = function()
				snapStart, snapEnd = clip.startAt, clip.endAt
				state:pushUndo()
			end,
			onMove = function(moveMouse)
				local dur = state.duration:get()
				local newFrom = draggedTime(
					gui,
					state,
					area(),
					moveMouse,
					grab,
					track,
					{ clip = clip },
					{ edgeMode = "from" }
				)
				newFrom = math.clamp(newFrom, 0, math.max(0, dur - len0))
				clip.startAt = newFrom
				clip.endAt = newFrom + len0
				refresh()
			end,
			onEnd = function()
				state:finishClipDrag(track)
			end,
			onClick = function() end,
			onCancel = function()
				clip.startAt = snapStart
				clip.endAt = snapEnd
				refresh()
			end,
		}, block, pressInput)
	end

	local function edgeHit(anchorX: number): Instance
		local hitBtn: TextButton
		hitBtn = e("TextButton")({
			BackgroundTransparency = 1,
			Text = "",
			Size = UDim2.new(0, SEGMENT_EDGE_PX, 1, 0),
			AnchorPoint = Vector2.new(anchorX, 0),
			Position = UDim2.fromScale(anchorX, 0),
			ZIndex = 10,
			AutoButtonColor = false,
			[OnEvent("InputBegan")] = function(input: InputObject)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					beginClipEdgeDrag(if anchorX == 0 then "from" else "to", input, hitBtn)
				end
			end,
			[Children] = e("Frame")({
				BackgroundColor3 = Theme.color.handle,
				BackgroundTransparency = 0.25,
				BorderSizePixel = 0,
				Size = UDim2.new(0, SEGMENT_EDGE_BAR_PX, 1, 0),
				AnchorPoint = Vector2.new(anchorX, 0),
				Position = UDim2.fromScale(anchorX, 0),
				ZIndex = 1,
				Active = false,
			}),
		}) :: TextButton
		return hitBtn
	end

	local dur = state.duration:get()
	local endT0 = clipEndVisual(dur)
	local w0 = math.max((endT0 - clip.startAt) / dur, 0.02)
	local leftEdge = edgeHit(0)
	local rightEdge = edgeHit(1)
	block = e("TextButton")({
		BackgroundColor3 = Theme.color.track.animation,
		BackgroundTransparency = 0.08,
		Position = UDim2.new(clip.startAt / dur, 1, 0, 4),
		Size = UDim2.new(w0, -2, 1, -8),
		Text = "",
		AutoButtonColor = false,
		ZIndex = 7,
		[OnEvent("InputBegan")] = function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				beginClipBodyDrag(input)
				return
			elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
				ContextMenu.show(gui, {
					{ kind = "header", text = "动画片段" },
					{
						text = "定位到起播",
						onClick = function()
							state:setTime(clip.startAt)
						end,
					},
					{
						text = "改起播帧…",
						onClick = function()
							local fps = state.fps:get()
							InputPrompt.show(gui, {
								title = "起播时间(帧)",
								default = tostring(math.round(clip.startAt * fps)),
								onSubmit = function(txt)
									local f = tonumber(txt)
									if f then
										state:pushUndo()
										local len = (clip.endAt or clip.startAt + 1.5)
											- clip.startAt
										clip.startAt =
											math.clamp(f / fps, 0, state.duration:get() - len)
										if clip.endAt then
											clip.endAt = clip.startAt + len
										end
										state:finishClipDrag(track)
									end
								end,
							})
						end,
					},
					{
						text = "改结束帧…",
						onClick = function()
							local fps = state.fps:get()
							local endV = clip.endAt or clip.startAt + 1.5
							InputPrompt.show(gui, {
								title = "结束时间(帧)",
								default = tostring(math.round(endV * fps)),
								onSubmit = function(txt)
									local f = tonumber(txt)
									if f then
										state:pushUndo()
										state:setClipEndAt(clip, f / fps)
										state:finishClipDrag(track)
									end
								end,
							})
						end,
					},
					{
						text = "改 AnimationId…",
						onClick = function()
							InputPrompt.show(gui, {
								title = "动画 AnimationId",
								default = clip.animationId,
								placeholder = "rbxassetid://… 或数字 id",
								onSubmit = function(txt)
									if txt ~= "" then
										state:applyClipAnimationId(track, clip, txt, nil)
									end
								end,
							})
						end,
					},
					{
						text = "按动画时长重算条长",
						onClick = function()
							state:pushUndo()
							state:syncClipLengthFromAsset(clip, track, nil)
						end,
					},
					{
						text = "改速度 speed…",
						onClick = function()
							InputPrompt.show(gui, {
								title = "播放速度(1=正常)",
								default = tostring(clip.speed or 1),
								onSubmit = function(txt)
									local n = tonumber(txt)
									if n then
										state:setClipField(clip, "speed", n)
									end
								end,
							})
						end,
					},
					{
						text = if clip.looped then "关闭循环" else "开启循环",
						onClick = function()
							state:setClipField(clip, "looped", not clip.looped)
						end,
					},
					{ kind = "sep" },
					{
						text = "Rig：R6 专用",
						onClick = function()
							state:setClipField(clip, "rigType", "R6")
						end,
					},
					{
						text = "Rig：R15 专用",
						onClick = function()
							state:setClipField(clip, "rigType", "R15")
						end,
					},
					{
						text = "Rig：不限(清除)",
						onClick = function()
							state:setClipField(clip, "rigType", nil)
						end,
					},
					{ kind = "sep" },
					{
						text = "删除片段",
						color = Theme.color.danger,
						onClick = function()
							state:removeClip(track, clip)
						end,
					},
				}, { width = 240 })
			end
		end,
		[Children] = {
			e("UICorner")({ CornerRadius = UDim.new(0, 3) }),
			e("Frame")({
				BackgroundColor3 = Theme.color.clipHeader,
				BackgroundTransparency = 0.35,
				BorderSizePixel = 0,
				Size = UDim2.new(0, 4, 1, 0),
				Active = false,
			}),
			leftEdge,
			rightEdge,
			e("TextLabel")({
				Name = "ClipLabel",
				BackgroundTransparency = 1,
				Size = UDim2.fromScale(1, 1),
				Text = TimelineUnity.clipPrimaryTitle(track, clipIndex)
					.. "\n"
					.. TimelineUnity.clipSecondaryLine(clip, state.fps:get()),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
				TextTruncate = Enum.TextTruncate.AtEnd,
				ZIndex = 2,
				TextColor3 = Theme.color.clipLabelText,
				TextStrokeColor3 = Theme.color.clipLabelStroke,
				TextStrokeTransparency = 0.35,
				Font = Theme.font.bold,
				TextSize = 11,
				[Children] = e("UIPadding")({
					PaddingLeft = UDim.new(0, 8),
					PaddingTop = UDim.new(0, 2),
				}),
			}),
		},
	})
	return block
end

-- Marker(对标 Unity Timeline Marker / Signal 行上的竖线标记)。
local function eventDiamond(
	gui: PluginGui,
	state: EditorState.EditorState,
	area: () -> GuiObject,
	track: CutsceneFormat.Track,
	ev: CutsceneFormat.CutsceneEvent
): Instance
	local dur = state.duration:get()
	local container
	local hitTarget
	local markerLine = e("Frame")({
		BackgroundColor3 = Theme.color.marker,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0, 2, 1, 0),
		ZIndex = 5,
	})
	hitTarget = e("TextButton")({
		BackgroundTransparency = 1,
		Size = UDim2.new(0, 16, 1, 0),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Text = "",
		ZIndex = 6,
		[OnEvent("InputBegan")] = function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				local grab = DragController.fracInArea(area(), gui:GetRelativeMousePosition(), gui)
						* state.duration:get()
					- ev.t
				beginTimelineDrag(gui, {
					onBegin = function()
						state:pushUndo()
					end,
					onMove = function(mouse)
						ev.t = draggedTime(gui, state, area(), mouse, grab, track, { event = ev })
						container.Position = UDim2.fromScale(ev.t / state.duration:get(), 0.5)
					end,
					onEnd = function()
						state:finishDrag()
					end,
				}, hitTarget, input)
			elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
				ContextMenu.show(gui, {
					{ kind = "header", text = "标记 · " .. ev.name },
					{
						text = "定位到此事件",
						onClick = function()
							state:setTime(ev.t)
						end,
					},
					{
						text = "改时间(帧)…",
						onClick = function()
							local fps = state.fps:get()
							InputPrompt.show(gui, {
								title = "事件时间(帧)",
								default = tostring(math.round(ev.t * fps)),
								onSubmit = function(txt)
									local f = tonumber(txt)
									if f then
										state:pushUndo()
										ev.t = math.clamp(f / fps, 0, state.duration:get())
										state:finishDrag()
									end
								end,
							})
						end,
					},
					{
						text = "改名…",
						onClick = function()
							InputPrompt.show(gui, {
								title = "事件名(供 onEvent 分发)",
								default = ev.name,
								placeholder = "如 sfx_door / vfx_dust",
								onSubmit = function(txt)
									if txt ~= "" then
										state:renameEvent(ev, txt)
									end
								end,
							})
						end,
					},
					{
						text = "复制到剪贴板",
						onClick = function()
							_kfClipboard = {
								kind = "event",
								name = ev.name,
								payload = if ev.payload then table.clone(ev.payload) else nil,
							}
						end,
					},
					{
						text = if ev.payload
							then "编辑 payload…(" .. payloadToText(ev.payload) .. ")"
							else "编辑 payload…",
						onClick = function()
							InputPrompt.show(gui, {
								title = "payload(k=v; k2=v2;数字/true/false 自动转型,空=清除)",
								default = if ev.payload then payloadToText(ev.payload) else "",
								placeholder = "如 soundId=123456; volume=0.5",
								onSubmit = function(txt)
									local payload, err = payloadFromText(txt)
									if err then
										warn("[anima] payload 解析失败:" .. err)
										return
									end
									state:setEventPayload(track, ev, payload)
								end,
							})
						end,
					},
					{ kind = "sep" },
					{
						text = "删除标记",
						color = Theme.color.danger,
						onClick = function()
							state:removeEvent(track, ev)
						end,
					},
				})
			end
		end,
	})
	local label = e("TextLabel")({
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0.5, 4, 0, -2),
		Size = UDim2.fromOffset(120, 14),
		Text = ev.name,
		TextColor3 = Theme.color.marker,
		Font = Theme.font.bold,
		TextSize = 10,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 7,
	})
	local cap = e("TextLabel")({
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromOffset(10, 10),
		Text = "▼",
		TextColor3 = Theme.color.marker,
		Font = Theme.font.bold,
		TextSize = 8,
		ZIndex = 6,
	})
	container = e("Frame")({
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(ev.t / dur, 0.5),
		Size = UDim2.new(0, 130, 1, 0),
		[Children] = { markerLine, hitTarget, cap, label },
	})
	return container
end

local function soundCueMarker(
	gui: PluginGui,
	state: EditorState.EditorState,
	area: () -> GuiObject,
	track: CutsceneFormat.Track,
	cue: CutsceneFormat.SoundCue
): Instance
	local dur = state.duration:get()
	local color = Theme.trackColor("sound")
	local labelText = cue.soundId:match("(%d+)$") or cue.soundId
	local container
	local hitTarget
	local markerLine = e("Frame")({
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0, 2, 1, 0),
		ZIndex = 5,
	})
	hitTarget = e("TextButton")({
		BackgroundTransparency = 1,
		Size = UDim2.new(0, 16, 1, 0),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Text = "",
		ZIndex = 6,
		[OnEvent("InputBegan")] = function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				local grab = DragController.fracInArea(area(), gui:GetRelativeMousePosition(), gui)
						* state.duration:get()
					- cue.t
				beginTimelineDrag(gui, {
					onBegin = function()
						state:pushUndo()
					end,
					onMove = function(mouse)
						cue.t = draggedTime(gui, state, area(), mouse, grab, track, nil)
						container.Position = UDim2.fromScale(cue.t / state.duration:get(), 0.5)
					end,
					onEnd = function()
						state:finishDrag()
					end,
				}, hitTarget, input)
			elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
				ContextMenu.show(gui, {
					{ kind = "header", text = "音效 · " .. labelText },
					{
						text = "定位",
						onClick = function()
							state:setTime(cue.t)
						end,
					},
					{
						text = "改 SoundId…",
						onClick = function()
							InputPrompt.show(gui, {
								title = "SoundId",
								default = cue.soundId,
								onSubmit = function(txt)
									if txt ~= "" then
										state:setSoundCueField(cue, "soundId", txt)
									end
								end,
							})
						end,
					},
					{
						text = "改音量 volume…",
						onClick = function()
							InputPrompt.show(gui, {
								title = "音量 0~1",
								default = tostring(cue.volume or 1),
								onSubmit = function(txt)
									local n = tonumber(txt)
									if n then
										state:setSoundCueField(cue, "volume", math.clamp(n, 0, 1))
									end
								end,
							})
						end,
					},
					{ kind = "sep" },
					{
						text = "删除",
						color = Theme.color.danger,
						onClick = function()
							state:removeSoundCue(track, cue)
						end,
					},
				})
			end
		end,
	})
	local label = e("TextLabel")({
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0.5, 4, 0, -2),
		Size = UDim2.fromOffset(120, 14),
		Text = "♪ " .. labelText,
		TextColor3 = color,
		Font = Theme.font.bold,
		TextSize = 10,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 7,
	})
	container = e("Frame")({
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(cue.t / dur, 0.5),
		Size = UDim2.new(0, 130, 1, 0),
		[Children] = { markerLine, hitTarget, label },
	})
	return container
end

local function effectCueMarker(
	gui: PluginGui,
	state: EditorState.EditorState,
	area: () -> GuiObject,
	track: CutsceneFormat.Track,
	cue: CutsceneFormat.EffectCue
): Instance
	local dur = state.duration:get()
	local color = Theme.trackColor("effect")
	local labelText
	if cue.emitMode == "forge" then
		labelText = "forge:" .. (cue.forgeRoot or "*")
	else
		labelText = cue.templateName
			or (cue.particleAssetId and (cue.particleAssetId:match("(%d+)$") or cue.particleAssetId))
			or "fx"
	end
	local container
	local hitTarget
	local markerLine = e("Frame")({
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0, 2, 1, 0),
		ZIndex = 5,
	})
	hitTarget = e("TextButton")({
		BackgroundTransparency = 1,
		Size = UDim2.new(0, 16, 1, 0),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Text = "",
		ZIndex = 6,
		[OnEvent("InputBegan")] = function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				local grab = DragController.fracInArea(area(), gui:GetRelativeMousePosition(), gui)
						* state.duration:get()
					- cue.t
				beginTimelineDrag(gui, {
					onBegin = function()
						state:pushUndo()
					end,
					onMove = function(mouse)
						cue.t = draggedTime(gui, state, area(), mouse, grab, track, nil)
						container.Position = UDim2.fromScale(cue.t / state.duration:get(), 0.5)
					end,
					onEnd = function()
						state:finishDrag()
					end,
				}, hitTarget, input)
			elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
				ContextMenu.show(gui, {
					{ kind = "header", text = "特效 · " .. labelText },
					{
						text = "定位",
						onClick = function()
							state:setTime(cue.t)
						end,
					},
					{
						text = "Forge: 改 forgeRoot…",
						onClick = function()
							InputPrompt.show(gui, {
								title = "forgeRoot(留空=整绑定)",
								default = cue.forgeRoot or "",
								onSubmit = function(txt)
									state:setEffectCueField(
										cue,
										"forgeRoot",
										if txt ~= "" then txt else nil
									)
									state:setEffectCueField(cue, "emitMode", "forge")
								end,
							})
						end,
					},
					{
						text = "Forge: 改 forgeScale…",
						onClick = function()
							InputPrompt.show(gui, {
								title = "forgeScale",
								default = tostring(cue.forgeScale or 1),
								onSubmit = function(txt)
									local n = tonumber(txt)
									if n then
										state:setEffectCueField(cue, "forgeScale", n)
										state:setEffectCueField(cue, "emitMode", "forge")
									end
								end,
							})
						end,
					},
					{
						text = "切换为 Forge 模式",
						onClick = function()
							state:setEffectCueField(cue, "emitMode", "forge")
							state:setEffectCueField(cue, "templateName", nil)
							state:setEffectCueField(cue, "particleAssetId", nil)
						end,
					},
					{
						text = "切换为粒子模式",
						onClick = function()
							state:setEffectCueField(cue, "emitMode", nil)
							state:setEffectCueField(cue, "forgeRoot", nil)
							state:setEffectCueField(cue, "forgeScale", nil)
						end,
					},
					{
						text = "改模板名 templateName…",
						onClick = function()
							InputPrompt.show(gui, {
								title = "ParticleEmitter 名",
								default = cue.templateName or "",
								onSubmit = function(txt)
									state:setEffectCueField(cue, "emitMode", nil)
									state:setEffectCueField(
										cue,
										"templateName",
										if txt ~= "" then txt else nil
									)
								end,
							})
						end,
					},
					{
						text = "改粒子资源 id…",
						onClick = function()
							InputPrompt.show(gui, {
								title = "particleAssetId",
								default = cue.particleAssetId or "",
								onSubmit = function(txt)
									state:setEffectCueField(
										cue,
										"particleAssetId",
										if txt ~= "" then txt else nil
									)
								end,
							})
						end,
					},
					{
						text = "改 emitCount…",
						onClick = function()
							InputPrompt.show(gui, {
								title = "Emit 数量",
								default = tostring(cue.emitCount or 1),
								onSubmit = function(txt)
									local n = tonumber(txt)
									if n then
										state:setEffectCueField(
											cue,
											"emitCount",
											math.max(1, math.floor(n))
										)
									end
								end,
							})
						end,
					},
					{ kind = "sep" },
					{
						text = "删除",
						color = Theme.color.danger,
						onClick = function()
							state:removeEffectCue(track, cue)
						end,
					},
				})
			end
		end,
	})
	local label = e("TextLabel")({
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0.5, 4, 0, -2),
		Size = UDim2.fromOffset(120, 14),
		Text = "✦ " .. labelText,
		TextColor3 = color,
		Font = Theme.font.bold,
		TextSize = 10,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 7,
	})
	container = e("Frame")({
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(cue.t / dur, 0.5),
		Size = UDim2.new(0, 130, 1, 0),
		[Children] = { markerLine, hitTarget, label },
	})
	return container
end

local SCREEN_CUE_CN: { [string]: string } = {
	fade = "淡入淡出",
	letterbox = "黑边",
	tint = "红屏",
	splash = "溅血",
}

-- 演出轨 cue 标记(22 spec):长按拖时间;右键 定位/改参数/缓动/删除。
local function screenCueMarker(
	gui: PluginGui,
	state: EditorState.EditorState,
	area: () -> GuiObject,
	track: CutsceneFormat.Track,
	cue: CutsceneFormat.ScreenCue
): Instance
	local dur = state.duration:get()
	local color = Theme.trackColor("screen")
	local labelText = SCREEN_CUE_CN[cue.kind] or cue.kind
	local container
	local hitTarget
	local markerLine = e("Frame")({
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0, 2, 1, 0),
		ZIndex = 5,
	})
	local function promptNumber(title: string, default: number, apply: (n: number) -> ())
		InputPrompt.show(gui, {
			title = title,
			default = tostring(default),
			onSubmit = function(txt)
				local n = tonumber(txt)
				if n then
					apply(n)
				end
			end,
		})
	end
	local function promptColor(title: string, default: Color3?, field: string)
		local d = default or Color3.new(1, 1, 1)
		InputPrompt.show(gui, {
			title = title .. "(r,g,b 0–255)",
			default = string.format(
				"%d,%d,%d",
				math.round(d.R * 255),
				math.round(d.G * 255),
				math.round(d.B * 255)
			),
			onSubmit = function(txt)
				local a, b, c = txt:match("^%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*$")
				local r, g, bl = tonumber(a), tonumber(b), tonumber(c)
				if r and g and bl then
					state:setScreenCueField(
						cue,
						field,
						Color3.fromRGB(
							math.clamp(r, 0, 255),
							math.clamp(g, 0, 255),
							math.clamp(bl, 0, 255)
						)
					)
				end
			end,
		})
	end
	hitTarget = e("TextButton")({
		BackgroundTransparency = 1,
		Size = UDim2.new(0, 16, 1, 0),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Text = "",
		ZIndex = 6,
		[OnEvent("InputBegan")] = function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				local grab = DragController.fracInArea(area(), gui:GetRelativeMousePosition(), gui)
						* state.duration:get()
					- cue.t
				beginTimelineDrag(gui, {
					onBegin = function()
						state:pushUndo()
					end,
					onMove = function(mouse)
						cue.t = draggedTime(gui, state, area(), mouse, grab, track, nil)
						container.Position = UDim2.fromScale(cue.t / state.duration:get(), 0.5)
					end,
					onEnd = function()
						state:finishDrag()
					end,
				}, hitTarget, input)
			elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
				local items: { ContextMenu.Item } = {
					{ kind = "header", text = "演出 · " .. labelText },
					{
						text = "定位",
						onClick = function()
							state:setTime(cue.t)
						end,
					},
					{
						text = string.format("改时长… (%.2fs)", cue.duration or 1),
						onClick = function()
							promptNumber("效果总时长(秒)", cue.duration or 1, function(n)
								state:setScreenCueField(cue, "duration", math.max(n, 0.01))
							end)
						end,
					},
				}
				if cue.kind == "fade" then
					table.insert(items, {
						text = string.format("改目标不透明度… (%.2f)", cue.to or 1),
						onClick = function()
							promptNumber(
								"遮罩不透明度 0(透)–1(全遮)",
								cue.to or 1,
								function(n)
									state:setScreenCueField(cue, "to", math.clamp(n, 0, 1))
								end
							)
						end,
					})
					table.insert(items, {
						text = "改遮罩颜色…",
						onClick = function()
							promptColor("遮罩颜色", cue.color or Color3.new(0, 0, 0), "color")
						end,
					})
				elseif cue.kind == "letterbox" then
					table.insert(items, {
						text = string.format("改黑边高占比… (%.2f)", cue.to or 0.12),
						onClick = function()
							promptNumber(
								"单边黑边高占比 0–0.5;0 = 收起",
								cue.to or 0.12,
								function(n)
									state:setScreenCueField(cue, "to", math.clamp(n, 0, 0.5))
								end
							)
						end,
					})
				elseif cue.kind == "tint" then
					table.insert(items, {
						text = "改染色…",
						onClick = function()
							promptColor("染色", cue.tintColor, "tintColor")
						end,
					})
					table.insert(items, {
						text = string.format("改饱和度… (%.2f)", cue.saturation or 0),
						onClick = function()
							promptNumber(
								"饱和度偏移 -1–1(负 = 褪色)",
								cue.saturation or 0,
								function(n)
									state:setScreenCueField(cue, "saturation", math.clamp(n, -1, 1))
								end
							)
						end,
					})
					table.insert(items, {
						text = string.format("改顶峰保持… (%.2fs)", cue.hold or 0),
						onClick = function()
							promptNumber("顶峰保持时长(秒)", cue.hold or 0, function(n)
								state:setScreenCueField(cue, "hold", math.max(n, 0))
							end)
						end,
					})
				elseif cue.kind == "splash" then
					table.insert(items, {
						text = "改贴图 id…",
						onClick = function()
							InputPrompt.show(gui, {
								title = "溅血贴图 rbxassetid",
								default = cue.imageId or "",
								placeholder = "rbxassetid://…",
								onSubmit = function(txt)
									state:setScreenCueField(
										cue,
										"imageId",
										if txt ~= "" then txt else nil
									)
								end,
							})
						end,
					})
					table.insert(items, {
						text = string.format("改张数… (%d)", cue.count or 3),
						onClick = function()
							promptNumber("贴图张数", cue.count or 3, function(n)
								state:setScreenCueField(cue, "count", math.max(1, math.floor(n)))
							end)
						end,
					})
					table.insert(items, {
						text = string.format("改停留占比… (%.2f)", cue.holdRatio or 0.3),
						onClick = function()
							promptNumber(
								"停留段占总时长比 0–1",
								cue.holdRatio or 0.3,
								function(n)
									state:setScreenCueField(cue, "holdRatio", math.clamp(n, 0, 1))
								end
							)
						end,
					})
				end
				table.insert(items, { kind = "header", text = "缓动" })
				for _, ez in Easing.names do
					table.insert(items, {
						text = easingMenuText(ez),
						onClick = function()
							state:setScreenCueField(cue, "easing", ez)
						end,
					})
				end
				table.insert(items, { kind = "sep" })
				table.insert(items, {
					text = "删除",
					color = Theme.color.danger,
					onClick = function()
						state:removeScreenCue(track, cue)
					end,
				})
				ContextMenu.show(gui, items)
			end
		end,
	})
	local label = e("TextLabel")({
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0.5, 4, 0, -2),
		Size = UDim2.fromOffset(120, 14),
		Text = "▣ " .. labelText,
		TextColor3 = color,
		Font = Theme.font.bold,
		TextSize = 10,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 7,
	})
	container = e("Frame")({
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(cue.t / dur, 0.5),
		Size = UDim2.new(0, 130, 1, 0),
		[Children] = { markerLine, hitTarget, label },
	})
	return container
end

-- 相机轨的一个生效段块:中间长按平移;左右缘长按改长度;短按选中;右键菜单。
local function segmentBlock(
	gui: PluginGui,
	state: EditorState.EditorState,
	cb: Callbacks,
	area: () -> GuiObject,
	track: CutsceneFormat.Track,
	segment: CutsceneFormat.CameraSegment
): Instance
	local function seg(): CutsceneFormat.CameraSegment
		return segment
	end
	local function segIndex(): number
		local segs = track.segments
		if not segs then
			return 1
		end
		for idx, s in segs do
			if s == segment then
				return idx
			end
		end
		return 1
	end
	local block
	local function refresh()
		local d = math.max(state.duration:get(), 1e-3)
		local s = seg()
		local span = math.max(s.to - s.from, 1 / math.max(state.fps:get(), 1))
		block.Position = UDim2.new(math.clamp(s.from / d, 0, 1), 1, 0, 4)
		block.Size = UDim2.new(math.clamp(span / d, 0.005, 1), -2, 1, -8)
		local fpsNow = state.fps:get()
		local txt = TimelineUnity.cameraSegmentTitle(track)
			.. "  "
			.. TimelineUnity.cameraSegmentSubtitle(track, s.from, s.to, fpsNow)
		local lbl = block:FindFirstChild("SegLabel")
		if lbl and lbl:IsA("TextLabel") then
			lbl.Text = txt
		end
	end
	local function selectSelf()
		state.selectedTrack:set(table.find(state.tracks:get(), track))
	end
	local selectedStroke = Computed(function()
		local sel = state.selectedTrack:get() == table.find(state.tracks:get(), track)
		return if sel then 0 else 1
	end)

	local function minSegDur(): number
		return 1 / math.max(state.fps:get(), 1)
	end

	local function beginSegmentEdgeDrag(
		mode: "from" | "to",
		pressInput: InputObject,
		feedback: GuiObject
	)
		local grab = DragController.fracInArea(area(), gui:GetRelativeMousePosition(), gui)
				* state.duration:get()
			- (if mode == "from" then seg().from else seg().to)
		local snapFrom, snapTo = seg().from, seg().to
		beginTimelineDrag(gui, {
			onBegin = function()
				snapFrom, snapTo = seg().from, seg().to
				state:pushUndo()
			end,
			onMove = function(mouse)
				local t = draggedTime(
					gui,
					state,
					area(),
					mouse,
					grab,
					track,
					{ segment = seg() },
					{ edgeMode = mode }
				)
				local s = seg()
				local minLen = minSegDur()
				if mode == "from" then
					s.from = math.min(t, s.to - minLen)
				else
					s.to = math.max(t, s.from + minLen)
				end
				refresh()
			end,
			onEnd = function()
				state:finishCameraSegmentDrag(track)
			end,
			onCancel = function()
				local s = seg()
				s.from, s.to = snapFrom, snapTo
				refresh()
			end,
		}, feedback, pressInput)
	end

	local function beginSegmentBodyDrag(pressInput: InputObject)
		local mouse = gui:GetRelativeMousePosition()
		local blockLeft = block.AbsolutePosition.X
		local relX = mouse.X - blockLeft
		local w = math.max(block.AbsoluteSize.X, 1)
		if relX < SEGMENT_EDGE_PX or relX > w - SEGMENT_EDGE_PX then
			return
		end
		local grab = DragController.fracInArea(area(), mouse, gui) * state.duration:get()
			- seg().from
		local len0 = seg().to - seg().from
		local snapFrom, snapTo = seg().from, seg().to
		beginTimelineDrag(gui, {
			onBegin = function()
				snapFrom, snapTo = seg().from, seg().to
				state:pushUndo()
			end,
			onMove = function(moveMouse)
				local dur = state.duration:get()
				local newFrom = draggedTime(
					gui,
					state,
					area(),
					moveMouse,
					grab,
					track,
					{ segment = seg() },
					{ edgeMode = "from" }
				)
				newFrom = math.clamp(newFrom, 0, math.max(0, dur - len0))
				local s = seg()
				s.from = newFrom
				s.to = newFrom + len0
				refresh()
			end,
			onEnd = function()
				state:finishCameraSegmentDrag(track)
			end,
			onClick = function()
				selectSelf()
			end,
			onCancel = function()
				local s = seg()
				s.from, s.to = snapFrom, snapTo
				refresh()
			end,
		}, block, pressInput)
	end

	local function edgeHit(anchorX: number): Instance
		local hitBtn: TextButton
		hitBtn = e("TextButton")({
			BackgroundTransparency = 1,
			Text = "",
			Size = UDim2.new(0, SEGMENT_EDGE_PX, 1, 0),
			AnchorPoint = Vector2.new(anchorX, 0),
			Position = UDim2.fromScale(anchorX, 0),
			ZIndex = 10,
			AutoButtonColor = false,
			[OnEvent("InputBegan")] = function(input: InputObject)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					beginSegmentEdgeDrag(if anchorX == 0 then "from" else "to", input, hitBtn)
				end
			end,
			[Children] = e("Frame")({
				BackgroundColor3 = Theme.color.handle,
				BackgroundTransparency = 0.25,
				BorderSizePixel = 0,
				Size = UDim2.new(0, SEGMENT_EDGE_BAR_PX, 1, 0),
				AnchorPoint = Vector2.new(anchorX, 0),
				Position = UDim2.fromScale(anchorX, 0),
				ZIndex = 1,
				Active = false,
			}),
		}) :: TextButton
		return hitBtn
	end

	local dur = math.max(state.duration:get(), 1e-3)
	local s0 = seg()
	local fps = state.fps:get()
	local segText = TimelineUnity.cameraSegmentTitle(track)
		.. "  "
		.. TimelineUnity.cameraSegmentSubtitle(track, s0.from, s0.to, fps)
	local leftEdge = edgeHit(0)
	local rightEdge = edgeHit(1)
	block = e("TextButton")({
		BackgroundColor3 = Theme.color.track.camera,
		BackgroundTransparency = 0.42,
		Position = UDim2.new(math.clamp(s0.from / dur, 0, 1), 1, 0, 4),
		Size = UDim2.new(math.clamp(math.max((s0.to - s0.from) / dur, 0.005), 0.005, 1), -2, 1, -8),
		Text = "",
		TextColor3 = Theme.color.clipLabelText,
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = Theme.font.main,
		TextSize = 10,
		TextTruncate = Enum.TextTruncate.AtEnd,
		AutoButtonColor = false,
		ZIndex = 3,
		[OnEvent("InputBegan")] = function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				beginSegmentBodyDrag(input)
				return
			end
			if input.UserInputType ~= Enum.UserInputType.MouseButton2 then
				return
			end
			selectSelf()
			local segMenu: { ContextMenu.Item } = {
				{
					kind = "header",
					text = "相机轨 " .. track.target .. "(段 " .. segIndex() .. ")",
				},
			}
			for _, pathItem in cameraPathMenuItems(gui, cb, track, state.currentTime:get(), "") do
				table.insert(segMenu, pathItem)
			end
			table.insert(segMenu, { kind = "sep" })
			table.insert(segMenu, {
				text = "定位到段起点",
				onClick = function()
					state:setTime(seg().from)
				end,
			})
			table.insert(segMenu, {
				text = "输入起止帧…",
				onClick = function()
					local s = seg()
					InputPrompt.show(gui, {
						title = "起 止 帧(空格分隔,如 30 90)",
						placeholder = "起帧 止帧",
						default = string.format(
							"%d %d",
							math.round(s.from * fps),
							math.round(s.to * fps)
						),
						onSubmit = function(txt)
							local a, b = txt:match("^%s*(%-?%d+)%s+(%-?%d+)%s*$")
							local fa, fb = tonumber(a), tonumber(b)
							if fa and fb then
								state:setSegmentRange(track, segIndex(), fa / fps, fb / fps)
							end
						end,
					})
				end,
			})
			table.insert(segMenu, {
				text = if seg().blendIn and (seg().blendIn :: number) > 0
					then string.format(
						"混入时长(crossfade)… (%.2fs)",
						seg().blendIn :: number
					)
					else "混入时长(crossfade)…(硬切)",
				onClick = function()
					InputPrompt.show(gui, {
						title = "进段混入时长(秒;0 = 硬切)",
						default = tostring(seg().blendIn or 0),
						onSubmit = function(txt)
							local n = tonumber(txt)
							if n then
								state:setSegmentBlendIn(track, seg(), n)
							end
						end,
					})
				end,
			})
			table.insert(segMenu, {
				text = "＋ 在播放头处加一段",
				onClick = function()
					state:addSegment(track, state.currentTime:get())
				end,
			})
			table.insert(segMenu, {
				text = "删除此段",
				color = Theme.color.danger,
				onClick = function()
					state:removeSegment(track, segIndex())
				end,
			})
			table.insert(segMenu, { kind = "sep" })
			table.insert(segMenu, {
				text = "删除整条相机轨",
				color = Theme.color.danger,
				onClick = function()
					state:removeTrack(track)
				end,
			})
			ContextMenu.show(gui, segMenu)
		end,
		[Children] = {
			e("UICorner")({ CornerRadius = UDim.new(0, 3) }),
			e("UIStroke")({
				Color = Theme.color.accent,
				Thickness = 2,
				Transparency = selectedStroke,
			}),
			leftEdge,
			rightEdge,
			e("TextLabel")({
				Name = "SegLabel",
				BackgroundTransparency = 1,
				Size = UDim2.fromScale(1, 1),
				Text = segText,
				TextColor3 = Theme.color.clipLabelText,
				TextStrokeColor3 = Theme.color.clipLabelStroke,
				TextStrokeTransparency = 0.35,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Center,
				Font = Theme.font.bold,
				TextSize = 11,
				TextTruncate = Enum.TextTruncate.AtEnd,
				ZIndex = 2,
				[Children] = e("UIPadding")({ PaddingLeft = UDim.new(0, 9) }),
			}),
		},
	})
	return block
end

local function trackContent(
	gui: PluginGui,
	state: EditorState.EditorState,
	cb: Callbacks,
	area: () -> GuiObject,
	track: CutsceneFormat.Track
): Instance
	local dur = state.duration:get()
	local kids: { Instance } = {}

	if track.kind == "camera" then
		local segs = track.segments
		if segs then
			for _, seg in segs do
				table.insert(kids, segmentBlock(gui, state, cb, area, track, seg))
			end
		end
		if track.keyframes then
			for _, kf in track.keyframes do
				table.insert(kids, markDiamond(gui, state, cb, area, track, kf))
			end
		end
	elseif track.kind == "animation" and track.clips and #track.clips > 0 then
		for i, c in track.clips do
			local nextT = if track.clips[i + 1] then track.clips[i + 1].startAt else dur
			table.insert(kids, clipBlock(gui, state, area, track, c, i, nextT))
		end
	elseif track.kind == "event" and track.events and #track.events > 0 then
		for _, ev in track.events do
			table.insert(kids, eventDiamond(gui, state, area, track, ev))
		end
	elseif track.kind == "sound" and track.soundCues and #track.soundCues > 0 then
		for _, cue in track.soundCues do
			table.insert(kids, soundCueMarker(gui, state, area, track, cue))
		end
	elseif track.kind == "effect" and track.effectCues and #track.effectCues > 0 then
		for _, cue in track.effectCues do
			table.insert(kids, effectCueMarker(gui, state, area, track, cue))
		end
	elseif track.kind == "screen" and track.screenCues and #track.screenCues > 0 then
		for _, cue in track.screenCues do
			table.insert(kids, screenCueMarker(gui, state, area, track, cue))
		end
	elseif track.kind == "property" and track.propKeyframes then
		for _, kf in track.propKeyframes do
			table.insert(kids, propDiamond(gui, state, area, track, kf))
		end
	elseif track.kind == "rigAnim" and track.jointTracks and #track.jointTracks > 0 then
		-- 烘焙关节数据(几十帧/关节):V1 只渲染整块,不做逐 key 编辑(20 spec)
		local minT, maxT = math.huge, 0
		for _, jt in track.jointTracks do
			local first, last = jt.keyframes[1], jt.keyframes[#jt.keyframes]
			if first and last then
				minT = math.min(minT, first.t)
				maxT = math.max(maxT, last.t)
			end
		end
		if maxT > minT then
			table.insert(
				kids,
				e("Frame")({
					BackgroundColor3 = Theme.trackColor("rigAnim"),
					BackgroundTransparency = 0.35,
					BorderSizePixel = 0,
					Position = UDim2.new(minT / dur, 1, 0, 6),
					Size = UDim2.new(math.max((maxT - minT) / dur, 0.01), -2, 1, -12),
					ZIndex = 4,
					[Children] = {
						e("UICorner")({ CornerRadius = UDim.new(0, 4) }),
						e("TextLabel")({
							BackgroundTransparency = 1,
							Size = UDim2.fromScale(1, 1),
							Text = string.format("🦴 %d 关节", #track.jointTracks),
							TextColor3 = Theme.color.clipLabelText,
							TextStrokeColor3 = Theme.color.clipLabelStroke,
							TextStrokeTransparency = 0.35,
							TextXAlignment = Enum.TextXAlignment.Left,
							Font = Theme.font.bold,
							TextSize = 11,
							TextTruncate = Enum.TextTruncate.AtEnd,
							ZIndex = 5,
							[Children] = e("UIPadding")({ PaddingLeft = UDim.new(0, 9) }),
						}),
					},
				})
			)
		end
	elseif track.keyframes then
		for _, kf in track.keyframes do
			table.insert(kids, markDiamond(gui, state, cb, area, track, kf))
		end
	end

	return e("Frame")({
		BackgroundTransparency = 1,
		Active = false,
		Size = UDim2.fromScale(1, 1),
		[Children] = {
			-- 轨道空白:点击取消选中;scrub 仅在标尺行(RulerScrubHit / PlayheadHandle)
			e("TextButton")({
				BackgroundTransparency = 1,
				Text = "",
				Size = UDim2.fromScale(1, 1),
				ZIndex = 1,
				AutoButtonColor = false,
				[OnEvent("InputBegan")] = function(input: InputObject)
					if input.UserInputType == Enum.UserInputType.MouseButton1 then
						state.selectedTrack:set(nil)
					elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
						local m = gui:GetRelativeMousePosition()
						local d = state.duration:get()
						local fps = state.fps:get()
						local atTime = math.clamp(
							math.round(DragController.fracInArea(area(), m, gui) * d * fps) / fps,
							0,
							d
						)
						task.defer(function()
							if not ContextMenu.justShown() then
								showTrackMenu(gui, state, cb, track, atTime)
							end
						end)
					end
				end,
			}),
			e("Frame")({
				BackgroundTransparency = 1,
				Active = false,
				Size = UDim2.fromScale(1, 1),
				ZIndex = 2,
				[Children] = kids,
			}),
		},
	})
end

local function rowFrame(index: number, bg: Color3, child: Instance, rowKey: string?): Instance
	return e("Frame")({
		Name = if rowKey then "AnimaRow_" .. rowKey else ("AnimaRow_" .. tostring(index)),
		BackgroundColor3 = bg,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, Theme.size.trackHeight),
		Position = UDim2.new(
			0,
			0,
			0,
			Theme.size.rulerHeight + (index - 1) * Theme.size.trackHeight
		),
		[Children] = child,
	})
end

-- 自适应网格步长(单位:帧)。major = 带帧号标签的主刻度;minor = 细分小刻度
-- (nil = 当前密度下画不下)。候选步长取"整帧数好看"的档位:1/2/5/10 帧、
-- 半秒、1/2/5/10/30/60 秒,选像素间距刚好够宽的最细一档。
local function gridSteps(fps: number, totalFrames: number, widthPx: number): (number, number?)
	local candidates: { number } = { 1, 2, 5, 10 }
	for _, sec in { 0.5, 1, 2, 5, 10, 30, 60, 120, 300 } do
		local f = math.floor(sec * fps + 0.5)
		if f > 10 then
			table.insert(candidates, f)
		end
	end
	table.sort(candidates)
	local pxPerFrame = widthPx / math.max(totalFrames, 1)
	local major = candidates[#candidates]
	for _, c in candidates do
		if c * pxPerFrame >= 72 then
			major = c
			break
		end
	end
	local minor: number? = nil
	for _, c in candidates do
		-- 必须整除 major 才不会和主刻度错位;限总数防极端缩放下实例爆炸
		if c < major and major % c == 0 and c * pxPerFrame >= 12 and totalFrames / c <= 900 then
			minor = c
			break
		end
	end
	return major, minor
end

local function ruler(
	gui: PluginGui,
	state: EditorState.EditorState,
	area: () -> GuiObject,
	areaWidth: Fusion.Value<number>
): Instance
	-- 刻度随缩放/面板宽度自适应重建(areaWidth 已含缩放倍数)
	local ticks = Computed(function()
		local dur = math.max(state.duration:get(), 1e-3)
		local fps = math.max(state.fps:get(), 1)
		local w = areaWidth:get()
		local kids: { Instance } = {}
		if w < 2 then
			return kids
		end
		local totalFrames = dur * fps
		local major, minor = gridSteps(fps, totalFrames, w)
		if minor then
			for f = 0, totalFrames, minor do
				if f % major ~= 0 then
					table.insert(
						kids,
						e("Frame")({
							BackgroundColor3 = Theme.color.line,
							BorderSizePixel = 0,
							AnchorPoint = Vector2.new(0, 1),
							Position = UDim2.fromScale(f / totalFrames, 1),
							Size = UDim2.fromOffset(1, 5),
						})
					)
				end
			end
		end
		for f = 0, totalFrames, major do
			table.insert(
				kids,
				e("Frame")({
					BackgroundColor3 = Theme.color.line,
					BorderSizePixel = 0,
					Position = UDim2.fromScale(f / totalFrames, 0),
					Size = UDim2.new(0, 1, 1, 0),
				})
			)
			table.insert(
				kids,
				e("TextLabel")({
					BackgroundTransparency = 1,
					Position = UDim2.new(f / totalFrames, 2, 0, 0),
					Size = UDim2.new(0, 44, 1, 0),
					Text = TimelineUnity.formatRulerMajor(f / fps, f),
					TextColor3 = Theme.color.textDim,
					TextXAlignment = Enum.TextXAlignment.Left,
					Font = Theme.font.main,
					TextSize = 11,
				})
			)
		end
		return kids
	end)
	return e("Frame")({
		BackgroundColor3 = Theme.color.panel,
		BorderSizePixel = 0,
		Active = false,
		ClipsDescendants = false,
		Size = UDim2.new(1, 0, 0, Theme.size.rulerHeight),
		[Children] = (function()
			local playheadHeadBtn
			playheadHeadBtn = e("TextButton")({
				Name = "PlayheadHandle",
				AnchorPoint = Vector2.new(0.5, 1),
				Position = Computed(function()
					local dur = math.max(state.duration:get(), 1e-3)
					return UDim2.fromScale(state.currentTime:get() / dur, 1)
				end),
				Size = UDim2.fromOffset(
					Theme.size.playheadHandleWidth,
					Theme.size.rulerHeight + Theme.size.playheadHandleExtendUp
				),
				BackgroundTransparency = 1,
				ClipsDescendants = false,
				Text = "",
				AutoButtonColor = false,
				ZIndex = 50,
				[OnEvent("MouseEnter")] = function()
					playheadHandleHover:set(true)
				end,
				[OnEvent("MouseLeave")] = function()
					playheadHandleHover:set(false)
				end,
				[OnEvent("InputBegan")] = function(input: InputObject)
					if input.UserInputType == Enum.UserInputType.MouseButton1 then
						beginScrub(gui, state, area(), nil, true, playheadHeadBtn, input)
					end
				end,
				[Children] = e("TextLabel")({
					Name = "PlayheadTriangle",
					AnchorPoint = Vector2.new(0.5, 1),
					Position = UDim2.fromScale(0.5, 1),
					Size = UDim2.fromOffset(
						Theme.size.playheadTriangleWidth,
						Theme.size.playheadTriangleHeight
					),
					BackgroundTransparency = 1,
					Text = "▼",
					TextSize = 13,
					TextColor3 = Computed(function()
						return if playheadHandleHover:get()
							then Color3.fromRGB(255, 120, 120)
							else Theme.color.playhead
					end),
					Font = Theme.font.bold,
					TextYAlignment = Enum.TextYAlignment.Bottom,
					ZIndex = 51,
				}),
			}) :: any
			return {
				e("TextButton")({
					Name = "RulerScrubHit",
					BackgroundTransparency = 1,
					Size = UDim2.fromScale(1, 1),
					Text = "",
					AutoButtonColor = false,
					ZIndex = 1,
					[OnEvent("InputBegan")] = function(input: InputObject)
						if input.UserInputType == Enum.UserInputType.MouseButton1 then
							local m = gui:GetRelativeMousePosition()
							if not mouseInTimelineRuler(area(), m) then
								return
							end
							local src = if input.Target and input.Target:IsA("GuiObject")
								then input.Target :: GuiObject
								else nil
							beginScrub(gui, state, area(), nil, false, src, input)
						end
					end,
				}),
				ticks,
				e("TextLabel")({
					BackgroundTransparency = 1,
					AnchorPoint = Vector2.new(1, 0),
					Position = UDim2.fromScale(1, 0),
					Size = UDim2.fromOffset(72, 1),
					Text = "长按拖动",
					TextColor3 = Theme.color.textDim,
					TextXAlignment = Enum.TextXAlignment.Right,
					Font = Theme.font.main,
					TextSize = 10,
					TextTransparency = 0.35,
					ZIndex = 2,
				}),
				e("TextLabel")({
					Name = "PlayheadScrubTooltip",
					AnchorPoint = Vector2.new(0.5, 1),
					Position = Computed(function()
						local dur = math.max(state.duration:get(), 1e-3)
						return UDim2.new(state.currentTime:get() / dur, 0, 0, -2)
					end),
					Size = UDim2.fromOffset(96, 18),
					BackgroundColor3 = Theme.color.panelAlt,
					BackgroundTransparency = 0.08,
					Visible = Computed(function()
						return playheadScrubbing:get()
					end),
					Text = Computed(function()
						local t = state.currentTime:get()
						local fps = state.fps:get()
						return TimelineUnity.formatRulerMajor(t, math.round(t * fps))
					end),
					TextColor3 = Theme.color.text,
					Font = Theme.font.bold,
					TextSize = 11,
					ZIndex = 51,
					[Children] = {
						e("UICorner")({ CornerRadius = UDim.new(0, 3) }),
						e("UIPadding")({
							PaddingLeft = UDim.new(0, 6),
							PaddingRight = UDim.new(0, 6),
						}),
					},
				}),
				playheadHeadBtn,
			}
		end)(),
	})
end

--========================= 分组折叠 =========================--

type DisplayRow = { kind: string, track: CutsceneFormat.Track?, group: string? }

-- 把扁平 tracks 折成"分组表头 + 可见轨道行"的显示序列。
-- 无 group 的轨道直接平铺(无表头);有 group 的按首次出现顺序成组,折叠时藏起子轨。
local function buildDisplayRows(
	tracks: { CutsceneFormat.Track },
	collapsed: { [string]: boolean }
): { DisplayRow }
	local order: { string } = {}
	local byGroup: { [string]: { CutsceneFormat.Track } } = {}
	for _, tr in tracks do
		local g = tr.group or ""
		if not byGroup[g] then
			byGroup[g] = {}
			table.insert(order, g)
		end
		table.insert(byGroup[g], tr)
	end
	local out: { DisplayRow } = {}
	for _, g in order do
		if g ~= "" then
			table.insert(out, { kind = "header", group = g })
			if not collapsed[g] then
				for _, tr in byGroup[g] do
					table.insert(out, { kind = "track", track = tr, group = g })
				end
			end
		else
			for _, tr in byGroup[g] do
				table.insert(out, { kind = "track", track = tr })
			end
		end
	end
	return out
end

local function toggleCollapse(collapsed: Fusion.Value<{ [string]: boolean }>, g: string)
	local c = table.clone(collapsed:get())
	c[g] = not c[g]
	collapsed:set(c)
end

--========================= 左轨道名列 =========================--

-- 相机 / cameraMove 轨行内控件:路径模式 + ⏺ 录制(仅 camera 显示录制)。
local function cameraRowControls(
	state: EditorState.EditorState,
	cb: Callbacks,
	track: CutsceneFormat.Track
): Instance
	if track.kind ~= "camera" and track.kind ~= "cameraMove" then
		return e("Frame")({ BackgroundTransparency = 1, Size = UDim2.fromScale(0, 1) })
	end
	local recording = cb.recordingCam:get() == track.target and track.kind == "camera"
	local bezier = track.pathMode == "bezier"
	local smooth = track.smooth == true and not bezier
	local pathLabel = if bezier then "⌇" elseif smooth then "◠" else "—"
	local pathAccent = bezier or smooth
	local children: { Instance } = {
		e("UIListLayout")({
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, 3),
			HorizontalAlignment = Enum.HorizontalAlignment.Right,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		e("TextButton")({
			LayoutOrder = 1,
			Size = UDim2.fromOffset(18, 18),
			BackgroundColor3 = if pathAccent then Theme.color.accent else Theme.color.panel,
			Text = pathLabel,
			TextColor3 = Theme.color.text,
			Font = Theme.font.bold,
			TextSize = 12,
			ZIndex = 3,
			[OnEvent("Activated")] = function()
				if bezier then
					state:setTrackPathMode(track, "linear")
				elseif smooth then
					state:setTrackPathMode(track, "bezier")
				else
					state:setTrackSmooth(track, true)
				end
			end,
			[Children] = e("UICorner")({ CornerRadius = UDim.new(0, 3) }),
		}),
	}
	if track.kind == "camera" then
		table.insert(
			children,
			e("TextButton")({
				LayoutOrder = 2,
				Size = UDim2.fromOffset(18, 18),
				BackgroundColor3 = if recording
					then Theme.color.danger
					else Color3.fromRGB(96, 48, 52),
				Text = "⏺",
				TextColor3 = Theme.color.text,
				TextSize = 11,
				ZIndex = 3,
				[OnEvent("Activated")] = function()
					cb.onCameraRecord(track)
				end,
				[Children] = e("UICorner")({ CornerRadius = UDim.new(0, 3) }),
			})
		)
	end
	return e("Frame")({
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, if track.kind == "camera" then -79 else -58, 0.5, 0),
		Size = UDim2.fromOffset(if track.kind == "camera" then 42 else 21, 18),
		ZIndex = 3,
		[Children] = children,
	})
end

-- 相机轨「跟随▾」:followBinding(与 vcam target 独立);右键清除。
local function applyExplorerInstance(
	inst: Instance,
	onBind: (binding: string, followPart: string?) -> ()
): boolean
	local binding, followPart = BindingFromInstance.resolve(inst)
	if not binding then
		warn("[anima] 无法绑定:请选择 Workspace 下的 Model / Part / Attachment")
		return false
	end
	onBind(binding, followPart)
	local partHint = if followPart and followPart ~= "" then ` · {followPart}` else ""
	print(`[anima] 已绑定 → {binding}{partHint}`)
	return true
end

-- Explorer 拖放槽(PluginDragDropped) + 点击用当前选中 / 点选模式。
local function explorerBindSlot(
	gui: PluginGui,
	layoutOrder: number,
	onBind: (string, string?) -> ()
): Instance
	local zone
	zone = e("TextButton")({
		LayoutOrder = layoutOrder,
		Size = UDim2.fromOffset(20, 18),
		BackgroundColor3 = Theme.color.panel,
		Text = "⎕",
		TextColor3 = Theme.color.textDim,
		Font = Theme.font.main,
		TextSize = 11,
		ZIndex = 4,
		AutoButtonColor = true,
		[OnEvent("Activated")] = function()
			local sel = Selection:Get()
			if #sel == 1 then
				applyExplorerInstance(sel[1], onBind)
			else
				BindingDrop.bindFromSelectionOrPick(gui, function(inst)
					applyExplorerInstance(inst, onBind)
				end)
			end
		end,
		[Children] = e("UICorner")({ CornerRadius = UDim.new(0, 3) }),
	})
	BindingDrop.register(zone, function(inst)
		applyExplorerInstance(inst, onBind)
	end)
	return zone
end

local function cameraFollowChip(
	gui: PluginGui,
	state: EditorState.EditorState,
	cb: Callbacks,
	track: CutsceneFormat.Track
): Instance
	if track.kind ~= "camera" then
		return e("Frame")({ BackgroundTransparency = 1, Size = UDim2.fromScale(0, 1) })
	end
	local label = if track.followBinding and track.followBinding ~= ""
		then "跟随·" .. track.followBinding
		else "跟随▾"
	local function bindFollow(binding: string, followPart: string?)
		state:setCameraFollow(track, binding, followPart or "HumanoidRootPart")
	end
	return e("Frame")({
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -4, 0.5, 0),
		Size = UDim2.fromOffset(96, 18),
		BackgroundTransparency = 1,
		ZIndex = 3,
		[Children] = {
			e("UIListLayout")({
				FillDirection = Enum.FillDirection.Horizontal,
				Padding = UDim.new(0, 3),
				HorizontalAlignment = Enum.HorizontalAlignment.Right,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			e("TextButton")({
				LayoutOrder = 1,
				Size = UDim2.fromOffset(72, 18),
				BackgroundColor3 = Theme.color.binding,
				Text = label,
				TextColor3 = Theme.color.textDim,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Font = Theme.font.main,
				TextSize = 11,
				ZIndex = 3,
				[OnEvent("Activated")] = function()
					pickTarget(gui, "跟随角色", cb.characterCandidates(), function(tgt)
						state:setCameraFollow(track, tgt, "HumanoidRootPart")
					end)
				end,
				[OnEvent("MouseButton2Click")] = function()
					ContextMenu.show(gui, {
						{ kind = "header", text = "相机跟随" },
						{
							text = "绑定 Explorer 选中…",
							onClick = function()
								BindingDrop.bindFromSelectionOrPick(gui, function(inst)
									applyExplorerInstance(inst, bindFollow)
								end)
							end,
						},
						{
							text = "清除跟随",
							onClick = function()
								state:setCameraFollow(track, nil, nil)
							end,
						},
					})
				end,
				[Children] = e("UICorner")({ CornerRadius = UDim.new(0, 3) }),
			}),
			explorerBindSlot(gui, 2, bindFollow),
		},
	})
end

-- 轨道行右侧的绑定芯片(Timeline 的 binding 槽):常驻显示 target,点击换绑。
-- cameraMove 的 target 是 vcam 名;camera 轨用 cameraFollowChip。
local function bindingChip(
	gui: PluginGui,
	state: EditorState.EditorState,
	cb: Callbacks,
	track: CutsceneFormat.Track
): Instance
	if track.kind == "camera" or track.kind == "cameraMove" then
		return e("Frame")({ BackgroundTransparency = 1, Size = UDim2.fromScale(0, 1) })
	end
	local function bindTarget(binding: string, _followPart: string?)
		state:setTrackTarget(track, binding)
	end
	return e("Frame")({
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -4, 0.5, 0),
		Size = UDim2.fromOffset(96, 18),
		BackgroundTransparency = 1,
		ZIndex = 3,
		[Children] = {
			e("UIListLayout")({
				FillDirection = Enum.FillDirection.Horizontal,
				Padding = UDim.new(0, 3),
				HorizontalAlignment = Enum.HorizontalAlignment.Right,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			e("TextButton")({
				LayoutOrder = 1,
				Size = UDim2.fromOffset(72, 18),
				BackgroundColor3 = Theme.color.binding,
				Text = track.target,
				TextColor3 = Theme.color.textDim,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Font = Theme.font.main,
				TextSize = 11,
				ZIndex = 3,
				[OnEvent("Activated")] = function()
					local cands = if track.kind == "animation"
						then cb.characterCandidates()
						else cb.targetCandidates()
					pickTarget(gui, "绑定到", cands, function(tgt)
						state:setTrackTarget(track, tgt)
					end)
				end,
				[Children] = e("UICorner")({ CornerRadius = UDim.new(0, 3) }),
			}),
			explorerBindSlot(gui, 2, bindTarget),
		},
	})
end

-- 左列:分组表头行(折叠箭头 + 组名 + ＋子轨;右键改名/删组)。
local function labelHeaderRow(
	gui: PluginGui,
	state: EditorState.EditorState,
	cb: Callbacks,
	collapsed: Fusion.Value<{ [string]: boolean }>,
	group: string,
	index: number
): Instance
	local isCollapsed = collapsed:get()[group] == true
	return rowFrame(
		index,
		Theme.color.panelAlt,
		e("Frame")({
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			[Children] = {
				e("UIPadding")({ PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4) }),
				e("TextButton")({
					BackgroundTransparency = 1,
					Size = UDim2.new(1, -22, 1, 0),
					Text = (if isCollapsed then "▸ " else "▾ ") .. "轨道组 · " .. group,
					TextColor3 = Theme.color.text,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextTruncate = Enum.TextTruncate.AtEnd,
					Font = Theme.font.bold,
					TextSize = 12,
					[OnEvent("Activated")] = function()
						toggleCollapse(collapsed, group)
					end,
					[OnEvent("MouseButton2Click")] = function()
						ContextMenu.show(gui, {
							{ kind = "header", text = "分组 " .. group },
							{
								text = "改名…",
								onClick = function()
									InputPrompt.show(gui, {
										title = "分组改名",
										default = group,
										onSubmit = function(txt)
											if txt ~= "" then
												state:renameGroup(group, txt)
											end
										end,
									})
								end,
							},
							{ kind = "sep" },
							{
								text = "删除整组",
								color = Theme.color.danger,
								onClick = function()
									state:removeGroup(group)
								end,
							},
						})
					end,
				}),
				e("TextButton")({ -- ＋ 子轨
					AnchorPoint = Vector2.new(1, 0.5),
					Position = UDim2.fromScale(1, 0.5),
					Size = UDim2.fromOffset(18, 18),
					BackgroundColor3 = Theme.color.panel,
					Text = "＋",
					TextColor3 = Theme.color.text,
					Font = Theme.font.bold,
					TextSize = 14,
					[OnEvent("Activated")] = function()
						local items: { ContextMenu.Item } =
							{ { kind = "header", text = "加子轨到 " .. group } }
						table.insert(items, {
							text = CAMERA_CREATE_HINT,
							onClick = function()
								print(
									"[anima] 请使用顶栏「＋ 相机」创建虚拟相机与独立相机轨"
								)
							end,
						})
						-- 动画/变换子轨先选绑定目标再建轨(Timeline 式)
						table.insert(items, {
							text = "动画子轨 → 选角色…",
							onClick = function()
								pickTarget(
									gui,
									"绑定角色(骨骼)",
									cb.characterCandidates(),
									function(tgt)
										state:addTrack("animation", tgt, "动画子轨", group)
									end
								)
							end,
						})
						table.insert(items, {
							text = "变换子轨 → 选目标…",
							onClick = function()
								pickTarget(gui, "绑定目标", cb.targetCandidates(), function(tgt)
									state:addTrack("transform", tgt, "变换子轨", group)
								end)
							end,
						})
						table.insert(items, {
							text = "事件子轨",
							onClick = function()
								state:addTrack("event", group, "事件子轨", group)
							end,
						})
						ContextMenu.show(gui, items)
					end,
					[Children] = e("UICorner")({ CornerRadius = UDim.new(0, 3) }),
				}),
			},
		})
	)
end

local function labelColumn(
	gui: PluginGui,
	state: EditorState.EditorState,
	cb: Callbacks,
	collapsed: Fusion.Value<{ [string]: boolean }>,
	vScroll: Fusion.Value<number>
): Instance
	local headerBar = e("Frame")({ -- 表头 + 加轨道(固定,不随垂直滚动;23 spec)
		BackgroundColor3 = Theme.color.panel,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, Theme.size.rulerHeight),
		ZIndex = 8,
		[Children] = (function()
			local addTrackBtn
			addTrackBtn = e("TextButton")({
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -4, 0.5, 0),
				Size = UDim2.fromOffset(58, 20),
				BackgroundColor3 = Theme.color.accent,
				Text = "+ 轨道",
				TextColor3 = Color3.new(1, 1, 1),
				Font = Theme.font.bold,
				TextSize = 11,
				ZIndex = 12,
				[OnEvent("Activated")] = function()
					local gOrigin = gui.AbsolutePosition
					local ap = addTrackBtn.AbsolutePosition
					local asz = addTrackBtn.AbsoluteSize
					showAddTrackMenu(gui, state, cb, {
						position = Vector2.new(
							ap.X - gOrigin.X + asz.X,
							ap.Y - gOrigin.Y + asz.Y + 2
						),
						width = 228,
						anchor = Vector2.new(1, 0),
						minX = 8,
					})
				end,
				[Children] = e("UICorner")({ CornerRadius = UDim.new(0, 3) }),
			}) :: any
			return {
				e("UIPadding")({ PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 4) }),
				e("TextLabel")({
					BackgroundTransparency = 1,
					Size = UDim2.new(1, -66, 1, 0),
					Text = "轨道名称",
					TextColor3 = Theme.color.textDim,
					TextXAlignment = Enum.TextXAlignment.Left,
					Font = Theme.font.bold,
					TextSize = 11,
				}),
				e("TextLabel")({
					BackgroundTransparency = 1,
					AnchorPoint = Vector2.new(1, 0.5),
					Position = UDim2.new(1, -66, 0.5, 0),
					Size = UDim2.fromOffset(40, 14),
					Text = "绑定",
					TextColor3 = Theme.color.textDim,
					TextXAlignment = Enum.TextXAlignment.Right,
					Font = Theme.font.main,
					TextSize = 10,
				}),
				addTrackBtn,
			}
		end)(),
	})
	local rows = Computed(function()
		state.revision:get()
		local tracks = state.tracks:get()
		local kids: { Instance } = {}
		for i, row in buildDisplayRows(tracks, collapsed:get()) do
			if row.kind == "header" then
				table.insert(kids, labelHeaderRow(gui, state, cb, collapsed, row.group, i))
			else
				local track = row.track
				local index = i
				local bg = Theme.color.trackHeader
				local rightInset = if track.kind == "camera"
					then 120
					elseif track.kind == "cameraMove" then 44
					else 108
				local title = (if track.hidden then "🙈 " else "")
					.. TimelineUnity.trackTitle(track)
				local subtitle = TimelineUnity.trackBindingLine(track)
				local trackIndex = table.find(tracks, track)
				local selectedStroke = Computed(function()
					return if state.selectedTrack:get() == trackIndex then 0 else 1
				end)
				table.insert(
					kids,
					rowFrame(
						index,
						bg,
						e("TextButton")({
							BackgroundTransparency = 1,
							Text = "",
							Size = UDim2.fromScale(1, 1),
							[OnEvent("InputBegan")] = function(input: InputObject)
								if input.UserInputType == Enum.UserInputType.MouseButton1 then
									state.selectedTrack:set(trackIndex)
								end
							end,
							[OnEvent("MouseButton2Click")] = function()
								showTrackMenu(gui, state, cb, track)
							end,
							[Children] = {
								e("TextLabel")({
									BackgroundColor3 = Theme.trackColor(track.kind),
									Position = UDim2.fromOffset(6, 6),
									Size = UDim2.fromOffset(18, 18),
									Text = TimelineUnity.trackBadge(track.kind),
									TextColor3 = Theme.color.text,
									TextXAlignment = Enum.TextXAlignment.Center,
									TextYAlignment = Enum.TextYAlignment.Center,
									Font = Theme.font.bold,
									TextSize = 11,
									[Children] = e("UICorner")({ CornerRadius = UDim.new(0, 3) }),
								}),
								e("Frame")({
									BackgroundTransparency = 1,
									Position = UDim2.fromOffset(30, 0),
									Size = UDim2.new(1, -rightInset, 1, 0),
									[Children] = {
										e("TextButton")({
											BackgroundTransparency = 1,
											Position = UDim2.fromOffset(0, 2),
											Size = UDim2.new(1, 0, 0, 18),
											Text = title,
											TextColor3 = Theme.color.text,
											TextXAlignment = Enum.TextXAlignment.Left,
											TextTruncate = Enum.TextTruncate.AtEnd,
											Font = Theme.font.bold,
											TextSize = 12,
											ZIndex = 2,
											[OnEvent("Activated")] = function()
												onTrackTitleClick(gui, state, track, trackIndex)
											end,
										}),
										e("TextLabel")({
											BackgroundTransparency = 1,
											Position = UDim2.fromOffset(0, 20),
											Size = UDim2.new(1, 0, 0, 14),
											Text = subtitle,
											TextColor3 = Theme.color.textDim,
											TextXAlignment = Enum.TextXAlignment.Left,
											TextTruncate = Enum.TextTruncate.AtEnd,
											Font = Theme.font.main,
											TextSize = 10,
										}),
									},
								}),
								e("UIStroke")({
									Color = Theme.color.selection,
									Thickness = 1,
									Transparency = selectedStroke,
								}),
								cameraRowControls(state, cb, track),
								cameraFollowChip(gui, state, cb, track),
								bindingChip(gui, state, cb, track),
							},
						}),
						`l_${index}_${track.kind}_${track.target}`
					)
				)
			end
		end
		return kids
	end)
	local offsetHolder = e("Frame")({
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Position = Computed(function()
			return UDim2.fromOffset(0, -vScroll:get())
		end),
		[Children] = rows,
	})

	return e("Frame")({
		BackgroundColor3 = Theme.color.panelAlt,
		BorderSizePixel = 0,
		Active = true,
		ClipsDescendants = true,
		Size = UDim2.new(0, Theme.size.labelWidth, 1, 0),
		-- 轨道行/分组行的按钮会吃掉自己的右键;落到这里的都是空白处 → 新增轨道
		[OnEvent("InputBegan")] = function(input: InputObject)
			if input.UserInputType ~= Enum.UserInputType.MouseButton2 then
				return
			end
			task.defer(function()
				if not ContextMenu.justShown() then
					showAddTrackMenu(gui, state, cb)
				end
			end)
		end,
		-- 左名列平滚轮 = 垂直滚动(时间轴侧滚轮=缩放,Shift+滚轮=垂直)
		[OnEvent("InputChanged")] = function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseWheel then
				local step = Theme.size.trackHeight * 2
				vScroll:set(
					math.max(0, vScroll:get() + (if input.Position.Z > 0 then -step else step))
				)
			end
		end,
		[Children] = { offsetHolder, headerBar },
	})
end

--========================= 右时间轴 =========================--

local function timeline(
	gui: PluginGui,
	state: EditorState.EditorState,
	cb: Callbacks,
	collapsed: Fusion.Value<{ [string]: boolean }>,
	vScroll: Fusion.Value<number>
): Instance
	-- contentArea 兼作"时间轴坐标 area",宽度 = zoom × 视口宽(套在横向 ScrollingFrame 里滚动)。
	-- 关键帧/镜头/播放头作为其子级,按占时长比例定位,随缩放/滚动一起走。
	local zoom = Fusion.Value(1) -- 横向缩放倍数(1 = 铺满视口)
	local MIN_ZOOM, MAX_ZOOM = 1, 20
	local viewportWidth = Fusion.Value(1)
	local viewportHeight = Fusion.Value(1)
	local areaWidth = Fusion.Value(0) -- contentArea 实际像素宽,驱动网格刻度自适应
	local contentArea
	local scroller
	local function area(): GuiObject
		return contentArea
	end

	local canvasWidthPx = Computed(function()
		local vw = math.max(viewportWidth:get(), 1)
		return math.max(math.ceil(vw * zoom:get()), vw)
	end)

	-- 垂直滚动钳制(23 spec):maxV = 标尺高 + 行数×行高 - 视口高
	local displayRowCount = Computed(function()
		state.revision:get()
		return #buildDisplayRows(state.tracks:get(), collapsed:get())
	end)
	local function clampVScroll()
		local maxV = math.max(
			0,
			Theme.size.rulerHeight
				+ displayRowCount:get() * Theme.size.trackHeight
				- math.max(viewportHeight:get(), 1)
		)
		local v = vScroll:get()
		local c = math.clamp(v, 0, maxV)
		if c ~= v then
			vScroll:set(c)
		end
	end
	Fusion.Observer(vScroll):onChange(clampVScroll)
	Fusion.Observer(displayRowCount):onChange(function()
		task.defer(clampVScroll)
	end)

	local function maxCanvasScrollX(): number
		local vw = math.max(scroller.AbsoluteSize.X, 1)
		local cw = math.max(math.ceil(vw * zoom:get()), vw)
		return math.max(0, cw - vw)
	end

	local function clampCanvasScroll()
		local maxX = maxCanvasScrollX()
		local cp = scroller.CanvasPosition
		scroller.CanvasPosition = Vector2.new(math.clamp(cp.X, 0, maxX), 0)
	end

	-- 缩放并保持锚点处的时间不动。anchorX 是相对 gui 的鼠标 X(滚轮缩放传入);
	-- 不传则以视口中心为锚(± 按钮)。CanvasSize 异步更新,defer 后再写 CanvasPosition 并夹紧。
	local function zoomAt(factor: number, anchorX: number?)
		local old = zoom:get()
		local new = math.clamp(old * factor, MIN_ZOOM, MAX_ZOOM)
		if new == old then
			return
		end
		local viewportW = math.max(scroller.AbsoluteSize.X, 1)
		local anchor = if anchorX
			then math.clamp(anchorX - scroller.AbsolutePosition.X, 0, viewportW)
			else viewportW / 2
		local target = (scroller.CanvasPosition.X + anchor) * (new / old) - anchor
		zoom:set(new)
		task.defer(function()
			local maxX = maxCanvasScrollX()
			scroller.CanvasPosition = Vector2.new(math.clamp(target, 0, maxX), 0)
		end)
	end

	local rows = Computed(function()
		state.revision:get()
		local tracks = state.tracks:get()
		local kids: { Instance } = {}
		for i, row in buildDisplayRows(tracks, collapsed:get()) do
			if row.kind == "header" then
				table.insert(
					kids,
					rowFrame(
						i,
						Theme.color.panelAlt,
						e("Frame")({ BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) })
					)
				)
			else
				local track = row.track
				local index = i
				local bg = Theme.color.trackHeader
				table.insert(
					kids,
					rowFrame(
						index,
						bg,
						trackContent(gui, state, cb, area, track),
						`t_${index}_${track.kind}_${track.target}`
					)
				)
			end
		end
		return kids
	end)

	local playhead = e("Frame")({
		BackgroundColor3 = Theme.color.playhead,
		BorderSizePixel = 0,
		Active = false,
		ZIndex = 9,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = Computed(function()
			local dur = math.max(state.duration:get(), 1e-3)
			return UDim2.new(state.currentTime:get() / dur, 0, 0, Theme.size.rulerHeight)
		end),
		Size = UDim2.new(0, Theme.size.playheadLineWidth, 1, -Theme.size.rulerHeight),
	})

	-- rows(Computed)单独包一层 Frame(经过验证的 [Children]=Computed 模式),
	-- 再与 playhead 作为 contentArea 的两个普通子级,避免把 Computed 直接嵌进数组。
	local rowsHolder = e("Frame")({
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Position = Computed(function()
			return UDim2.fromOffset(0, -vScroll:get())
		end),
		[Children] = rows,
	})
	-- 标尺固定在顶部,不透明底罩住滚上来的行(23 spec)
	local rulerHolder = e("Frame")({
		BackgroundColor3 = Theme.color.panel,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, Theme.size.rulerHeight),
		ZIndex = 20,
		[Children] = ruler(gui, state, area, areaWidth),
	})
	-- 竖向网格线:主刻度延伸到轨道区,随缩放自适应(和 ruler 用同一套步长)。
	local gridLines = Computed(function()
		local dur = math.max(state.duration:get(), 1e-3)
		local fps = math.max(state.fps:get(), 1)
		local w = areaWidth:get()
		local kids: { Instance } = {}
		if w < 2 then
			return kids
		end
		local totalFrames = dur * fps
		local major = gridSteps(fps, totalFrames, w)
		for f = 0, totalFrames, major do
			table.insert(
				kids,
				e("Frame")({
					BackgroundColor3 = Theme.color.line,
					BackgroundTransparency = 0.6,
					BorderSizePixel = 0,
					Position = UDim2.new(f / totalFrames, 0, 0, Theme.size.rulerHeight),
					Size = UDim2.new(0, 1, 1, -Theme.size.rulerHeight),
				})
			)
		end
		return kids
	end)
	local gridHolder = e("Frame")({
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,
		[Children] = gridLines,
	})

	contentArea = e("Frame")({
		BackgroundTransparency = 1,
		Active = true,
		Size = Computed(function()
			return UDim2.new(0, canvasWidthPx:get(), 1, 0)
		end),
		-- 轨道行(trackContent)自己接右键;落到这里的是无轨道的空白 → 新增轨道。
		-- 标尺区(顶部)不弹。
		[OnEvent("InputBegan")] = function(input: InputObject)
			if input.UserInputType ~= Enum.UserInputType.MouseButton2 then
				return
			end
			local relY = gui:GetRelativeMousePosition().Y - contentArea.AbsolutePosition.Y
			if relY < Theme.size.rulerHeight then
				return
			end
			task.defer(function()
				if not ContextMenu.justShown() then
					showAddTrackMenu(gui, state, cb)
				end
			end)
		end,
		[Children] = { rowsHolder, gridHolder, playhead, rulerHolder },
	})
	scroller = e("ScrollingFrame")({
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		CanvasSize = Computed(function()
			return UDim2.fromOffset(canvasWidthPx:get(), math.max(viewportHeight:get(), 1))
		end),
		ScrollingDirection = Enum.ScrollingDirection.X,
		ElasticBehavior = Enum.ElasticBehavior.Never,
		ScrollBarThickness = 8,
		ScrollBarImageColor3 = Theme.color.accent,
		ScrollBarImageTransparency = 0.4,
		TopImage = "",
		BottomImage = "",
		ClipsDescendants = true,
		-- 时间轴区域内(刻度尺/轨道/空白)滚轮 = 以鼠标位置为锚点缩放。
		-- 挂在 scroller 上一处搞定:指针落在任何子级内时它同样收到 InputChanged。
		[OnEvent("InputChanged")] = function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseWheel then
				if modifierShiftDown() then
					local step = Theme.size.trackHeight * 2
					vScroll:set(
						math.max(0, vScroll:get() + (if input.Position.Z > 0 then -step else step))
					)
					return
				end
				local factor = if input.Position.Z > 0 then 1.25 else 1 / 1.25
				zoomAt(factor, gui:GetRelativeMousePosition().X)
			end
		end,
		[Children] = contentArea,
	})

	local function syncTimelineViewport()
		viewportWidth:set(math.max(scroller.AbsoluteSize.X, 1))
		viewportHeight:set(math.max(scroller.AbsoluteSize.Y, 1))
		if contentArea then
			areaWidth:set(contentArea.AbsoluteSize.X)
		end
		task.defer(clampCanvasScroll)
		task.defer(clampVScroll)
	end
	scroller:GetPropertyChangedSignal("AbsoluteSize"):Connect(syncTimelineViewport)
	contentArea:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		areaWidth:set(contentArea.AbsoluteSize.X)
		task.defer(clampCanvasScroll)
	end)
	task.defer(syncTimelineViewport)

	-- 右下角缩放控件(固定,不随内容滚动)。
	local function zoomBtn(order: number, txt: string, onClick: () -> ()): Instance
		return e("TextButton")({
			LayoutOrder = order,
			Size = UDim2.fromOffset(22, 20),
			BackgroundColor3 = Theme.color.panelAlt,
			BackgroundTransparency = 0.1,
			Text = txt,
			TextColor3 = Theme.color.text,
			Font = Theme.font.bold,
			TextSize = 14,
			AutoButtonColor = true,
			ZIndex = 30,
			[OnEvent("Activated")] = onClick,
			[Children] = e("UICorner")({ CornerRadius = UDim.new(0, 3) }),
		})
	end
	local zoomControls = e("Frame")({
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -12, 1, -12),
		Size = UDim2.fromOffset(74, 20),
		ZIndex = 30,
		[Children] = {
			e("UIListLayout")({
				FillDirection = Enum.FillDirection.Horizontal,
				Padding = UDim.new(0, 3),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			zoomBtn(1, "－", function()
				zoomAt(1 / 1.5)
			end),
			zoomBtn(2, "⤢", function()
				zoom:set(1)
				scroller.CanvasPosition = Vector2.new(0, 0)
			end),
			zoomBtn(3, "＋", function()
				zoomAt(1.5)
			end),
		},
	})

	return e("Frame")({
		BackgroundColor3 = Theme.color.bg,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -Theme.size.labelWidth, 1, 0),
		Position = UDim2.fromOffset(Theme.size.labelWidth, 0),
		ClipsDescendants = true,
		[Children] = {
			scroller,
			zoomControls,
		},
	})
end

--========================= 挂载 =========================--

function App.mount(
	gui: PluginGui,
	state: EditorState.EditorState,
	cb: Callbacks
): (Instance, () -> ())
	BindingDrop.install(gui)
	local previewCollapsed = Fusion.Value(false)
	local previewHeight = Fusion.Value(220) -- 内嵌预览高度(可拖分隔条调)
	local collapsed: Fusion.Value<{ [string]: boolean }> = Fusion.Value({})

	-- 各区块 y 偏移(预览折叠时高度归零)
	local function previewH(): number
		return if previewCollapsed:get() then 0 else previewHeight:get()
	end

	local previewContainer = e("Frame")({
		Name = "PreviewContainer",
		BackgroundColor3 = Color3.fromRGB(10, 11, 13),
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, Theme.size.topbar),
		Size = Computed(function()
			return UDim2.new(1, 0, 0, previewH())
		end),
		ClipsDescendants = true,
		[Children] = e("TextButton")({ -- 底边拖拽分隔条:调预览高度
			Name = "PreviewResize",
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.fromScale(0.5, 1),
			Size = UDim2.new(1, 0, 0, 6),
			BackgroundColor3 = Theme.color.accent,
			BackgroundTransparency = 0.55,
			Text = "⋯⋯⋯",
			TextColor3 = Theme.color.text,
			TextSize = 9,
			AutoButtonColor = true,
			ZIndex = 20,
			[OnEvent("InputBegan")] = function(input: InputObject)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					local resizeBar = input.Parent
					beginTimelineDrag(gui, {
						onMove = function(mouse)
							previewHeight:set(math.clamp(mouse.Y - Theme.size.topbar, 90, 480))
						end,
					}, if resizeBar and resizeBar:IsA("GuiObject") then resizeBar else nil, input)
				end
			end,
		}),
	})

	local vcamWrap = e("Frame")({
		Name = "VcamBar",
		BackgroundTransparency = 1,
		Position = Computed(function()
			return UDim2.fromOffset(0, Theme.size.topbar + previewH())
		end),
		Size = UDim2.new(1, 0, 0, Theme.size.vcamBar),
		[Children] = vcamBar(gui, state, cb),
	})

	-- 轨道区垂直滚动偏移(左名列与时间轴共享;23 spec)
	local vScroll = Fusion.Value(0)

	local body = e("Frame")({
		Name = "Body",
		BackgroundColor3 = Theme.color.bg,
		BorderSizePixel = 0,
		Position = Computed(function()
			return UDim2.fromOffset(0, Theme.size.topbar + previewH() + Theme.size.vcamBar)
		end),
		Size = Computed(function()
			return UDim2.new(1, 0, 1, -(Theme.size.topbar + previewH() + Theme.size.vcamBar))
		end),
		[Children] = {
			labelColumn(gui, state, cb, collapsed, vScroll),
			timeline(gui, state, cb, collapsed, vScroll),
		},
	})

	-- 视口对帧调整中的浮动提示条(醒目 + 一键结束)
	local adjustBadge = e("TextButton")({
		Name = "AdjustBadge",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, Theme.size.topbar + 6),
		Size = UDim2.fromOffset(300, 24),
		BackgroundColor3 = Theme.color.danger,
		Visible = Computed(function()
			return cb.adjustingKf:get() ~= nil
		end),
		Text = "🎥 视口对帧调整中:自由取景实时写回 — 点此结束",
		TextColor3 = Theme.color.text,
		Font = Theme.font.bold,
		TextSize = 12,
		AutoButtonColor = true,
		ZIndex = 50,
		[OnEvent("Activated")] = cb.onStopAdjust,
		[Children] = e("UICorner")({ CornerRadius = UDim.new(0, 4) }),
	})

	local authoringBadge = e("TextLabel")({
		Name = "AuthoringBadge",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, Theme.size.topbar + 6),
		Size = UDim2.fromOffset(360, 22),
		BackgroundColor3 = Theme.color.track.camera,
		BackgroundTransparency = 0.15,
		Visible = Computed(function()
			return cb.authoringMode:get() and cb.adjustingKf:get() == nil
		end),
		Text = "🎥 透视编辑:WASD 摆构图 · K 打帧 · 拖青/紫把手改 key · scrub 不改主视口",
		TextColor3 = Theme.color.text,
		Font = Theme.font.main,
		TextSize = 11,
		ZIndex = 49,
		[Children] = e("UICorner")({ CornerRadius = UDim.new(0, 4) }),
	})

	local root = e("Frame")({
		Name = "AnimaTimeline",
		BackgroundColor3 = Theme.color.bg,
		Size = UDim2.fromScale(1, 1),
		BorderSizePixel = 0,
		ZIndex = 1,
		[Children] = {
			topbar(gui, state, cb, previewCollapsed),
			previewContainer,
			vcamWrap,
			body,
			authoringBadge,
			adjustBadge,
		},
	})
	root.Parent = gui
	OverlayHost.ensure(gui)

	-- 让 init 把 PreviewViewport 挂进预览容器
	cb.mountPreview(previewContainer)

	local function cleanup()
		root:Destroy()
	end
	return root, cleanup
end

return App
