--!strict
-- Anima 插件入口。工具栏按钮 + 两个停靠面板(时间轴 + 独立相机预览),挂载 Timeline App。
-- 时间轴面板内嵌一条实时预览;3D 视口显示运镜轨迹;编辑走 EditorState(含撤销栈)。
-- 仅在真实插件环境运行(有 plugin 全局)。

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Selection = game:GetService("Selection")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local Fusion = require(script.Packages.Fusion)
local EditorState = require(script.EditorState)
local App = require(script.App)
local Serializer = require(script.Serializer)
local LivePreview = require(script.LivePreview)
local Preview = require(script.Preview)
local PreviewViewport = require(script.PreviewViewport)
local CameraPath = require(script.CameraPath)
local Playback = require(script.Playback)
local Recorder = require(script.Recorder)
local KeyframeAdjust = require(script.KeyframeAdjust)
local CameraAuthoring = require(script.CameraAuthoring)
local VCamAuthoring = require(script.VCamAuthoring)
local VCam = require(script.Shared.VCam)
local CutsceneFormat = require(script.Shared.CutsceneFormat)
local SceneResolver = require(script.SceneResolver)
local FollowAnchor = require(script.Shared.FollowAnchor)
local EditorPersistence = require(script.EditorPersistence)
local InputPrompt = require(script.InputPrompt)
local ContextMenu = require(script.ContextMenu)
local CutsceneExport = require(script.CutsceneExport)
local PathPreviewPrefs = require(script.PathPreviewPrefs)

local ChangeHistoryService = game:GetService("ChangeHistoryService")

-- 载入初始过场:优先用场景里已同步的 boss_intro,否则空模板。
local function loadInitialCutscene()
	local anima = ReplicatedStorage:FindFirstChild("Anima")
	if anima then
		local cutscenes = anima:FindFirstChild("Cutscenes")
		local sample = cutscenes and cutscenes:FindFirstChild("boss_intro")
		if sample and sample:IsA("ModuleScript") then
			local ok, data = pcall(require, sample)
			if ok and data then
				return data
			end
		end
	end
	return {
		name = "untitled",
		duration = 5,
		-- 空时间轴:用顶栏「＋相机」或轨道区「＋」新建独立相机轨/其它轨道。
		tracks = {},
	}
end

local plugin = plugin :: Plugin

local DRAFT_DEBOUNCE_SEC = 2
local EXPORT_TIME_EPS = 1e-4
local draftSaveScheduled = false

local function resolveInitialCutscene(): CutsceneFormat.Cutscene
	local draft = EditorPersistence.readDraft(plugin)
	if draft then
		local parsed = Serializer.deserialize(draft)
		if parsed then
			print("[anima] 已恢复未保存草稿(上次关闭 Studio 前的 Timeline 编辑)")
			return parsed
		end
	end
	return loadInitialCutscene()
end

local state: EditorState.EditorState
local function getCutscene()
	return state:toCutscene()
end
local function getTime()
	return state.currentTime:get()
end

local function flushDraftSave()
	EditorPersistence.saveDraft(plugin, Serializer.serialize(getCutscene()))
end

local function scheduleDraftSave()
	if draftSaveScheduled then
		return
	end
	draftSaveScheduled = true
	task.delay(DRAFT_DEBOUNCE_SEC, function()
		draftSaveScheduled = false
		flushDraftSave()
	end)
end

local function applyImportedCutscene(cutscene: CutsceneFormat.Cutscene, sourceLabel: string)
	state:loadCutscene(cutscene)
	EditorPersistence.clearDraft(plugin)
	scheduleDraftSave()
	print(`[anima] 已导入过场 · {sourceLabel}`)
end

state = EditorState.new(resolveInitialCutscene())
Preview.cutsceneRevision = state.revision:get()
local toolbar = plugin:CreateToolbar("Anima")
local openButton = toolbar:CreateButton("过场编辑器", "打开 Anima Timeline 面板", "")
openButton.ClickableWhenViewportHidden = true
local previewButton = toolbar:CreateButton("相机预览", "开关独立相机预览窗口", "")
previewButton.ClickableWhenViewportHidden = true

local widget = plugin:CreateDockWidgetPluginGui(
	"AnimaTimeline",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Bottom, false, false, 1000, 480, 620, 320)
)
widget.Title = "Anima Timeline"
widget.Name = "AnimaTimeline"

