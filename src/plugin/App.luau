--!strict
-- App — Timeline 面板根组件(Fusion)。
-- 结构:顶部工具条 / 内嵌预览横条(可折叠) / vcam 管理条 / 左轨道名列 / 右时间轴。
--
-- 交互(时间轴内统一长按拖拽:按住 HOLD_SEC 后跟随;全程须按住左键,松开即放下;Alt=自由不吸附):
--   相机段块 / 端把手(3/5) — 拖头尾改 from/to、拖身体整体平移,点击选中该轨
--   关键帧/片段/事件(6) — 拖改时间,右键菜单
--   播放头(10) + 标尺(11) — 仅标尺行拖/长按 scrub;红线纯点击不跳
--   轨道空白 — 点击取消选中,不移动播放头
--   关键帧/片段/事件 — 点击不跳播放头(定位见右键菜单)
-- 时间轴内容套横向 ScrollingFrame,宽度=zoom×视口(右下角缩放按钮);时间按帧(fps)显示与吸附。
-- 数据编辑直接调 EditorState(含撤销栈);vcam / 相机等 DataModel 副作用走回调。

local UserInputService = game:GetService("UserInputService")

local Fusion = require(script.Parent.Packages.Fusion)
local Theme = require(script.Parent.Theme)
local EditorState = require(script.Parent.EditorState)
local DragController = require(script.Parent.DragController)
local ContextMenu = require(script.Parent.ContextMenu)
local InputPrompt = require(script.Parent.InputPrompt)
local CutsceneFormat = require(script.Parent.Shared.CutsceneFormat)
local VCam = require(script.Parent.Shared.VCam)
local TimelineUnity = require(script.Parent.TimelineUnity)

local New = Fusion.New
local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local Computed = Fusion.Computed

local SNAP_PX = 8 -- 吸附像素阈值
local HOLD_SEC = 0.1 -- 时间轴:按住满此时长后进入拖拽;拖动全程须保持按住,松开即放下

-- 正在拖动播放头(scrub)时为 true,供把手时间提示条显示
local playheadScrubbing = Fusion.Value(false)
local playheadHandleHover = Fusion.Value(false)

local function beginTimelineDrag(gui: PluginGui, handlers: DragController.Handlers, feedback: GuiObject?)
	handlers.holdTime = HOLD_SEC
	handlers.holdDrag = true
	handlers.feedbackElement = feedback
	if feedback and not handlers.pressSource then
		handlers.pressSource = feedback
	end
	DragController.begin(gui, handlers)
end

-- 轨道名双击重命名(两次点击间隔 < 0.35s)
local renameDbl: { track: CutsceneFormat.Track?, at: number } = { track = nil, at = 0 }

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
	onExport: () -> (),
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
	recordingCam: Fusion.Value<string?>, -- 正在录制的相机轨 target(nil=无)
	onAddCameraTrack: (group: string?) -> (),
	onCameraRecord: (track: CutsceneFormat.Track) -> (),
	targetCandidates: () -> { string },
	characterCandidates: () -> { string }, -- 动画轨用:带 Humanoid 骨骼的候选
	-- 视口对帧调整(相机类关键帧反向编辑)
	adjustingKf: Fusion.Value<CutsceneFormat.Keyframe?>, -- 正在调整的关键帧(nil=无)
	onAdjustKeyframe: (track: CutsceneFormat.Track, kf: CutsceneFormat.Keyframe) -> (), -- 开/关
	onStopAdjust: () -> (),
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

-- 收集单轨上的时间点(供拖拽吸附);默认不含其它轨道。
local function markTimesForTrack(
	track: CutsceneFormat.Track,
	skip: {
		keyframe: CutsceneFormat.Keyframe?,
		clip: CutsceneFormat.AnimationClip?,
		event: CutsceneFormat.CutsceneEvent?,
	}?
): { number }
	local out: { number } = {}
	if track.keyframes then
		for _, kf in track.keyframes do
			if not (skip and skip.keyframe == kf) then
				table.insert(out, kf.t)
			end
		end
	end
	if track.clips then
		for _, c in track.clips do
			if not (skip and skip.clip == c) then
				table.insert(out, c.startAt)
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
	if track.segments then
		for _, s in track.segments do
			table.insert(out, s.from)
			table.insert(out, s.to)
		end
	end
	return out
