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
local PreviewViewport = require(script.PreviewViewport)
local CameraPath = require(script.CameraPath)
local Playback = require(script.Playback)
local Recorder = require(script.Recorder)
local KeyframeAdjust = require(script.KeyframeAdjust)
local VCamAuthoring = require(script.VCamAuthoring)
local VCam = require(script.Shared.VCam)
local CutsceneFormat = require(script.Shared.CutsceneFormat)
local SceneResolver = require(script.SceneResolver)

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

local state = EditorState.new(loadInitialCutscene())
local playback = Playback.new(state)
local recorder = Recorder.new(state)
local mainPreview = LivePreview.new()
local mainPreviewActive = Fusion.Value(false)
local kfAdjust = KeyframeAdjust.new(state)
local recordActive = Fusion.Value(false)
local recordingCam: Fusion.Value<string?> = Fusion.Value(nil)
local standalonePreview = PreviewViewport.new(previewWidget) -- 独立窗口
local mounted = false
local lastVcam: string? = nil

local embeddedPreview: PreviewViewport.PreviewViewport? = nil -- 面板内嵌预览
local cameraPath: CameraPath.CameraPath? = nil
local pathConn: RBXScriptConnection? = nil

local function getCutscene()
	return state:toCutscene()
end
local function getTime()
	return state.currentTime:get()
end

-- 独立预览窗口开关时启停
previewWidget:GetPropertyChangedSignal("Enabled"):Connect(function()
	previewButton:SetActive(previewWidget.Enabled)
	if previewWidget.Enabled then
		standalonePreview:start(getCutscene, getTime)
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

local callbacks: App.Callbacks = {
	isPlaying = playback.isPlaying,
	loop = playback.loop,
	mainPreviewActive = mainPreviewActive,
	recordActive = recordActive,

	onPlayPause = function()
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
		else
			kfAdjust:stop()
			mainPreview:start(getCutscene, getTime)
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
		state:addCameraTrack(name, 0, state.duration:get(), nil)
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

	onExport = function()
		local src = Serializer.serialize(getCutscene())
		local holder = ReplicatedStorage:FindFirstChild("AnimaExport")
		if not holder then
			holder = Instance.new("StringValue")
			holder.Name = "AnimaExport"
			holder.Parent = ReplicatedStorage
		end
		(holder :: StringValue).Value = src
		print("[anima] 已导出到 ReplicatedStorage.AnimaExport(供 MCP 取出写回文件)")
	end,

	-- init 把内嵌预览挂进面板容器
	mountPreview = function(container)
		local pv = PreviewViewport.new(container)
		pv:start(getCutscene, getTime)
		embeddedPreview = pv
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

	recordingCam = recordingCam,

	-- ＋摄像机:当前视口位姿建 vcam + 一条独立相机轨(生效区间默认整段)
	onAddCameraTrack = function(group)
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		local name = VCamAuthoring.nextName()
		VCamAuthoring.create(name, cam.CFrame)
		state:addCameraTrack(name, 0, state.duration:get(), group)
		lastVcam = name
		print(`[anima] 新建独立相机轨 {name} — 用行内 ⏺ 录制运镜(起止两帧)`)
	end,

	-- 相机轨行内录制:点开始记第一段起点+起始帧,点结束记第一段止+结束帧(采视口相机位姿)。整段一步撤销。
	onCameraRecord = function(track)
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		if not track.segments or #track.segments == 0 then
			track.segments = { { from = 0, to = 0 } }
		end
		local seg = track.segments[1]
		local t = state.currentTime:get()
		if recordingCam:get() == track.target then
			seg.to = math.max(t, seg.from)
			recordingCam:set(nil)
			state:captureFrameNoUndo(track, cam.CFrame)
			print(`[anima] 相机轨 {track.target} 录制结束 @ {string.format("%.2f", t)}s`)
		else
			state:pushUndo()
			seg.from = t
			seg.to = t
			recordingCam:set(track.target)
			state:captureFrameNoUndo(track, cam.CFrame)
			print(
				`[anima] 相机轨 {track.target} 开始录制 @ {string.format("%.2f", t)}s — scrub 到结束帧、在视口移动相机、再点 ⏺`
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
}

-- 当前选中的轨道对象(按 state.selectedTrack 索引取);无选中返回 nil。
local function selectedTrackObj()
	local idx = state.selectedTrack:get()
	if not idx then
		return nil
	end
	return state.tracks:get()[idx]
end

-- 面板打开时:确保挂载 + 启动运镜轨迹;关闭时销毁轨迹与内嵌预览。
local function startCameraPath()
	if cameraPath then
		return
	end
	local cp = CameraPath.new()
	cp:rebuild(getCutscene(), selectedTrackObj())
	cameraPath = cp
	-- 机位把手反向编辑:把手被 Studio 移动/旋转工具挪动 → 写回对应关键帧。
	-- 间隔 >1s 的新一轮拖拽压一次 undo;commit 节流,轨迹/朝向杆 0.2s 重画一次。
	local lastHandleEdit = 0
	local lastHandleCommit = 0
	local handleDirty = false
	pathConn = RunService.RenderStepped:Connect(function()
		local ok, err = pcall(function()
			cp:updateHead(getCutscene(), getTime())
			local edits = cp:consumeHandleEdits()
			if #edits > 0 then
				local tr = selectedTrackObj()
				if tr and tr.kind == "camera" and tr.keyframes then
					local now = os.clock()
					if now - lastHandleEdit > 1 then
						state:pushUndo()
					end
					lastHandleEdit = now
					for _, ed in edits do
						local kf = tr.keyframes[ed.kfIndex]
						if kf then
							kf.value = ed.cf
						end
					end
					handleDirty = true
				end
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
end

local function stopCameraPath()
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
		mounted = false -- 面板关了 GUI 被销毁,重开需重挂
	end
end

-- 结构性变更(revision)时刷新预览克隆 + 重画运镜轨迹。
Fusion.Observer(state.revision):onChange(function()
	if embeddedPreview then
		embeddedPreview:refresh()
	end
	if previewWidget.Enabled then
		standalonePreview:refresh()
	end
	if cameraPath then
		cameraPath:rebuild(getCutscene(), selectedTrackObj())
	end
end)

-- 选中轨道变化时:只重画运镜轨迹(不动预览)。
Fusion.Observer(state.selectedTrack):onChange(function()
	if cameraPath then
		cameraPath:rebuild(getCutscene(), selectedTrackObj())
	end
end)

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
		playback:toggle()
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
	stopCameraPath()
	kfAdjust:stop()
	recorder:stop()
	if mainPreview.active then
		mainPreview:stop()
	end
end)

print("[anima] 插件已加载 — 工具栏 Anima ▸ 过场编辑器 / 相机预览")