local previewWidget = plugin:CreateDockWidgetPluginGui(
	"AnimaCameraPreview",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 440, 300, 240, 160)
)
previewWidget.Title = "Anima 相机预览"
previewWidget.Name = "AnimaCameraPreview"

local playback = Playback.new(state)
local recorder = Recorder.new(state)
local mainPreview = LivePreview.new()
local mainPreviewActive = Fusion.Value(false)
local recordActive = Fusion.Value(false)
local recordingCam: Fusion.Value<string?> = Fusion.Value(nil)
local kfAdjust = KeyframeAdjust.new(state)
local cameraAuthoring = CameraAuthoring.new({
	mainPreview = mainPreview,
	mainPreviewActive = mainPreviewActive,
	playback = playback,
	kfAdjust = kfAdjust,
	recorder = recorder,
	recordingCam = recordingCam,
})
local standalonePreview = PreviewViewport.new(previewWidget) -- 独立窗口
local mounted = false
local lastVcam: string? = nil

local embeddedPreview: PreviewViewport.PreviewViewport? = nil -- 面板内嵌预览
local cameraPath: CameraPath.CameraPath? = nil
local pathConn: RBXScriptConnection? = nil
local pathPreviewInputConn: RBXScriptConnection? = nil

-- getCutscene / getTime 已在 state 初始化处定义

-- 独立预览窗口开关时启停
previewWidget:GetPropertyChangedSignal("Enabled"):Connect(function()
	previewButton:SetActive(previewWidget.Enabled)
	if previewWidget.Enabled then
		standalonePreview:start(getCutscene, getTime, function()
			return state.revision:get()
		end)
	else
		standalonePreview:stop()
	end
end)

-- 收集场景里可作为轨道目标 / LookAt 的候选名。
local function targetCandidates(): { string }
	local seen: { [string]: boolean } = { Player = true }
	local out: { string } = { "Player" }
	local function add(name: string)
		if name ~= "" and not seen[name] and not VCam.find(name) then
			seen[name] = true
			table.insert(out, name)
		end
	end
	for _, d in workspace:GetChildren() do
		if d.Name == VCam.CONTAINER or d.Name == "AnimaCameraPath" or d.Name == "Baseplate" then
			continue
		end
		if d:IsA("Model") or d:IsA("BasePart") then
			add(d.Name)
		end
	end
	return out
end

-- 动画轨用的角色候选:"Player" + 场景里带 Humanoid(骨骼)的 Model。
local function characterCandidates(): { string }
	local seen: { [string]: boolean } = { Player = true }
	local out: { string } = { "Player" }
	for _, d in workspace:GetChildren() do
		if d:IsA("Model") and not seen[d.Name] and d:FindFirstChildOfClass("Humanoid") then
			seen[d.Name] = true
			table.insert(out, d.Name)
		end
	end
	return out
end

-- 删除引用某 vcam 的一切轨道:独立相机轨(target=name)+ 其运动轨(cameraMove target=name)。
local function purgeVcamRefs(name: string)
	state:pushUndo()
	local tracks = state.tracks:get()
	for i = #tracks, 1, -1 do
		local tr = tracks[i]
		if (tr.kind == "camera" or tr.kind == "cameraMove") and tr.target == name then
			table.remove(tracks, i)
		end
	end
	state:commitTracks(true)
end

-- 当前选中的轨道对象(按 state.selectedTrack 索引取);无选中返回 nil。
local function selectedTrackObj()
	local idx = state.selectedTrack:get()
	if not idx then
		return nil
	end
	return state.tracks:get()[idx]
end

local function cameraPathRebuildOpts(): CameraPath.RebuildOpts
	return {
		hideTangentGizmos = kfAdjust.current:get() ~= nil or playback.isPlaying:get(),
		previewPrefs = PathPreviewPrefs.load(plugin),
	}
end

local function rebuildCameraPathNow()
	if cameraPath then
		cameraPath:rebuild(getCutscene(), selectedTrackObj(), cameraPathRebuildOpts())
	end
end

-- 打帧后让 vcam Part 与视口一致(M3 策略 A,便于继续 WASD 摆下一帧)。
local function syncVcamPartFromCFrame(vcamName: string, cf: CFrame)
	local part = VCam.find(vcamName)
	if part then
		part.CFrame = cf
	end
