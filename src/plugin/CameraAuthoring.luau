--!strict
-- CameraAuthoring — 选中 camera 轨时的「视口 A」透视编辑。
-- 进入:Custom + VCam.resolvePose 一次,不随 playhead 插值写主视口。
-- 与 LivePreview / Playback / KeyframeAdjust / 录制互斥;逻辑集中在此,不污染 LivePreview。

local Selection = game:GetService("Selection")

local Fusion = require(script.Parent.Packages.Fusion)
local EditorState = require(script.Parent.EditorState)
local LivePreview = require(script.Parent.LivePreview)
local Playback = require(script.Parent.Playback)
local KeyframeAdjust = require(script.Parent.KeyframeAdjust)
local Recorder = require(script.Parent.Recorder)
local CutsceneFormat = require(script.Parent.Shared.CutsceneFormat)
local VCam = require(script.Parent.Shared.VCam)

local CameraAuthoring = {}
CameraAuthoring.__index = CameraAuthoring

export type Deps = {
	mainPreview: LivePreview.LivePreview,
	mainPreviewActive: Fusion.Value<boolean>,
	playback: Playback.Playback,
	kfAdjust: KeyframeAdjust.KeyframeAdjust,
	recorder: Recorder.Recorder,
	recordingCam: Fusion.Value<string?>,
}

export type CameraAuthoring = typeof(setmetatable(
	{} :: {
		_deps: Deps,
		authoringVcam: Fusion.Value<string?>,
		authoringMode: Fusion.Value<boolean>,
		_active: boolean,
		_vcam: string?,
		_savedType: Enum.CameraType?,
	},
	CameraAuthoring
))

function CameraAuthoring.new(deps: Deps): CameraAuthoring
	return setmetatable({
		_deps = deps,
		authoringVcam = Fusion.Value(nil :: string?),
		authoringMode = Fusion.Value(false),
		_active = false,
		_vcam = nil,
		_savedType = nil,
	}, CameraAuthoring)
end

function CameraAuthoring.isActive(self: CameraAuthoring): boolean
	return self._active
end

function CameraAuthoring.exit(self: CameraAuthoring, _reason: string?)
	if not self._active then
		return
	end
	self._active = false
	self._vcam = nil
	self.authoringVcam:set(nil)
	self.authoringMode:set(false)
	local cam = workspace.CurrentCamera
	if cam and not self._deps.mainPreview.active then
		cam.CameraType = self._savedType or Enum.CameraType.Custom
	end
	self._savedType = nil
end

local function stopConflicts(self: CameraAuthoring): boolean
	local deps = self._deps
	local stoppedFollow = false
	if deps.mainPreview.active then
		deps.mainPreview:stop()
		deps.mainPreviewActive:set(false)
		stoppedFollow = true
	end
	if deps.playback.isPlaying:get() then
		deps.playback:pause()
	end
	deps.kfAdjust:stop()
	if deps.recorder.active then
		deps.recorder:stop()
		print("[anima] 已退出 Record 录制,进入相机轨透视编辑")
	end
	if deps.recordingCam:get() then
		deps.recordingCam:set(nil)
		print("[anima] 已结束相机轨 ⏺ 录制,进入透视编辑")
	end
	return stoppedFollow
end

function CameraAuthoring.enter(self: CameraAuthoring, vcamName: string)
	if vcamName == "" then
		self:exit()
		return
	end
	if self._active and self._vcam == vcamName then
		return
	end

	local stoppedFollow = stopConflicts(self)
	if stoppedFollow then
		print("[anima] 已关闭主视口跟随,进入相机轨透视编辑")
	end

	local cam = workspace.CurrentCamera
	if not cam then
		return
	end

	if not self._active then
		self._savedType = cam.CameraType
	end

	local cf = VCam.resolvePose(vcamName)
	if not cf then
		warn(`[anima] 透视编辑:找不到 vcam '{vcamName}' 或无法解析位姿`)
	else
		cam.CameraType = Enum.CameraType.Custom
		cam.CFrame = cf
	end

	local part = VCam.find(vcamName)
	if part then
		Selection:Set({ part })
	end

	self._active = true
	self._vcam = vcamName
	self.authoringVcam:set(vcamName)
	self.authoringMode:set(true)
end

-- 双击关键帧等:主视口跳到指定位姿并进入/保持透视 A,便于 WASD 微调后 K 打帧。
function CameraAuthoring.snapViewport(self: CameraAuthoring, vcamName: string, cf: CFrame)
	if vcamName == "" then
		return
	end
	local stoppedFollow = stopConflicts(self)
	if stoppedFollow then
		print("[anima] 已关闭主视口跟随,进入相机轨透视编辑")
	end
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	if not self._active then
		self._savedType = cam.CameraType
	end
	cam.CameraType = Enum.CameraType.Custom
	cam.CFrame = cf
	local part = VCam.find(vcamName)
	if part then
		Selection:Set({ part })
	end
	self._active = true
	self._vcam = vcamName
	self.authoringVcam:set(vcamName)
	self.authoringMode:set(true)
end

function CameraAuthoring.syncFromTrack(self: CameraAuthoring, track: CutsceneFormat.Track?)
	if
		track
		and (track.kind == "camera" or track.kind == "cameraMove")
		and track.target
		and track.target ~= ""
	then
		self:enter(track.target)
	else
		self:exit()
	end
end

-- 绑定 selectedTrack / 播放状态;主视口跟随关闭后若仍选中 camera 轨则恢复 A。
function CameraAuthoring.bind(
	self: CameraAuthoring,
	state: EditorState.EditorState,
	getSelectedTrack: () -> CutsceneFormat.Track?
)
	Fusion.Observer(state.selectedTrack):onChange(function()
		self:syncFromTrack(getSelectedTrack())
	end)

	Fusion.Observer(self._deps.playback.isPlaying):onChange(function()
		if self._deps.playback.isPlaying:get() then
			self:exit("播放")
		elseif not self._deps.mainPreview.active then
			self:syncFromTrack(getSelectedTrack())
		end
	end)
end

return CameraAuthoring
