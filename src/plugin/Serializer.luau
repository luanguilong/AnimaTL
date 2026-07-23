--!strict
-- Serializer — 把 Cutscene 数据序列化成一个可 require 的 Luau 模块源码字符串。
-- 输出格式与手写的 cutscenes/*.luau 一致(return 一个 Cutscene table)。
-- CFrame 用 12 分量精确还原,round-trip 无损。

local CutsceneFormat = require(script.Parent.Shared.CutsceneFormat)

local Serializer = {}

local function num(n: number): string
	-- 整数省略小数;否则保留精度
	if n == math.floor(n) then
		return string.format("%d", n)
	end
	return string.format("%.6g", n)
end

local function cframe(cf: CFrame): string
	local c = { cf:GetComponents() } -- x,y,z, R00..R22 共 12 个
	local parts = {}
	for _, v in c do
		table.insert(parts, num(v))
	end
	return "CFrame.new(" .. table.concat(parts, ", ") .. ")"
end

local function str(s: string): string
	return string.format("%q", s)
end

local function vector3(v: Vector3): string
	return string.format("Vector3.new(%s, %s, %s)", num(v.X), num(v.Y), num(v.Z))
end

local function keyframe(kf: CutsceneFormat.Keyframe, indent: string): string
	local fields = { "t = " .. num(kf.t) }
	if kf.value then
		table.insert(fields, "value = " .. cframe(kf.value))
	end
	if kf.easing then
		table.insert(fields, "easing = " .. str(kf.easing))
	end
	if kf.outTangent then
		table.insert(fields, "outTangent = " .. vector3(kf.outTangent))
	end
	if kf.inTangent then
		table.insert(fields, "inTangent = " .. vector3(kf.inTangent))
	end
	return indent .. "{ " .. table.concat(fields, ", ") .. " },"
end

local function clip(c: CutsceneFormat.AnimationClip, indent: string): string
	local f = { "animationId = " .. str(c.animationId), "startAt = " .. num(c.startAt) }
	if c.endAt then
		table.insert(f, "endAt = " .. num(c.endAt))
	end
	if c.fadeTime then
		table.insert(f, "fadeTime = " .. num(c.fadeTime))
	end
	if c.speed then
		table.insert(f, "speed = " .. num(c.speed))
	end
	if c.looped ~= nil then
		table.insert(f, "looped = " .. tostring(c.looped))
	end
	if c.rigType then
		table.insert(f, "rigType = " .. str(c.rigType))
	end
	return indent .. "{ " .. table.concat(f, ", ") .. " },"
end

local function event(ev: CutsceneFormat.CutsceneEvent, indent: string): string
	local f = { "t = " .. num(ev.t), "name = " .. str(ev.name) }
	return indent .. "{ " .. table.concat(f, ", ") .. " },"
end

local function soundCue(c: CutsceneFormat.SoundCue, indent: string): string
	local f = { "t = " .. num(c.t), "soundId = " .. str(c.soundId) }
	if c.volume and c.volume ~= 1 then
		table.insert(f, "volume = " .. num(c.volume))
	end
	if c.playbackSpeed and c.playbackSpeed ~= 1 then
		table.insert(f, "playbackSpeed = " .. num(c.playbackSpeed))
	end
	if c.looped then
		table.insert(f, "looped = true")
	end
	if c.maxDistance then
		table.insert(f, "maxDistance = " .. num(c.maxDistance))
	end
	return indent .. "{ " .. table.concat(f, ", ") .. " },"
end

local function effectCue(c: CutsceneFormat.EffectCue, indent: string): string
	local f = { "t = " .. num(c.t) }
	if c.emitMode == "forge" then
		table.insert(f, 'emitMode = "forge"')
	end
	if c.forgeRoot and c.forgeRoot ~= "" then
		table.insert(f, "forgeRoot = " .. str(c.forgeRoot))
	end
	if c.forgeScale and c.forgeScale ~= 1 then
		table.insert(f, "forgeScale = " .. num(c.forgeScale))
	end
	if c.templateName and c.templateName ~= "" then
		table.insert(f, "templateName = " .. str(c.templateName))
	end
	if c.particleAssetId and c.particleAssetId ~= "" then
		table.insert(f, "particleAssetId = " .. str(c.particleAssetId))
	end
	if c.emitCount and c.emitCount ~= 1 then
		table.insert(f, "emitCount = " .. num(c.emitCount))
	end
	if c.duration and c.duration ~= 3 then
		table.insert(f, "duration = " .. num(c.duration))
	end
	return indent .. "{ " .. table.concat(f, ", ") .. " },"
end

local function track(tr: CutsceneFormat.Track, indent: string): string
	local i2 = indent .. "\t"
	local i3 = i2 .. "\t"
	local lines = { indent .. "{" }
	table.insert(lines, i2 .. "kind = " .. str(tr.kind) .. ",")
	table.insert(lines, i2 .. "target = " .. str(tr.target) .. ",")
	if tr.name then
		table.insert(lines, i2 .. "name = " .. str(tr.name) .. ",")
	end
	if tr.group then
		table.insert(lines, i2 .. "group = " .. str(tr.group) .. ",")
	end
	if tr.segments and #tr.segments > 0 then
		table.insert(lines, i2 .. "segments = {")
		for _, s in tr.segments do
			table.insert(lines, i3 .. "{ from = " .. num(s.from) .. ", to = " .. num(s.to) .. " },")
		end
		table.insert(lines, i2 .. "},")
	end
	if tr.from then
		table.insert(lines, i2 .. "from = " .. num(tr.from) .. ",")
	end
	if tr.to then
		table.insert(lines, i2 .. "to = " .. num(tr.to) .. ",")
	end
	if tr.smooth then
		table.insert(lines, i2 .. "smooth = true,")
	end
	if tr.pathMode then
		table.insert(lines, i2 .. "pathMode = " .. str(tr.pathMode) .. ",")
	end
	if tr.followBinding and tr.followBinding ~= "" then
		table.insert(lines, i2 .. "followBinding = " .. str(tr.followBinding) .. ",")
	end
	if tr.followPart and tr.followPart ~= "" and tr.followPart ~= "HumanoidRootPart" then
		table.insert(lines, i2 .. "followPart = " .. str(tr.followPart) .. ",")
	end
	if tr.keyframes and #tr.keyframes > 0 then
		table.insert(lines, i2 .. "keyframes = {")
		for _, kf in tr.keyframes do
			table.insert(lines, keyframe(kf, i3))
		end
		table.insert(lines, i2 .. "},")
	end
	if tr.clips and #tr.clips > 0 then
		table.insert(lines, i2 .. "clips = {")
		for _, c in tr.clips do
			table.insert(lines, clip(c, i3))
		end
		table.insert(lines, i2 .. "},")
	end
	if tr.events and #tr.events > 0 then
		table.insert(lines, i2 .. "events = {")
		for _, ev in tr.events do
			table.insert(lines, event(ev, i3))
		end
		table.insert(lines, i2 .. "},")
	end
	if tr.soundCues and #tr.soundCues > 0 then
		table.insert(lines, i2 .. "soundCues = {")
		for _, c in tr.soundCues do
			table.insert(lines, soundCue(c, i3))
		end
		table.insert(lines, i2 .. "},")
	end
	if tr.effectCues and #tr.effectCues > 0 then
		table.insert(lines, i2 .. "effectCues = {")
		for _, c in tr.effectCues do
			table.insert(lines, effectCue(c, i3))
		end
		table.insert(lines, i2 .. "},")
	end
	table.insert(lines, indent .. "},")
	return table.concat(lines, "\n")
end

-- 序列化为完整模块源码。
function Serializer.serialize(cutscene: CutsceneFormat.Cutscene): string
	local lines = {
		"--!strict",
		"-- 由 Anima 插件生成。",
		"",
		"local cutscene = {",
		"\tname = " .. str(cutscene.name) .. ",",
		"\tduration = " .. num(cutscene.duration) .. ",",
		"\tfps = " .. num(cutscene.fps or 30) .. ",",
		"\ttakeCameraControl = " .. tostring(cutscene.takeCameraControl ~= false) .. ",",
		"\ttracks = {",
	}
	for _, tr in cutscene.tracks do
		table.insert(lines, track(tr, "\t\t"))
	end
	table.insert(lines, "\t},")
	table.insert(lines, "}")
	table.insert(lines, "")
	table.insert(lines, "return cutscene")
	table.insert(lines, "")
	return table.concat(lines, "\n")
end

-- 反序列化:仅用于本插件 Serializer 输出的模块源码(临时 ModuleScript require,不 loadstring 任意脚本)。
function Serializer.deserialize(src: string): CutsceneFormat.Cutscene?
	if src == "" or not string.find(src, "local cutscene", 1, true) then
		return nil
	end
	local scratch = Instance.new("Folder")
	scratch.Name = "AnimaDeserializeScratch"
	scratch.Parent = script.Parent
	local mod = Instance.new("ModuleScript")
	mod.Name = "CutsceneScratch"
	mod.Source = src
	mod.Parent = scratch
	local ok, data = pcall(require, mod)
	scratch:Destroy()
	if not ok or type(data) ~= "table" then
		return nil
	end
	if type(data.duration) ~= "number" or type(data.tracks) ~= "table" then
		return nil
	end
	return data :: CutsceneFormat.Cutscene
end

return Serializer