end

local function bindingResolver(name: string): Instance?
	return SceneResolver.resolve(name)
end

local function onCaptureCameraTrack(track: CutsceneFormat.Track, t: number?)
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	if track.kind ~= "camera" then
		return
	end
	local at = t or state.currentTime:get()
	local stored = FollowAnchor.storeKeyframeCFrame(track, cam.CFrame, bindingResolver)
	state:captureFrame(track, stored, at)
	syncVcamPartFromCFrame(track.target, cam.CFrame)
	print(
		`[anima] 已在 {string.format("%.2fs", at)} 采集视口位姿 → 相机轨 '{track.target}'`
	)
end

local function onCaptureAtPlayhead()
	local track = selectedTrackObj()
	if not track then
		print("[anima] 打帧 K:请先选中一条 camera / cameraMove 轨")
		return
	end
	if track.kind == "camera" then
		onCaptureCameraTrack(track, nil)
	elseif track.kind == "cameraMove" then
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		state:captureFrame(track, cam.CFrame, nil)
		syncVcamPartFromCFrame(track.target, cam.CFrame)
		print(
			`[anima] 已在 {string.format("%.2fs", state.currentTime:get())} 采集视口位姿 → 运动轨 '{track.target}'`
		)
	else
		print("[anima] 打帧 K:请先选中 camera 或 cameraMove 轨")
	end
end

local function promptExportToPlace(gui: PluginGui)
	local defaultName = state.name:get()
	if defaultName == "untitled" or defaultName == "" then
		defaultName = "my_cutscene"
	end
	InputPrompt.show(gui, {
		title = "导出 · 模块名",
		default = defaultName,
		placeholder = "如 ult_slash / boss_intro",
		onSubmit = function(moduleName)
			if moduleName == "" then
				return
			end
			InputPrompt.show(gui, {
				title = "导出 · 子路径(可选)",
				default = "",
				placeholder = "留空=Cutscenes 根; 例 Skills/Ult",
				onSubmit = function(subPath)
					local cs = getCutscene()
					local fps = math.max(cs.fps or 30, 1)
					local fullDur = cs.duration
					local totalFrames = math.round(fullDur * fps)
					InputPrompt.show(gui, {
						title = "导出区间 · 起始",
						default = "0",
						placeholder = "帧(整数)或秒(小数);留空=0",
						onSubmit = function(startTxt)
							InputPrompt.show(gui, {
								title = "导出区间 · 结束",
								default = tostring(totalFrames),
								placeholder = `留空=总帧 {totalFrames}`,
								onSubmit = function(endTxt)
									local fromSec = CutsceneExport.parseExportTimeInput(startTxt, fps, 0)
									local toSec = CutsceneExport.parseExportTimeInput(endTxt, fps, fullDur)
									if fromSec == nil or toSec == nil then
										warn("[anima] 导出区间无效:请输入数字(帧或秒)")
										return
									end
									if fromSec < -EXPORT_TIME_EPS or toSec > fullDur + EXPORT_TIME_EPS or fromSec >= toSec - EXPORT_TIME_EPS then
										warn(
											string.format(
												"[anima] 导出区间无效:需满足 0 <= 起始 < 结束 <= %.2fs",
												fullDur
											)
										)
										return
									end
									local sliced, sliceWarnings = CutsceneExport.slice(cs, fromSec, toSec)
									for _, w in sliceWarnings do
										warn(w)
									end
									print(CutsceneExport.formatExportRangeLog(fromSec, toSec, fps, sliced.duration))
									local ok, mod, reqPath = pcall(CutsceneExport.writeModule, sliced, subPath, moduleName)
									if not ok or not mod then
										warn(tostring(mod))
										return
									end
									CutsceneExport.writeAnimaExportString((mod :: ModuleScript).Source)
									state.name:set(moduleName)
									ChangeHistoryService:SetWaypoint("Anima 导出过场")
									Selection:Set({ mod :: ModuleScript })
									EditorPersistence.clearDraft(plugin)
									scheduleDraftSave()
									local fileHint = CutsceneExport.suggestedFilePath(subPath, moduleName)
									print(`[anima] 已导出 ModuleScript → ReplicatedStorage.{reqPath}`)
									print(`[anima] 程序 require: ReplicatedStorage.{reqPath}`)
									print(`[anima] Git/Rojo 建议路径: {fileHint}`)
									print("[anima] 副本仍在 ReplicatedStorage.AnimaExport(供 MCP 写盘)")
								end,
							})
						end,
					})
				end,
			})
		end,
	})
