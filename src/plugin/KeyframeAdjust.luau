--!strict
-- KeyframeAdjust — 视口对帧调整(机位反向编辑,所见即所得)。
--
-- 针对相机类关键帧(camera / cameraMove 轨):进入后把视口相机跳进该帧视角,
-- 用户用 Studio 正常导航自由取景 —— 取景框里看到的就是这一帧的最终构图,
-- 每帧把视口相机 CFrame 写回该关键帧(直接改引用,实时求值立即生效);
-- commitTracks 节流提交,CameraPath 轨迹随 revision 实时重画。
-- 整段调整算一步撤销(进入时压一次快照);undo/删帧导致引用失效时自动退出。

local RunService = game:GetService("RunService")

local Fusion = require(script.Parent.Packages.Fusion)
local EditorState = require(script.Parent.EditorState)
local CutsceneFormat = require(script.Parent.Shared.CutsceneFormat)
local FollowAnchor = require(script.Parent.Shared.FollowAnchor)
local SceneResolver = require(script.Parent.SceneResolver)

local KeyframeAdjust = {}
KeyframeAdjust.__index = KeyframeAdjust

local POS_EPS = 0.02
local ROT_EPS = 0.01
local COMMIT_INTERVAL = 0.2 -- 轨迹线重画节流(秒)

export type KeyframeAdjust = typeof(setmetatable(
	{} :: {
		state: EditorState.EditorState,
		current: Fusion.Value<CutsceneFormat.Keyframe?>, -- 正在调整的关键帧(供 UI)
		_track: CutsceneFormat.Track?,
		_conn: RBXScriptConnection?,
		_lastCF: CFrame?,
		_dirty: boolean,
		_lastCommit: number,
	},
	KeyframeAdjust
))

function KeyframeAdjust.new(state: EditorState.EditorState): KeyframeAdjust
	return setmetatable({
		state = state,
		current = Fusion.Value(nil :: CutsceneFormat.Keyframe?),
		_track = nil :: CutsceneFormat.Track?,
		_conn = nil :: RBXScriptConnection?,
		_lastCF = nil :: CFrame?,
		_dirty = false,
		_lastCommit = 0,
	}, KeyframeAdjust)
end

-- kf 引用是否仍在轨道里(undo / 删帧会换表,失效即自动退出)。
local function stillAlive(self: KeyframeAdjust, kf: CutsceneFormat.Keyframe): boolean
	local track = self._track
	if not track or not track.keyframes then
		return false
	end
	for _, k in track.keyframes do
		if k == kf then
			return true
		end
	end
	return false
end

local function moved(a: CFrame?, b: CFrame): boolean
	if not a then
		return true
	end
	-- UpVector 一并比较,绕镜头轴的纯滚转(dutch angle)才检测得到
	return (a.Position - b.Position).Magnitude > POS_EPS
		or (a.LookVector - b.LookVector).Magnitude > ROT_EPS
		or (a.UpVector - b.UpVector).Magnitude > ROT_EPS
end

function KeyframeAdjust.start(
	self: KeyframeAdjust,
	track: CutsceneFormat.Track,
	kf: CutsceneFormat.Keyframe
)
	self:stop()
	local cam = workspace.CurrentCamera
	if not cam or not kf.value then
		return
	end
	self.state:pushUndo() -- 整段调整一步撤销
	self.state:setTime(kf.t) -- 播放头定位到该帧
	local viewCf = if track.kind == "camera"
		then FollowAnchor.worldFromKeyframeCFrame(track, kf.value, SceneResolver.resolve)
		else kf.value
	cam.CFrame = viewCf -- 跳进该帧视角
	self._track = track
	self._lastCF = viewCf
	self._dirty = false
	self._lastCommit = os.clock()
	self.current:set(kf)
	self._conn = RunService.RenderStepped:Connect(function()
		if not stillAlive(self, kf) then
			self:stop()
			return
		end
		local c = workspace.CurrentCamera
		if not c then
			return
		end
		local cf = c.CFrame
		if moved(self._lastCF, cf) then
			self._lastCF = cf
			local track = self._track
			if track and track.kind == "camera" then
				kf.value = FollowAnchor.storeKeyframeCFrame(track, cf, SceneResolver.resolve)
			else
				kf.value = cf
			end
			self._dirty = true
		end
		if self._dirty and os.clock() - self._lastCommit >= COMMIT_INTERVAL then
			self._dirty = false
			self._lastCommit = os.clock()
			self.state:commitTracks(true) -- +revision → CameraPath 重画
		end
	end)
end

function KeyframeAdjust.stop(self: KeyframeAdjust)
	if self._conn then
		self._conn:Disconnect()
		self._conn = nil
	end
	if self._dirty then
		self._dirty = false
		self.state:commitTracks(true)
	end
	self._track = nil
	self.current:set(nil)
end

-- 再次对同一帧调用 = 结束;对别的帧调用 = 切换过去。
function KeyframeAdjust.toggle(
	self: KeyframeAdjust,
	track: CutsceneFormat.Track,
	kf: CutsceneFormat.Keyframe
)
	if self.current:get() == kf then
		self:stop()
	else
		self:start(track, kf)
	end
end

return KeyframeAdjust
