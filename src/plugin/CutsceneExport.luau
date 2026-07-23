--!strict
-- CutsceneExport — 将过场写入 ReplicatedStorage.Anima.Cutscenes[/<子路径>]/<模块名>。

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CutsceneFormat = require(script.Parent.Shared.CutsceneFormat)
local Serializer = require(script.Parent.Serializer)

local CutsceneExport = {}

local TIME_EPS = 1e-4

local function trim(raw: string): string
	local s = string.gsub(raw or "", "^%s+", "")
	return string.gsub(s, "%s+$", "")
end

-- 导出区间输入:留空=defaultSec;整数=帧;含小数=秒(再量化到 1/fps)。
function CutsceneExport.parseExportTimeInput(raw: string, fps: number, defaultSec: number): number?
	local t = trim(raw)
	if t == "" then
		return defaultSec
	end
	local n = tonumber(t)
	if n == nil then
		return nil
	end
	local f = math.max(fps, 1)
	if string.find(t, "%.") then
		return math.round(n * f) / f
	end
	return math.round(n) / f
end

local function cloneKeyframe(kf: CutsceneFormat.Keyframe): CutsceneFormat.Keyframe
	return {
		t = kf.t,
		value = kf.value,
		easing = kf.easing,
		outTangent = kf.outTangent,
		inTangent = kf.inTangent,
	}
end

local function inClosedRange(t: number, fromSec: number, toSec: number): boolean
	return t + TIME_EPS >= fromSec and t <= toSec + TIME_EPS
end

local function sliceKeyframesCamera(
	track: CutsceneFormat.Track,
	fromSec: number,
	toSec: number
): { CutsceneFormat.Keyframe }?
	if not track.keyframes then
		return nil
	end
	local isCam = track.kind == "camera" or track.kind == "cameraMove"
	local predecessor: CutsceneFormat.Keyframe? = nil
	local hasExactStart = false
	local sliced: { CutsceneFormat.Keyframe } = {}

	for _, kf in track.keyframes do
		if kf.t < fromSec - TIME_EPS then
			if isCam and (not predecessor or kf.t > predecessor.t) then
				predecessor = kf
			end
		end
		if inClosedRange(kf.t, fromSec, toSec) then
			local copy = cloneKeyframe(kf)
			copy.t = kf.t - fromSec
			table.insert(sliced, copy)
			if math.abs(kf.t - fromSec) <= TIME_EPS then
				hasExactStart = true
			end
		end
	end

	if isCam and not hasExactStart and predecessor then
		local anchor = cloneKeyframe(predecessor)
		anchor.t = 0
		table.insert(sliced, anchor)
	end

	table.sort(sliced, function(a, b)
		return a.t < b.t
	end)

	if #sliced == 0 then
		return {}
	end
	return sliced
end

local function sliceKeyframesPlain(
	keyframes: { CutsceneFormat.Keyframe }?,
	fromSec: number,
	toSec: number
): { CutsceneFormat.Keyframe }?
	if not keyframes then
		return nil
	end
	local sliced: { CutsceneFormat.Keyframe } = {}
	for _, kf in keyframes do
		if inClosedRange(kf.t, fromSec, toSec) then
			local copy = cloneKeyframe(kf)
			copy.t = kf.t - fromSec
			table.insert(sliced, copy)
		end
	end
	if #sliced == 0 then
		return {}
	end
	return sliced
end

local function sliceTimedList<T>(
	items: { T }?,
	fromSec: number,
	toSec: number,
	getT: (T) -> number,
	setT: (T, number) -> T
): { T }?
	if not items then
		return nil
	end
	local out: { T } = {}
	for _, item in items do
		local t = getT(item)
		if inClosedRange(t, fromSec, toSec) then
			local copy = table.clone(item) :: T
			setT(copy, t - fromSec)
			table.insert(out, copy)
		end
	end
	if #out == 0 then
		return {}
	end
	return out
end