end

-- 标尺 / 播放头把手:长按后跟随 scrub;纯点击不跳时间(onClick 可选)。
-- grab=true 时记录按下点与播放头的时间差,拖动保持相对位置不跳(播放头把手用)。
local function beginScrub(
	gui: PluginGui,
	state: EditorState.EditorState,
	area: GuiObject,
	onClick: (() -> ())?,
	grab: boolean?,
	pressSource: GuiObject?
)
	local offset = 0
	if grab then
		local m = gui:GetRelativeMousePosition()
		offset = DragController.fracInArea(area, m) * state.duration:get() - state.currentTime:get()
	end
	beginTimelineDrag(
		gui,
		{
			onBegin = function()
				playheadScrubbing:set(true)
			end,
			onMove = function(mouse)
				local dur = state.duration:get()
				state:setTime(math.clamp(DragController.fracInArea(area, mouse) * dur - offset, 0, dur))
			end,
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
		},
		pressSource
	)
end

-- 先吸附本轨其它标记点,再量化到帧(1/fps);按住 Alt = 自由(不吸附/不量化)。
local function draggedTime(
	state: EditorState.EditorState,
	area: GuiObject,
	mouse: Vector2,
	offsetSec: number?,
	track: CutsceneFormat.Track,
	skip: {
		keyframe: CutsceneFormat.Keyframe?,
		clip: CutsceneFormat.AnimationClip?,
		event: CutsceneFormat.CutsceneEvent?,
	}?
): number
	local dur = state.duration:get()
	local t = math.clamp(DragController.fracInArea(area, mouse) * dur - (offsetSec or 0), 0, dur)
	local alt = UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt)
	local thr = SNAP_PX / math.max(area.AbsoluteSize.X, 1) * dur
	local snapped = DragController.snapTime(t, dur, markTimesForTrack(track, skip), thr, alt)
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
					placeholder = "如 sfx_door / vfx_dust",
					onSubmit = function(txt)
						if txt ~= "" then
							state:addEvent(track, txt, atTime)
						end
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
	elseif track.kind == "cameraMove" then
		table.insert(items, {
			text = "采集相机位姿打帧" .. suffix,
			onClick = function()
				cb.onCaptureCameraMove(track, atTime)
			end,
		})
	end
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
		text = "相机轨道",
		onClick = function()
			cb.onAddCameraTrack(nil)
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
	for _, vn in VCam.list() do
		table.insert(items, {
			text = "相机运动 → " .. vn,
			onClick = function()
				state:addTrack("cameraMove", vn, TimelineUnity.defaultTrackName("cameraMove"), nil)
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
		return string.format("帧 %d / %d", cur, total)
	end)
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
				Size = UDim2.new(0, 92, 1, 0),
				Text = timeLabel,
				TextColor3 = Theme.color.textDim,
				Font = Theme.font.main,
				TextSize = 13,
				AutoButtonColor = false,
				-- 点击改总时长(当前 / 总)
				[OnEvent("Activated")] = function()
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
			}),
			slot(3, 32, button("⏮", Theme.color.panel, cb.onToStart)),
			slot(5, 36, button("🔁", loopColor, cb.onToggleLoop)),
			slot(4, 40, button(playText, Theme.color.accent, cb.onPlayPause)),
			slot(4, 70, button(recText, recColor, cb.onToggleRecord)),
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
			slot(12, 60, button("💾 导出", Theme.color.track.animation, cb.onExport)),
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
				local grab = DragController.fracInArea(area(), gui:GetRelativeMousePosition())
						* state.duration:get()
					- kf.t
				beginTimelineDrag(gui, {
					onBegin = function()
						state:pushUndo()
					end,
					onMove = function(mouse)
						kf.t = draggedTime(state, area(), mouse, grab, track, { keyframe = kf })
						diamond.Position = UDim2.fromScale(kf.t / state.duration:get(), 0.5)
					end,
					onEnd = function()
						state:finishDrag()
					end,
				}, diamond)
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
				end
				table.insert(items, {
					text = "复制(+0.5s)",
					onClick = function()
						state:duplicateKeyframe(track, kf)
					end,
				})
				table.insert(items, { kind = "header", text = "缓动" })
				for _, ez in { "linear", "quadIn", "quadOut", "quadInOut", "cubicInOut", "sine" } do
					table.insert(items, {
						text = "  " .. ez,
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

-- 动画 Clip 条(对标 Unity Animation Track clip)。
local function clipBlock(
	gui: PluginGui,
	state: EditorState.EditorState,
	area: () -> GuiObject,
	track: CutsceneFormat.Track,
	clip: CutsceneFormat.AnimationClip,
	clipIndex: number,
	nextT: number
): Instance
	local dur = state.duration:get()
	local endT = math.min(nextT, math.max(clip.startAt + 1.5, clip.startAt))
	local w = math.max((endT - clip.startAt) / dur, 0.02)
	local primary = TimelineUnity.clipPrimaryTitle(track, clipIndex)
	local secondary = TimelineUnity.clipSecondaryLine(clip)
	local block
	block = e("TextButton")({
		BackgroundColor3 = Theme.color.track.animation,
		BackgroundTransparency = 0.12,
		Position = UDim2.new(clip.startAt / dur, 1, 0, 4),
		Size = UDim2.new(w, -2, 1, -8),
		Text = "",
		AutoButtonColor = true,
		ZIndex = 7,
		[OnEvent("InputBegan")] = function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				local grab = DragController.fracInArea(area(), gui:GetRelativeMousePosition())
						* state.duration:get()
					- clip.startAt
				beginTimelineDrag(gui, {
					onBegin = function()
						state:pushUndo()
					end,
					onMove = function(mouse)
						clip.startAt = draggedTime(state, area(), mouse, grab, track, { clip = clip })
						block.Position = UDim2.new(clip.startAt / state.duration:get(), 1, 0, 4)
					end,
					onEnd = function()
						state:finishDrag()
					end,
				}, block)
			elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
				ContextMenu.show(gui, {
					{ kind = "header", text = "Animation Clip" },
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
										clip.startAt = math.clamp(f / fps, 0, state.duration:get())
										state:finishDrag()
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
								placeholder = "rbxassetid://…",
								onSubmit = function(txt)
									if txt ~= "" then
										state:setClipField(clip, "animationId", txt)
									end
								end,
							})
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
						text = "删除片段",
						color = Theme.color.danger,
						onClick = function()
							state:removeClip(track, clip)
						end,
					},
				})
			end
		end,
		[Children] = {
			e("UICorner")({ CornerRadius = UDim.new(0, 3) }),
			e("Frame")({
				BackgroundColor3 = Theme.color.clipHeader,
				BackgroundTransparency = 0.35,
				BorderSizePixel = 0,
				Size = UDim2.new(0, 4, 1, 0),
			}),
			e("UIPadding")({ PaddingLeft = UDim.new(0, 8), PaddingTop = UDim.new(0, 2) }),
			e("TextLabel")({
				BackgroundTransparency = 1,
				Position = UDim2.fromOffset(8, 2),
				Size = UDim2.new(1, -10, 0, 14),
				Text = primary,
				TextColor3 = Theme.color.text,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Font = Theme.font.bold,
				TextSize = 11,
			}),
			e("TextLabel")({
				BackgroundTransparency = 1,
				Position = UDim2.fromOffset(8, 16),
				Size = UDim2.new(1, -10, 0, 12),
				Text = secondary,
				TextColor3 = Theme.color.textDim,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Font = Theme.font.main,
				TextSize = 9,
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
				local grab = DragController.fracInArea(area(), gui:GetRelativeMousePosition())
						* state.duration:get()
					- ev.t
				beginTimelineDrag(gui, {
					onBegin = function()
						state:pushUndo()
					end,
					onMove = function(mouse)
						ev.t = draggedTime(state, area(), mouse, grab, track, { event = ev })
						container.Position = UDim2.fromScale(ev.t / state.duration:get(), 0.5)
					end,
					onEnd = function()
						state:finishDrag()
					end,
				}, hitTarget)
			elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
				ContextMenu.show(gui, {
					{ kind = "header", text = "Marker · " .. ev.name },
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
					{ kind = "sep" },
					{
						text = "Delete Marker",
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
		Position = UDim2.new(0.5, 0, 0, 0),
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

-- 相机轨的一个生效段块(track.segments[segIndex]):长按拖动(两端 resize / 身体平移)、
-- 点击选中、右键(输入起止帧/加段/删段/删轨)。同一台相机可有多段,每段一个块。
local function segmentBlock(
	gui: PluginGui,
	state: EditorState.EditorState,
	area: () -> GuiObject,
	track: CutsceneFormat.Track,
	segIndex: number
): Instance
	local function seg(): CutsceneFormat.CameraSegment
		return track.segments[segIndex]
	end
	local block
	local function refresh()
		local d = state.duration:get()
		local s = seg()
		block.Position = UDim2.new(s.from / d, 1, 0, 4)
		block.Size = UDim2.new(math.max((s.to - s.from) / d, 0.005), -2, 1, -8)
		local fpsNow = state.fps:get()
		block.Text = TimelineUnity.cameraSegmentTitle(track)
			.. "  "
			.. TimelineUnity.cameraSegmentSubtitle(track, s.from, s.to, fpsNow)
	end
	-- 点击选中本轨(按当前 tracks 数组里的索引)。
	local function selectSelf()
		state.selectedTrack:set(table.find(state.tracks:get(), track))
	end
	local selectedStroke = Computed(function()
		local sel = state.selectedTrack:get() == table.find(state.tracks:get(), track)
		return if sel then 0 else 1
	end)
	local function edge(anchorX: number, isFrom: boolean): Instance
		local edgeBtn = e("TextButton")({
			BackgroundColor3 = Theme.color.handle,
			BackgroundTransparency = 0.25,
			BorderSizePixel = 0,
			Size = UDim2.new(0, 6, 1, 0),
			AnchorPoint = Vector2.new(anchorX, 0),
			Position = UDim2.fromScale(anchorX, 0),
			ZIndex = 5,
			Text = "",
			[OnEvent("InputBegan")] = function(input: InputObject)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					local s0 = seg()
					local grab = DragController.fracInArea(area(), gui:GetRelativeMousePosition())
							* state.duration:get()
						- (if isFrom then s0.from else s0.to)
					beginTimelineDrag(gui, {
						onBegin = function()
							state:pushUndo()
						end,
						onMove = function(mouse)
							local t = draggedTime(state, area(), mouse, grab, track, nil)
							local s = seg()
							if isFrom then
								s.from = math.min(t, s.to)
							else
								s.to = math.max(t, s.from)
							end
							refresh()
						end,
						onEnd = function()
							state:finishDrag()
						end,
						onClick = selectSelf,
					}, edgeBtn)
				end
			end,
		})
		return edgeBtn
	end

	local dur = state.duration:get()
	local s0 = seg()
	local fps = state.fps:get()
	local segText = TimelineUnity.cameraSegmentTitle(track)
		.. "  "
		.. TimelineUnity.cameraSegmentSubtitle(track, s0.from, s0.to, fps)
	block = e("TextButton")({
		BackgroundColor3 = Theme.color.track.camera,
		BackgroundTransparency = 0.65,
		Position = UDim2.new(s0.from / dur, 1, 0, 4),
		Size = UDim2.new(math.max((s0.to - s0.from) / dur, 0.005), -2, 1, -8),
		Text = segText,
		TextColor3 = Theme.color.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = Theme.font.main,
		TextSize = 10,
		TextTruncate = Enum.TextTruncate.AtEnd,
		AutoButtonColor = false,
		ZIndex = 3,
		-- 左键:点击选中,长按整体平移本段(保持时长,抓哪儿拖哪儿);两端 resize 由 edge 把手负责。
		-- 右键菜单挂 InputBegan(按下即弹):与轨道行的 defer 兜底菜单同帧仲裁。
		[OnEvent("InputBegan")] = function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				local length = seg().to - seg().from
				local grab = DragController.fracInArea(area(), gui:GetRelativeMousePosition())
						* state.duration:get()
					- seg().from
				beginTimelineDrag(gui, {
					onBegin = function()
						state:pushUndo()
					end,
					onMove = function(mouse)
						local d = state.duration:get()
						local f = math.clamp(draggedTime(state, area(), mouse, grab, track, nil), 0, d - length)
						local s = seg()
						s.from = f
						s.to = f + length
						refresh()
					end,
					onEnd = function()
						state:finishDrag()
					end,
					onClick = selectSelf,
				}, block)
				return
			end
			if input.UserInputType ~= Enum.UserInputType.MouseButton2 then
				return
			end
			selectSelf()
			ContextMenu.show(gui, {
				{
					kind = "header",
					text = "相机轨 " .. track.target .. "(段 " .. segIndex .. ")",
				},
				{
					text = "定位到段起点",
					onClick = function()
						state:setTime(seg().from)
					end,
				},
				{
					text = "输入起止帧…",
					onClick = function()
						local fps = state.fps:get()
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
									state:setSegmentRange(track, segIndex, fa / fps, fb / fps)
								end
							end,
						})
					end,
				},
				{
					text = "＋ 在播放头处加一段",
					onClick = function()
						state:addSegment(track, state.currentTime:get())
					end,
				},
				{
					text = "删除此段",
					color = Theme.color.danger,
					onClick = function()
						state:removeSegment(track, segIndex)
					end,
				},
				{ kind = "sep" },
				{
					text = "删除整条相机轨",
					color = Theme.color.danger,
					onClick = function()
						state:removeTrack(track)
					end,
				},
			})
		end,
		[Children] = {
			e("UICorner")({ CornerRadius = UDim.new(0, 3) }),
			e("UIPadding")({ PaddingLeft = UDim.new(0, 9) }),
			e("UIStroke")({
				Color = Theme.color.accent,
				Thickness = 2,
				Transparency = selectedStroke,
			}),
			edge(0),
			edge(1),
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

	if track.kind == "camera" and track.segments and #track.segments > 0 then
		for i in track.segments do
			table.insert(kids, segmentBlock(gui, state, area, track, i))
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
							math.round(DragController.fracInArea(area(), m) * d * fps) / fps,
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

local function rowFrame(index: number, bg: Color3, child: Instance): Instance
	return e("Frame")({
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
					return UDim2.new(state.currentTime:get() / dur, 0, 1, 0)
				end),
				Size = UDim2.new(0, Theme.size.playheadHandleWidth, 1, 0),
				BackgroundTransparency = 1,
				Text = "▼",
				TextColor3 = Computed(function()
					return if playheadHandleHover:get()
						then Color3.fromRGB(255, 120, 120)
						else Theme.color.playhead
				end),
				TextSize = 22,
				Font = Theme.font.bold,
				TextYAlignment = Enum.TextYAlignment.Bottom,
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
						beginScrub(gui, state, area(), nil, true, playheadHeadBtn)
					end
				end,
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
							local src = if input.Target and input.Target:IsA("GuiObject")
								then input.Target :: GuiObject
								else nil
							beginScrub(gui, state, area(), nil, false, src)
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

-- 相机轨行内控件:曲线/直线切换 + ⏺ 录制(仅"每相机独立轨"显示)。
local function cameraRowControls(
	state: EditorState.EditorState,
	cb: Callbacks,
	track: CutsceneFormat.Track
): Instance
	if track.kind ~= "camera" then
		return e("Frame")({ BackgroundTransparency = 1, Size = UDim2.fromScale(0, 1) })
	end
	local recording = cb.recordingCam:get() == track.target
	local smooth = track.smooth == true
	return e("Frame")({
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -4, 0.5, 0),
		Size = UDim2.fromOffset(42, 18),
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
				Size = UDim2.fromOffset(18, 18),
				BackgroundColor3 = if smooth then Theme.color.accent else Theme.color.panel,
				Text = if smooth then "◠" else "—",
				TextColor3 = Theme.color.text,
				Font = Theme.font.bold,
				TextSize = 12,
				ZIndex = 3,
				[OnEvent("Activated")] = function()
					state:setTrackSmooth(track, not smooth)
				end,
				[Children] = e("UICorner")({ CornerRadius = UDim.new(0, 3) }),
			}),
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
			}),
		},
	})
end

-- 轨道行右侧的绑定芯片(Timeline 的 binding 槽):常驻显示 target,点击换绑。
-- camera / cameraMove 轨的 target 是 vcam 名、右侧另有自己的控件,不给芯片。
local function bindingChip(
	gui: PluginGui,
	state: EditorState.EditorState,
	cb: Callbacks,
	track: CutsceneFormat.Track
): Instance
	if track.kind == "camera" or track.kind == "cameraMove" then
		return e("Frame")({ BackgroundTransparency = 1, Size = UDim2.fromScale(0, 1) })
	end
	return e("TextButton")({
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -4, 0.5, 0),
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
							text = "🎥 摄像机轨",
							onClick = function()
								cb.onAddCameraTrack(group)
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
						for _, vn in VCam.list() do
							table.insert(items, {
								text = "相机运动轨 → " .. vn,
								onClick = function()
									state:addTrack("cameraMove", vn, "运动:" .. vn, group)
								end,
							})
						end
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
	collapsed: Fusion.Value<{ [string]: boolean }>
): Instance
	local rows = Computed(function()
		local tracks = state.tracks:get()
		local kids: { Instance } = {
			e("Frame")({ -- 表头 + 加轨道
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
								position = Vector2.new(ap.X - gOrigin.X, ap.Y - gOrigin.Y + asz.Y + 2),
								width = 228,
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
			}),
		}
		for i, row in buildDisplayRows(tracks, collapsed:get()) do
			if row.kind == "header" then
				table.insert(kids, labelHeaderRow(gui, state, cb, collapsed, row.group, i))
			else
				local track = row.track
				local index = i
				local bg = Theme.color.trackHeader
				local hasChip = track.kind ~= "camera" and track.kind ~= "cameraMove"
				local title = TimelineUnity.trackTitle(track)
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
									Size = if hasChip
										then UDim2.new(1, -108, 1, 0)
										else UDim2.new(1, -44, 1, 0),
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
								bindingChip(gui, state, cb, track),
							},
						})
					)
				)
			end
		end
		return kids
	end)

	return e("Frame")({
		BackgroundColor3 = Theme.color.panelAlt,
		BorderSizePixel = 0,
		Active = true,
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
		[Children] = rows,
	})
