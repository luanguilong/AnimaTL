--!strict
-- Playback — 按真实时间推进播放头(▶/⏸/🔁)。
-- 只驱动 state.currentTime;预览窗口与主视口预览各自观察 currentTime 更新。

local RunService = game:GetService("RunService")
local Fusion = require(script.Parent.Packages.Fusion)
local EditorState = require(script.Parent.EditorState)

local Value = Fusion.Value

local Playback = {}
Playback.__index = Playback

export type Playback = typeof(setmetatable(
	{} :: {
		state: EditorState.EditorState,
		isPlaying: Fusion.Value<boolean>,
		loop: Fusion.Value<boolean>,
		_conn: RBXScriptConnection?,
	},
	Playback
))

function Playback.new(state: EditorState.EditorState): Playback
	return setmetatable({
		state = state,
		isPlaying = Value(false),
		loop = Value(false),
		_conn = nil,
	}, Playback)
end

function Playback.play(self: Playback)
	if self.isPlaying:get() then
		return
	end
	self.isPlaying:set(true)
	self._conn = RunService.RenderStepped:Connect(function(dt: number)
		local dur = self.state.duration:get()
		local t = self.state.currentTime:get() + dt
		if t >= dur then
			if self.loop:get() then
				t = t - dur
			else
				t = dur
				self:pause()
			end
		end
		self.state:setTime(t)
	end)
end

function Playback.pause(self: Playback)
	if not self.isPlaying:get() then
		return
	end
	self.isPlaying:set(false)
	if self._conn then
		self._conn:Disconnect()
		self._conn = nil
	end
end

function Playback.toggle(self: Playback)
	if self.isPlaying:get() then
		self:pause()
	else
		-- 到末尾再点播放则从头开始
		if self.state.currentTime:get() >= self.state.duration:get() then
			self.state:setTime(0)
		end
		self:play()
	end
end

function Playback.toStart(self: Playback)
	self.state:setTime(0)
end

function Playback.toggleLoop(self: Playback)
	self.loop:set(not self.loop:get())
end

return Playback