local function sliceClips(
	clips: { CutsceneFormat.AnimationClip }?,
	fromSec: number,
	toSec: number,
	warnings: { string }
): { CutsceneFormat.AnimationClip }?
	if not clips then
		return nil
	end
	local out: { CutsceneFormat.AnimationClip } = {}
	for _, clip in clips do
		local endT = CutsceneFormat.clipTimelineEnd(clip, nil, nil)
		if endT <= fromSec + TIME_EPS or clip.startAt >= toSec - TIME_EPS then
			continue
		end
		local newStart = math.max(clip.startAt, fromSec)
		local newEnd = math.min(endT, toSec)
		if newEnd <= newStart + TIME_EPS then
			continue
		end
		if clip.startAt < fromSec - TIME_EPS then
			table.insert(
				warnings,
				`[anima] 导出区间:动画 clip 自 {clip.animationId} 从中间切入,运行时将仍从动画第 0 帧开播`
			)
		end
		local copy = table.clone(clip)
		copy.startAt = newStart - fromSec
		copy.endAt = newEnd - fromSec
		table.insert(out, copy)
	end
	if #out == 0 then
		return {}
	end
	return out
end

local function sliceSegments(
	track: CutsceneFormat.Track,
	fromSec: number,
	toSec: number
): { CutsceneFormat.CameraSegment }?
	local src = CutsceneFormat.segmentsOf(track)
	if #src == 0 then
		return nil
	end
	local out: { CutsceneFormat.CameraSegment } = {}
	for _, s in src do
		local newFrom = math.max(s.from, fromSec)
		local newTo = math.min(s.to, toSec)
		if newTo > newFrom + TIME_EPS then
			table.insert(out, {
				from = newFrom - fromSec,
				to = newTo - fromSec,
			})
		end
	end
	if #out == 0 then
		return {}
	end
	return out
end

local function sliceTrack(
	track: CutsceneFormat.Track,
	fromSec: number,
	toSec: number,
	warnings: { string }
): CutsceneFormat.Track
	local out = table.clone(track)
	out.from = nil
	out.to = nil

	local segs = sliceSegments(track, fromSec, toSec)
	if segs ~= nil then
		out.segments = segs
	end

	if track.kind == "camera" or track.kind == "cameraMove" then
		out.keyframes = sliceKeyframesCamera(track, fromSec, toSec)
	else
		out.keyframes = sliceKeyframesPlain(track.keyframes, fromSec, toSec)
	end

	out.clips = sliceClips(track.clips, fromSec, toSec, warnings)

	out.events = sliceTimedList(track.events, fromSec, toSec, function(ev)
		return ev.t
	end, function(ev, t)
		ev.t = t
		return ev
	end)

	out.soundCues = sliceTimedList(track.soundCues, fromSec, toSec, function(c)
		return c.t
	end, function(c, t)
		c.t = t
		return c
	end)

	out.effectCues = sliceTimedList(track.effectCues, fromSec, toSec, function(c)
		return c.t
	end, function(c, t)
		c.t = t
		return c
	end)

	return out
end

-- 导出前裁剪过场:[fromSec, toSec] 闭区间,片内时间 rebasing 到 0。不修改入参。
function CutsceneExport.slice(
	cutscene: CutsceneFormat.Cutscene,
	fromSec: number,
	toSec: number
): (CutsceneFormat.Cutscene, { string })
	local fps = math.max(cutscene.fps or 30, 1)
	local function q(sec: number): number
		return math.round(sec * fps) / fps
	end
	fromSec = q(fromSec)
	toSec = q(toSec)

	local warnings: { string } = {}
	local out: CutsceneFormat.Cutscene = {
		name = cutscene.name,
		duration = math.max(0, toSec - fromSec),
		tracks = {},
		fps = cutscene.fps,
		takeCameraControl = cutscene.takeCameraControl,
	}

	for _, tr in cutscene.tracks do
		table.insert(out.tracks, sliceTrack(tr, fromSec, toSec, warnings))
	end

	return out, warnings
end

function CutsceneExport.formatExportRangeLog(
	fromSec: number,
	toSec: number,
	fps: number,
	outDuration: number
): string
	local f = math.max(fps, 1)
	local fromF = math.round(fromSec * f)
	local toF = math.round(toSec * f)
	return string.format(
		"[anima] 导出区间: %df–%df (%.2fs–%.2fs), duration=%.2fs",
		fromF,
		toF,
		fromSec,
		toSec,
		outDuration
	)
end

local ROOT_FOLDER = "Anima"
local CUTSCENES_FOLDER = "Cutscenes"