end

local callbacks: App.Callbacks = {
	isPlaying = playback.isPlaying,
	loop = playback.loop,
	mainPreviewActive = mainPreviewActive,
	recordActive = recordActive,
	authoringMode = cameraAuthoring.authoringMode,

	onPlayPause = function()
		if not playback.isPlaying:get() and cameraAuthoring:isActive() then
			cameraAuthoring:exit("播放")
		end
		kfAdjust:stop() -- 播放接管相机,先退出对帧调整
		playback:toggle()
	end,
	onToStart = function()
		playback:toStart()
	end,
	onToggleLoop = function()
		playback:toggleLoop()
	end,

	-- 录制开关(auto-key):开始前先关主视口跟随,让视口/gizmo 可自由摆布
	onToggleRecord = function()
		if not recorder.active then
			if cameraAuthoring:isActive() then
				cameraAuthoring:exit("Record 录制")
			end
			kfAdjust:stop()
			if mainPreview.active then
				mainPreview:stop()
				mainPreviewActive:set(false)
			end
		end
		recorder:toggle()
		recordActive:set(recorder.active)
		if recorder.active then
			print(
				"[anima] ● 录制开始 — scrub 到某刻,在视口摆物体/移动相机 gizmo 自动打帧"
			)
		else
			print("[anima] ● 录制结束")
		end
	end,

	-- 跟随主视口(全保真):接管主视口相机随播放头驱动,再点归还
	onToggleMainPreview = function()
		if mainPreview.active then
			mainPreview:stop()
			mainPreviewActive:set(false)
			print("[anima] 主视口跟随已关闭,相机已归还")
			cameraAuthoring:syncFromTrack(selectedTrackObj())
		else
			if cameraAuthoring:isActive() then
				cameraAuthoring:exit("主视口跟随")
			end
			kfAdjust:stop()
			mainPreview:start(getCutscene, getTime, bindingResolver)
			mainPreviewActive:set(true)
			print("[anima] 主视口跟随已开启")
		end
	end,

	-- 顶栏「＋相机」:当前视口位姿新建 vcam + 一条独立相机轨(生效区间默认整段)。
	-- 与菜单「＋摄像机(独立轨)」归一,统一走独立轨模型。
	onAddVcam = function()
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		local name = VCamAuthoring.nextName()
		VCamAuthoring.create(name, cam.CFrame)
		local idx = state:addCameraTrack(name, 0, state.duration:get(), nil)
		state.selectedTrack:set(idx)
		lastVcam = name
		print(
			`[anima] 新建独立相机轨 {name} @ {string.format("%.2fs", state.currentTime:get())}`
		)
	end,

	onLookThrough = function()
		local target = lastVcam
		local cutscene = getCutscene()
		local t = state.currentTime:get()
		-- 覆盖 t 的独立相机轨(索引最小者上镜),与 CameraDirector 一致
		local bestIdx: number? = nil
		for i, track in cutscene.tracks do
			if track.kind == "camera" and CutsceneFormat.coversAt(track, t) then
				if not bestIdx or i < bestIdx then
					bestIdx, target = i, track.target
				end
			end
		end
		if target and LivePreview.lookThrough(target) then
			print(`[anima] 透视 vcam {target}`)
		else
			print("[anima] 还没有可透视的 vcam,先点『＋ 相机』")
		end
	end,

	onExport = function(gui: PluginGui)
		promptExportToPlace(gui)
	end,

	onSaveAsModule = function(gui: PluginGui)
		promptExportToPlace(gui)
	end,

	onNewDocument = function()
		state:loadCutscene(EditorState.emptyUntitled())
		EditorPersistence.clearDraft(plugin)
		scheduleDraftSave()
		print("[anima] 新建空白过场 untitled")
	end,

	onRestoreDraft = function()
		local draft = EditorPersistence.readDraft(plugin)
		if not draft then
			print("[anima] 没有可恢复的 Plugin 草稿")
			return
		end
		local parsed = Serializer.deserialize(draft)
		if parsed then
			state:loadCutscene(parsed)
			print("[anima] 已从 Plugin 草稿恢复")
		else
			warn("[anima] 草稿损坏,无法反序列化")
		end
	end,

	onImportMenu = function(gui: PluginGui)
		ContextMenu.show(gui, {
			{ kind = "header", text = "导入过场到 Timeline" },
			{
				text = "从 ReplicatedStorage.AnimaExport",
				onClick = function()
					local holder = ReplicatedStorage:FindFirstChild("AnimaExport")
					if not holder or not holder:IsA("StringValue") or holder.Value == "" then
						warn("[anima] 找不到 AnimaExport 或为空,请先 💾 导出或粘贴源码")
						return
					end
					local parsed = Serializer.deserialize(holder.Value)
					if not parsed then
						warn("[anima] AnimaExport 内容无法解析")
						return
					end
					applyImportedCutscene(parsed, "AnimaExport")
				end,
			},
			{
				text = "从 Explorer 选中 ModuleScript",
				onClick = function()
					local sel = Selection:Get()
					if #sel ~= 1 or not sel[1]:IsA("ModuleScript") then
						warn("[anima] 请在 Explorer 中选中一个 cutscene ModuleScript")
						return
					end
					local ok, data = pcall(require, sel[1])
					if not ok or type(data) ~= "table" or type(data.tracks) ~= "table" then
						warn("[anima] 所选模块不是有效的 cutscene 表")
						return
					end
					applyImportedCutscene(data :: CutsceneFormat.Cutscene, sel[1].Name)
				end,
			},
		}, { width = 260 })
	end,

	-- init 把内嵌预览挂进面板容器
	mountPreview = function(container)
		local pv = PreviewViewport.new(container)
		pv:start(getCutscene, getTime, function()
			return state.revision:get()
		end)
		embeddedPreview = pv
		Preview.skipWorkspaceMedia = true
	end,

	onSelectVcam = function(name)
		local part = VCam.find(name)
		if part then
			Selection:Set({ part })
			lastVcam = name
		end
	end,
	onDeleteVcam = function(name)
		purgeVcamRefs(name)
		local part = VCam.find(name)
		if part then
			part:Destroy()
		end
		print(`[anima] 已删除虚拟相机 {name}`)
	end,
	onRenameVcam = function(old, new)
		if new == "" or VCam.find(new) then
			return
		end
		local part = VCam.find(old)
		if not part then
			return
		end
		part.Name = new
		for _, tr in state.tracks:get() do
			-- 独立相机轨 / 运动轨:target 引用 vcam 名
			if (tr.kind == "camera" or tr.kind == "cameraMove") and tr.target == old then
				tr.target = new
				if tr.name == "🎥 " .. old then
					tr.name = "🎥 " .. new
				end
			end
		end
		state:commitTracks(true)
	end,
	onSetVcamFov = function(name, fov)
		local part = VCam.find(name)
		if part then
			part:SetAttribute("FOV", fov)
			state:commitTracks(true)
		end
	end,
	onSetVcamLookAt = function(name, target)
		VCamAuthoring.setLookAt(name, target)
		state:commitTracks(true)
	end,
	onRecaptureVcam = function(name)
		local part = VCam.find(name)
		local cam = workspace.CurrentCamera
		if part and cam then
			part.CFrame = cam.CFrame
			state:commitTracks(true)
			print(`[anima] 已用当前视口位姿更新 {name}`)
		end
	end,
	-- t:时间轴右键传入的点击处时间;缺省 = 当前播放头时间
	onCaptureTransform = function(track, t)
		local inst = SceneResolver.resolve(track.target)
		if not inst then
			warn(`[anima] 打帧失败:找不到目标 '{track.target}'`)
			return
		end
		local cf: CFrame? = nil
		if inst:IsA("BasePart") then
			cf = inst.CFrame
		elseif inst:IsA("Model") then
			local ok, pivot = pcall(function()
				return inst:GetPivot()
			end)
			if ok then
				cf = pivot
			end
		end
		if cf then
			state:captureFrame(track, cf, t)
			print(
				`[anima] 已在 {string.format("%.2fs", t or state.currentTime:get())} 采集 '{track.target}' 位姿`
			)
		end
	end,
	-- 相机运动轨打帧:采集当前编辑视口相机的位姿(想让这台相机此刻在哪)
	onCaptureCameraMove = function(track, t)
		local cam = workspace.CurrentCamera
		if cam then
			state:captureFrame(track, cam.CFrame, t)
			print(
				`[anima] 已在 {string.format("%.2fs", t or state.currentTime:get())} 采集相机位姿 → 运动轨 '{track.target}'`
			)
		end
	end,
	onCaptureCameraTrack = onCaptureCameraTrack,
	onCaptureAtPlayhead = onCaptureAtPlayhead,

	recordingCam = recordingCam,

	onJumpToCameraKeyframe = function(track, kf)
		if kfAdjust.current:get() then
			kfAdjust:stop()
		end
		state:setTime(kf.t)
		local idx = table.find(state.tracks:get(), track)
		if idx then
			state.selectedTrack:set(idx)
		end
		local cf = kf.value
		if typeof(cf) ~= "CFrame" then
			return
		end
		if track.kind == "camera" then
			cf = FollowAnchor.worldFromKeyframeCFrame(track, cf, bindingResolver)
		end
		local vcamName = track.target
		if track.kind == "cameraMove" and vcamName ~= "" then
			cameraAuthoring:snapViewport(vcamName, cf)
		elseif track.kind == "camera" and vcamName ~= "" then
			cameraAuthoring:snapViewport(vcamName, cf)
		else
			local cam = workspace.CurrentCamera
			if cam then
				cam.CameraType = Enum.CameraType.Custom
				cam.CFrame = cf
			end
		end
		print(
			`[anima] 已跳到关键帧 @ {string.format("%.2fs", kf.t)} — 可用 WASD 微调视口,按 K 写回选中轨`
		)
	end,

	-- 相机轨行内录制:点开始记第一段起点+起始帧,点结束记第一段止+结束帧(采视口相机位姿)。整段一步撤销。
	onCameraRecord = function(track)
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		if recordingCam:get() ~= track.target then
			if cameraAuthoring:isActive() then
				cameraAuthoring:exit("相机轨录制")
			end
		end
		if not track.segments or #track.segments == 0 then
			track.segments = { { from = 0, to = 0 } }
		end
		local seg = track.segments[1]
		local t = state.currentTime:get()
		if recordingCam:get() == track.target then
			seg.to = math.max(t, seg.from)
			recordingCam:set(nil)
			state:captureFrameNoUndo(
				track,
				FollowAnchor.storeKeyframeCFrame(track, cam.CFrame, bindingResolver)
			)
			print(`[anima] 相机轨 {track.target} 录制结束 @ {string.format("%.2f", t)}s`)
		else
			state:pushUndo()
			seg.from = t
			seg.to = t
			recordingCam:set(track.target)
			state:captureFrameNoUndo(
				track,
				FollowAnchor.storeKeyframeCFrame(track, cam.CFrame, bindingResolver)
			)
			print(
				`[anima] 相机轨 {track.target} 开始录制 @ {string.format("%.2f", t)}s — 与透视编辑互斥;日常摆镜建议 WASD + K`
			)
		end
	end,

	targetCandidates = targetCandidates,
	characterCandidates = characterCandidates,

	-- 视口对帧调整:跳进该帧视角自由取景,实时写回关键帧(所见即所得)。
	-- 与主视口跟随 / 录制 / 播放互斥(都在抢视口相机)。
	adjustingKf = kfAdjust.current,
	onAdjustKeyframe = function(track, kf)
		if kfAdjust.current:get() ~= kf then
			if cameraAuthoring:isActive() then
				cameraAuthoring:exit("视口对帧")
			end
			if mainPreview.active then
				mainPreview:stop()
				mainPreviewActive:set(false)
			end
			if recorder.active then
				recorder:stop()
				recordActive:set(false)
			end
			if playback.isPlaying:get() then
				playback:toggle()
			end
		end
		kfAdjust:toggle(track, kf)
		if kfAdjust.current:get() then
			print(
				`[anima] 🎥 视口对帧调整 @ {string.format("%.2fs", kf.t)} — 在视口自由取景即实时写回该帧,点顶部提示条结束`
			)
		else
			print("[anima] 视口对帧调整结束")
		end
	end,
	onStopAdjust = function()
		kfAdjust:stop()
		print("[anima] 视口对帧调整结束")
	end,
	appendPathPreviewMenuItems = function(gui: PluginGui, items: { ContextMenu.Item })
		table.insert(items, { kind = "sep" })
		for _, it in PathPreviewPrefs.menuItems(gui, plugin, rebuildCameraPathNow) do
			table.insert(items, it)
		end
	end,
}