end

--========================= 右时间轴 =========================--

local function timeline(
	gui: PluginGui,
	state: EditorState.EditorState,
	cb: Callbacks,
	collapsed: Fusion.Value<{ [string]: boolean }>
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
		local tracks = state.tracks:get()
		local kids: { Instance } = { ruler(gui, state, area, areaWidth) }
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
				table.insert(kids, rowFrame(index, bg, trackContent(gui, state, cb, area, track)))
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
		[Children] = rows,
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
		[Children] = { rowsHolder, gridHolder, playhead },
	})
	scroller = e("ScrollingFrame")({
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		CanvasSize = Computed(function()
			return UDim2.new(0, canvasWidthPx:get(), 0, math.max(viewportHeight:get(), 1))
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
					}, if resizeBar and resizeBar:IsA("GuiObject") then resizeBar else nil)
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
			labelColumn(gui, state, cb, collapsed),
			timeline(gui, state, cb, collapsed),
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

	local root = e("Frame")({
		Name = "AnimaTimeline",
		BackgroundColor3 = Theme.color.bg,
		Size = UDim2.fromScale(1, 1),
		BorderSizePixel = 0,
		[Children] = {
			topbar(gui, state, cb, previewCollapsed),
			previewContainer,
			vcamWrap,
			body,
			adjustBadge,
		},
	})
	root.Parent = gui

	-- 让 init 把 PreviewViewport 挂进预览容器
	cb.mountPreview(previewContainer)

	local function cleanup()
		root:Destroy()
	end
	return root, cleanup
end

return App