local function sanitizeSegment(raw: string): string
	local s = string.gsub(raw, "^%s+", "")
	s = string.gsub(s, "%s+$", "")
	s = string.gsub(s, "[/\\]+", "")
	s = string.gsub(s, "%.%.", "")
	if s == "" then
		return ""
	end
	return s
end

function CutsceneExport.parseSubPath(raw: string): { string }
	local trimmed = string.gsub(raw or "", "^%s+", "")
	trimmed = string.gsub(trimmed, "%s+$", "")
	trimmed = string.gsub(trimmed, "\\", "/")
	if trimmed == "" or trimmed == "/" then
		return {}
	end
	local segments: { string } = {}
	for seg in string.split(trimmed, "/") do
		local clean = sanitizeSegment(seg)
		if clean ~= "" then
			table.insert(segments, clean)
		end
	end
	return segments
end

local function ensureAnimaCutscenesRoot(): Folder
	local anima = ReplicatedStorage:FindFirstChild(ROOT_FOLDER)
	if not anima then
		anima = Instance.new("Folder")
		anima.Name = ROOT_FOLDER
		anima.Parent = ReplicatedStorage
	end
	local cutscenes = anima:FindFirstChild(CUTSCENES_FOLDER)
	if not cutscenes then
		cutscenes = Instance.new("Folder")
		cutscenes.Name = CUTSCENES_FOLDER
		cutscenes.Parent = anima
	end
	return cutscenes :: Folder
end

local function ensureFolderPath(root: Folder, segments: { string }): Folder
	local cur: Instance = root
	for _, seg in segments do
		local nextInst = cur:FindFirstChild(seg)
		if not nextInst then
			local f = Instance.new("Folder")
			f.Name = seg
			f.Parent = cur
			nextInst = f
		elseif not nextInst:IsA("Folder") then
			error(`[anima] 导出路径被占用: {cur:GetFullName()}.{seg} 不是 Folder`)
		end
		cur = nextInst
	end
	return cur :: Folder
end

-- 返回 ModuleScript 与 require 路径说明(点分,供程序 require)。
function CutsceneExport.writeModule(
	cutscene: CutsceneFormat.Cutscene,
	subPath: string,
	moduleName: string
): (ModuleScript, string)
	local name = sanitizeSegment(moduleName)
	if name == "" then
		error("[anima] 模块名无效")
	end
	local segments = CutsceneExport.parseSubPath(subPath)
	local root = ensureAnimaCutscenesRoot()
	local parent = ensureFolderPath(root, segments)

	local existing = parent:FindFirstChild(name)
	local mod: ModuleScript
	if existing and existing:IsA("ModuleScript") then
		mod = existing
	else
		if existing then
			error(`[anima] 无法创建模块 {name}: 同名非 ModuleScript 已存在`)
		end
		mod = Instance.new("ModuleScript")
		mod.Name = name
		mod.Parent = parent
	end

	local data = table.clone(cutscene)
	data.name = name
	mod.Source = Serializer.serialize(data)

	local pathParts = { "ReplicatedStorage", ROOT_FOLDER, CUTSCENES_FOLDER }
	for _, seg in segments do
		table.insert(pathParts, seg)
	end
	table.insert(pathParts, name)
	local instancePath = table.concat(pathParts, ".")
	local requirePath = ROOT_FOLDER .. "." .. CUTSCENES_FOLDER
	for _, seg in segments do
		requirePath ..= "." .. seg
	end
	requirePath ..= "." .. name
	return mod, requirePath
end

function CutsceneExport.writeAnimaExportString(src: string)
	local holder = ReplicatedStorage:FindFirstChild("AnimaExport")
	if not holder then
		holder = Instance.new("StringValue")
		holder.Name = "AnimaExport"
		holder.Parent = ReplicatedStorage
	end
	(holder :: StringValue).Value = src
end

-- 建议的磁盘路径(Rojo / Git),不含 .luau 以外的约束。
function CutsceneExport.suggestedFilePath(subPath: string, moduleName: string): string
	local name = sanitizeSegment(moduleName)
	local segments = CutsceneExport.parseSubPath(subPath)
	local parts = { "cutscenes" }
	for _, seg in segments do
		table.insert(parts, seg)
	end
	table.insert(parts, name .. ".luau")
	return table.concat(parts, "/")
end

return CutsceneExport
