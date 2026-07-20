--!strict
-- Recorder — auto-key 录制(scrub-and-pose)。
-- 开启后每帧监测 transform / cameraMove 轨的 target 位姿,变化超阈值就在当前
-- playhead 自动打帧(同一时间覆盖、不重复)。用法:scrub 到某刻 → 在视口摆物体 /
-- 移动相机 gizmo → 自动记录;再 scrub 到别处摆 → 新的一帧。
-- 整段录制算一步撤销(start 时压一次快照)。

local RunService = game:GetService("RunService")

local EditorState = require(script.Parent.EditorState)
local SceneResolver = require(script.Parent.SceneResolver)
local Shared = script.Parent.Shared
local VCam = require(Shared.VCam)
local CutsceneFormat = require(Shared.CutsceneFormat)

local Recorder = {}
Recorder.__index = Recorder

local POS_EPS = 0.02
local ROT_EPS = 0.01

export type Recorder = typeof(setmetatable(
	{} :: {
		state: EditorState.EditorState,
		active: boolean,
		_conn: RBXScriptConnection?,
		_last: { [CutsceneFormat.Track]: CFrame },
	},
	Recorder
))

function Recorder.new(state: EditorState.EditorState): Recorder
	return setmetatable({
		state = state,
		active = false,
		_conn = nil,
		_last = {},
	}, Recorder)
end

-- 某轨道监测的目标实例:transform→场景物体, cameraMove→vcam Part。
local function targetOf(track: CutsceneFormat.Track): Instance?
	if track.kind == "transform" then
		return SceneResolver.resolve(track.target)
	elseif track.kind == "cameraMove" then
		return VCam.find(track.target)
	end
	return nil
end

local function cframeOf(inst: Instance): CFrame?
	if inst:IsA("BasePart") then
		return inst.CFrame
	elseif inst:IsA("Model") then
		local ok, pivot = pcall(function()
			return inst:GetPivot()
		end)
		if ok then
			return pivot
		end
	end
	return nil
end

local function changed(a: CFrame?, b: CFrame): boolean
	if not a then
		return true
	end
	if (a.Position - b.Position).Magnitude > POS_EPS then
		return true
	end
	if (a.LookVector - b.LookVector).Magnitude > ROT_EPS then
		return true
	end
	return false
end

function Recorder.start(self: Recorder)
	if self.active then
		return
	end
	self.active = true
	self._last = {}
	self.state:pushUndo() -- 整段录制算一步撤销
	self._conn = RunService.RenderStepped:Connect(function()
		local ok, err = pcall(function()
			for _, track in self.state.tracks:get() do
				if track.kind == "transform" or track.kind == "cameraMove" then
					local inst = targetOf(track)
					local cf = inst and cframeOf(inst)
					if cf and changed(self._last[track], cf) then
						self._last[track] = cf
						self.state:captureFrameNoUndo(track, cf)
					end
				end
			end
		end)
		if not ok then
			warn("[anima] 录制出错:", err)
		end
	end)
end

function Recorder.stop(self: Recorder)
	self.active = false
	if self._conn then
		self._conn:Disconnect()
		self._conn = nil
	end
	self._last = {}
end

function Recorder.toggle(self: Recorder)
	if self.active then
		self:stop()
	else
		self:start()
	end
end

return Recorder
