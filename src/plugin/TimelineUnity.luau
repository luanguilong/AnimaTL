--!strict
-- TimelineUnity — 对标 Unity Timeline 的轨道/片段/Marker 展示文案与默认命名。
-- 仅 UI 层;不改 CutsceneFormat 运行时语义。

local CutsceneFormat = require(script.Parent.Shared.CutsceneFormat)

local TimelineUnity = {}

export type TrackKind = CutsceneFormat.TrackKind

local DEFAULT_TRACK_NAME: { [string]: string } = {
	animation = "动画轨道",
	transform = "控制轨道",
	camera = "相机轨道",
	cameraMove = "相机运动轨道",
	event = "标记轨道",
	sound = "音效轨道",
	effect = "特效轨道",
	property = "属性轨道",
	rigAnim = "关节动画轨道",
}

-- Unity 轨道类型徽标(字母块,替代 emoji)
local TRACK_BADGE: { [string]: string } = {
	animation = "A",
	transform = "C",
	camera = "V",
	cameraMove = "M",
	event = "•",
	sound = "S",
	effect = "F",
	property = "P",
	rigAnim = "R",
}

function TimelineUnity.defaultTrackName(kind: TrackKind): string
	return DEFAULT_TRACK_NAME[kind] or "Track"
end

function TimelineUnity.trackBadge(kind: string): string
	return TRACK_BADGE[kind] or "?"
end

-- 左列:第一行 = 轨道名(用户 name 优先,否则 Unity 默认轨名)
function TimelineUnity.trackTitle(track: CutsceneFormat.Track): string
	if track.name and track.name ~= "" then
		return track.name
	end
	return TimelineUnity.defaultTrackName(track.kind)
end

-- 左列:第二行 = Binding / 虚拟相机(对标 Unity 绑定槽)
function TimelineUnity.trackBindingLine(track: CutsceneFormat.Track): string
	if track.kind == "camera" then
		local line = "虚拟相机 · " .. track.target
		if track.followBinding and track.followBinding ~= "" then
			line ..= " · 跟随 " .. track.followBinding
		end
		return line
	end
	if track.kind == "cameraMove" then
		return "虚拟相机 · " .. track.target
	end
	if track.kind == "event" then
		return "标记 · " .. track.target
	end
	if track.kind == "property" then
		return "绑定 · " .. track.target .. " · " .. (track.propertyName or "?")
	end
	if track.kind == "rigAnim" then
		return "绑定 · " .. track.target .. " · " .. (#(track.jointTracks or {})) .. " 关节"
	end
	return "绑定 · " .. track.target
end

-- 动画 Clip 条:主标题(优先轨道名,否则 Animation Clip)
function TimelineUnity.clipPrimaryTitle(track: CutsceneFormat.Track, clipIndex: number): string
	local base = if track.name and track.name ~= "" then track.name else "动画片段"
	if track.clips and #track.clips > 1 then
		return base .. " " .. tostring(clipIndex)
	end
	return base
end

function TimelineUnity.clipSecondaryLine(clip: CutsceneFormat.AnimationClip, fps: number?): string
	local id = clip.animationId:match("(%d+)$") or clip.animationId
	local parts: { string } = {}
	if clip.rigType == "R6" or clip.rigType == "R15" then
		table.insert(parts, `[{clip.rigType}]`)
	end
	if clip.endAt then
		local f = math.max(fps or 30, 1)
		local a = math.round(clip.startAt * f)
		local b = math.round(clip.endAt * f)
		table.insert(parts, string.format("%df-%df", a, b))
	end
	if clip.looped then
		table.insert(parts, "循环")
	end
	table.insert(parts, id)
	local speed = clip.speed or 1
	if math.abs(speed - 1) > 0.01 then
		table.insert(parts, string.format("×%.2g", speed))
	end
	return table.concat(parts, " · ")
end

-- 相机段:对标 Cinemachine Shot / Camera Clip
function TimelineUnity.cameraSegmentTitle(track: CutsceneFormat.Track): string
	if track.name and track.name ~= "" then
		return track.name
	end
	return "相机片段"
end

function TimelineUnity.cameraSegmentSubtitle(
	track: CutsceneFormat.Track,
	fromSec: number,
	toSec: number,
	fps: number
): string
	return string.format(
		"%s · %df–%df",
		track.target,
		math.round(fromSec * fps),
		math.round(toSec * fps)
	)
end

-- 标尺:Unity 默认以秒为主,帧为辅
function TimelineUnity.formatRulerMajor(seconds: number, frame: number): string
	if math.abs(seconds - math.round(seconds)) < 0.001 then
		return string.format("%ds  %df", math.round(seconds), frame)
	end
	return string.format("%.2fs  %df", seconds, frame)
end

function TimelineUnity.markerTooltip(ev: CutsceneFormat.CutsceneEvent, fps: number): string
	return string.format("%s @ %df", ev.name, math.round(ev.t * fps))
end

return TimelineUnity