local function applyTangentEdit(ed: CameraPath.TangentEdit)
	local tr = ed.track
	if not tr.keyframes then
		return
	end
	local kf = tr.keyframes[ed.kfIndex]
	if not kf or not kf.value then
		return
	end
	local anchorWorld = FollowAnchor.worldFromKeyframeCFrame(tr, kf.value, bindingResolver)
	local delta = ed.worldControl - anchorWorld.Position
	local stored = FollowAnchor.worldDeltaToStoredOffset(tr, delta, bindingResolver)
	local symmetric = UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightAlt)
	if ed.field == "out" then
		kf.outTangent = stored
		if symmetric then
			kf.inTangent = -stored
		end
	else
		kf.inTangent = stored
		if symmetric then
			kf.outTangent = -stored
		end
	end
end

-- 面板打开时:确保挂载 + 启动运镜轨迹;关闭时销毁轨迹与内嵌预览。
local function startCameraPath()
	if cameraPath then
		return
	end
	local cp = CameraPath.new()
	cp:rebuild(getCutscene(), selectedTrackObj(), cameraPathRebuildOpts())
	cameraPath = cp
	-- 机位把手反向编辑(M5:一次拖拽一步 undo;authoring 下仍可拖把手改已有 key)。
	local handleUndoArmed = false
	local lastHandleActivity = 0
	local HANDLE_UNDO_GAP = 0.4
	local lastHandleCommit = 0
	local handleDirty = false
	pathConn = RunService.RenderStepped:Connect(function()
		local ok, err = pcall(function()
			cp:updateHead(getCutscene(), getTime())
			local edits = cp:consumeHandleEdits()
			local tanEdits = cp:consumeTangentEdits()
			if #edits > 0 or #tanEdits > 0 then
				if not handleUndoArmed then
					state:pushUndo()
					handleUndoArmed = true
				end
				lastHandleActivity = os.clock()
				for _, ed in edits do
					local tr = ed.track
					if tr.keyframes then
						local kf = tr.keyframes[ed.kfIndex]
						if kf then
							kf.value = FollowAnchor.storeKeyframeCFrame(tr, ed.cf, bindingResolver)
						end
					end
				end
				for _, ed in tanEdits do
					applyTangentEdit(ed)
				end
				handleDirty = true
			elseif handleUndoArmed and os.clock() - lastHandleActivity >= HANDLE_UNDO_GAP then
				handleUndoArmed = false
			end
			if handleDirty and os.clock() - lastHandleCommit >= 0.2 then
				handleDirty = false
				lastHandleCommit = os.clock()
				state:commitTracks(true)
			end
		end)
		if not ok then
			warn("[anima] 轨迹更新出错:", err)
		end
	end)
	if pathPreviewInputConn then
		pathPreviewInputConn:Disconnect()
	end
	pathPreviewInputConn = UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed then
			return
		end
		if input.UserInputType ~= Enum.UserInputType.MouseButton2 then
			return
		end
		if not widget.Enabled or not cameraPath then
			return
		end
		local sel = Selection:Get()
		if #sel ~= 1 then
			return
		end
		local inst = sel[1]
		if not inst:IsA("BasePart") then
			return
		end
		local root = workspace:FindFirstChild("AnimaCameraPath")
		if not root or not inst:IsDescendantOf(root) then
			return
		end
		local tangentFolder = root:FindFirstChild("TangentHandles")
		if tangentFolder and inst:IsDescendantOf(tangentFolder) then
			task.defer(function()
				PathPreviewPrefs.showContextMenu(widget, plugin, rebuildCameraPathNow)
			end)
		end
	end)
