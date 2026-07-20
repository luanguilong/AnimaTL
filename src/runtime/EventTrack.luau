--!strict
-- EventTrack — 到达事件时间点时触发一次具名回调(音效、粒子、切镜等)。
-- 事件的实际效果由调用方注册的 handler 决定,运行时只负责"到点触发一次"。

local CutsceneFormat = require(script.Parent.Parent.Shared.CutsceneFormat)

local EventTrack = {}
EventTrack.__index = EventTrack

export type EventHandler = (event: CutsceneFormat.CutsceneEvent, target: Instance?) -> ()

export type EventTrack = typeof(setmetatable(
	{} :: {
		events: { CutsceneFormat.CutsceneEvent },
		target: Instance?,
		handler: EventHandler,
		_fired: { [number]: boolean }, -- index -> 是否已触发
	},
	EventTrack
))

function EventTrack.new(
	track: CutsceneFormat.Track,
	target: Instance?,
	handler: EventHandler
): EventTrack
	return setmetatable({
		events = track.events or {},
		target = target,
		handler = handler,
		_fired = {},
	}, EventTrack)
end

-- 推进到时间 t:触发所有 t 已越过且尚未触发的事件。
-- 支持时间跳跃(seek):会补发被跨过的事件。
function EventTrack.update(self: EventTrack, t: number)
	for i, event in self.events do
		if not self._fired[i] and t >= event.t then
			self._fired[i] = true
			self.handler(event, self.target)
		end
	end
end

-- 重置触发状态(过场重播前)。
function EventTrack.reset(self: EventTrack)
	self._fired = {}
end

return EventTrack