end

local function stopCameraPath()
	if pathPreviewInputConn then
		pathPreviewInputConn:Disconnect()
		pathPreviewInputConn = nil
	end
	if pathConn then
		pathConn:Disconnect()
		pathConn = nil
	end
	if cameraPath then
		cameraPath:destroy()
		cameraPath = nil
	end
end

local function ensureMounted()
	if widget.Enabled then
		if not mounted then
			App.mount(widget, state, callbacks)
			mounted = true
		end
		startCameraPath()
	else
		stopCameraPath()
		if embeddedPreview then
			embeddedPreview:stop()
			embeddedPreview = nil
		end
		Preview.skipWorkspaceMedia = false
		mounted = false -- 面板关了 GUI 被销毁,重开需重挂
	end
end

Fusion.Observer(kfAdjust.current):onChange(function()
	if cameraPath then
		cameraPath:rebuild(getCutscene(), selectedTrackObj(), cameraPathRebuildOpts())
	end
end)

Fusion.Observer(playback.isPlaying):onChange(function()
	if cameraPath then
		cameraPath:rebuild(getCutscene(), selectedTrackObj(), cameraPathRebuildOpts())
	end
	if playback.isPlaying:get() then
		local cutscene = getCutscene()
		local fxCount = 0
		for _, tr in cutscene.tracks do
			if tr.kind == "effect" and tr.effectCues then
				fxCount += #tr.effectCues
				print(`[anima] 播放:特效轨 '{tr.target}' · {#tr.effectCues} 个 cue`)
				for _, c in tr.effectCues do
					local mode = if c.emitMode == "forge" then "forge" else "particle"
					print(`  · t={string.format("%.2f", c.t)}s mode={mode}`)
				end
			end
		end
		if fxCount == 0 then
			print("[anima] 播放:当前过场没有特效 cue(请检查特效轨是否有菱形)")
		end
	end
end)

-- 结构性变更(revision)时刷新预览克隆 + 重画运镜轨迹。
Fusion.Observer(state.revision):onChange(function()
	Preview.cutsceneRevision = state.revision:get()
	scheduleDraftSave()
	Preview.clearAnimationCache()
	if embeddedPreview then
		embeddedPreview:refresh()
	end
	if previewWidget.Enabled then
		standalonePreview:refresh()
	end
	if cameraPath then
		cameraPath:rebuild(getCutscene(), selectedTrackObj(), cameraPathRebuildOpts())
	end
end)

-- 拖播放头 / 播放时:场景 Rig 动画预览(主视口跟随开启时由 LivePreview 统一驱动,避免双份)。
Fusion.Observer(state.currentTime):onChange(function()
	if widget.Enabled and not mainPreview.active then
		Preview.applyAt(getCutscene(), getTime(), false)
	end
end)

-- 选中轨道变化时:运镜轨迹 + 相机轨透视编辑(A)。
Fusion.Observer(state.selectedTrack):onChange(function()
	if cameraPath then
		cameraPath:rebuild(getCutscene(), selectedTrackObj(), cameraPathRebuildOpts())
	end
end)

cameraAuthoring:bind(state, selectedTrackObj)

-- 面板内的撤销/重做快捷键(仅当鼠标在时间轴面板内,避免与 Studio 撤销打架)。
UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed or not widget.Enabled then
		return
	end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end
	local m = widget:GetRelativeMousePosition()
	local sz = widget.AbsoluteSize
	if m.X < 0 or m.Y < 0 or m.X > sz.X or m.Y > sz.Y then
		return
	end
	-- 空格 / Enter:播放暂停(面板聚焦、非输入态)
	if input.KeyCode == Enum.KeyCode.Space or input.KeyCode == Enum.KeyCode.Return then
		callbacks.onPlayPause()
		return
	end
	if input.KeyCode == Enum.KeyCode.K then
		onCaptureAtPlayhead()
		return
	end
	local ctrl = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
	if not ctrl then
		return
	end
	local shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
	if input.KeyCode == Enum.KeyCode.Z and not shift then
		state:undo()
	elseif input.KeyCode == Enum.KeyCode.Y or (input.KeyCode == Enum.KeyCode.Z and shift) then
		state:redo()
	end
end)

openButton.Click:Connect(function()
	widget.Enabled = not widget.Enabled
	openButton:SetActive(widget.Enabled)
	ensureMounted()
end)

widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	openButton:SetActive(widget.Enabled)
	ensureMounted()
end)

previewButton.Click:Connect(function()
	previewWidget.Enabled = not previewWidget.Enabled
end)

-- 卸载清理
plugin.Unloading:Connect(function()
	flushDraftSave()
	stopCameraPath()
	cameraAuthoring:exit()
	kfAdjust:stop()
	recorder:stop()
	if mainPreview.active then
		mainPreview:stop()
	end
end)

print("[anima] 插件已加载 — 工具栏 Anima ▸ 过场编辑器 / 相机预览")
