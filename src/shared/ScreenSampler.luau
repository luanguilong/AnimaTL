--!strict
-- ScreenSampler — 演出轨(22 spec)纯求值:cues + t → 屏幕状态。
-- 运行时 ScreenTrack 与插件 scrub 预览共用(所见即所得);全按 t 纯函数,seek/重播一致。

local CutsceneFormat = require(script.Parent.CutsceneFormat)
local Easing = require(script.Parent.Easing)

local ScreenSampler = {}

export type SplashState = {
	key: string, -- "splash_<cue下标>"
	seed: number,
	count: number,
	imageId: string,
	alpha: number, -- ImageTransparency(1 = 不可见)
}

export type ScreenState = {
	fadeAlpha: number, -- 遮罩 BackgroundTransparency(1 = 全透)
	fadeColor: Color3?,
	letterbox: number, -- 单边黑边高占比
	tintIntensity: number, -- 0..1
	tintColor: Color3?,
	tintSaturation: number?,
	splashes: { SplashState }, -- 仅窗口内的 cue
}

local function durOf(cue: CutsceneFormat.ScreenCue): number
	return math.max(cue.duration or 1, 0.001)
end

local function easedProgress(cue: CutsceneFormat.ScreenCue, t: number): number
	local p = math.clamp((t - cue.t) / durOf(cue), 0, 1)
	return Easing.apply(cue.easing or "quadOut", p)
end

-- fade / letterbox 共用:取 t 之前(含)最近一条该类 cue 做插值;from 缺省 = 上一条的 to。
local function sampleLevel(
	cues: { CutsceneFormat.ScreenCue },
	kind: CutsceneFormat.ScreenCueKind,
	t: number,
	restValue: number
): (number, CutsceneFormat.ScreenCue?)
	local current: CutsceneFormat.ScreenCue? = nil
	local prevTo = restValue
	for _, cue in cues do
		if cue.kind == kind and cue.t <= t then
			if current then
				prevTo = (current :: CutsceneFormat.ScreenCue).to or prevTo
			end
			current = cue
		end
	end
	if not current then
		return restValue, nil
	end
	local cue = current :: CutsceneFormat.ScreenCue
	local from = cue.from or prevTo
	local to = cue.to or restValue
	return from + (to - from) * easedProgress(cue, t), cue
end

-- 攻-保持-回落包络:窗口 [cue.t, cue.t+duration],hold 居中,两侧各半攻/落。返回 0..1。
local function envelope(cue: CutsceneFormat.ScreenCue, t: number, holdSec: number): number
	local dur = durOf(cue)
	local rel = t - cue.t
	if rel < 0 or rel > dur then
		return 0
	end
	local hold = math.clamp(holdSec, 0, dur)
	local ramp = (dur - hold) / 2
	if ramp <= 0 then
		return 1
	end
	if rel < ramp then
		return Easing.apply(cue.easing or "quadOut", rel / ramp)
	end
	if rel > dur - ramp then
		return Easing.apply(cue.easing or "quadOut", (dur - rel) / ramp)
	end
	return 1
end

-- splash 贴图布点(22 spec):伪随机必须可重播一致——种子取 cue 下标,禁 math.random。
-- 运行时 ScreenOverlay 与插件 ScreenFxPreview 共用本函数,保证两边布点逐像素一致。
export type SplashSlot = {
	x: number, -- 屏幕比例坐标 0..1
	y: number,
	size: number, -- RelativeYY 比例
	rotation: number, -- 度
}

local function seededUnit(seed: number): number
	local x = math.sin(seed * 127.1 + 311.7) * 43758.5453
	return x - math.floor(x)
end

function ScreenSampler.splashLayout(seed: number, count: number): { SplashSlot }
	local slots: { SplashSlot } = {}
	for i = 1, count do
		local s = seed * 31 + i * 7
		-- 沿屏幕四周分布:随机取一条边,再沿边随机偏移
		local edge = math.floor(seededUnit(s) * 4) -- 0..3 = 上/下/左/右
		local along = 0.1 + seededUnit(s + 1) * 0.8
		local depth = seededUnit(s + 2) * 0.15 -- 距边缘深度
		local x, y
		if edge == 0 then
			x, y = along, depth
		elseif edge == 1 then
			x, y = along, 1 - depth
		elseif edge == 2 then
			x, y = depth, along
		else
			x, y = 1 - depth, along
		end
		table.insert(slots, {
			x = x,
			y = y,
			size = 0.25 + seededUnit(s + 3) * 0.25,
			rotation = seededUnit(s + 4) * 360,
		})
	end
	return slots
end

function ScreenSampler.sample(cues: { CutsceneFormat.ScreenCue }, t: number): ScreenState
	-- fade:cue 的 from/to 描述遮罩不透明度 0..1;转成 Transparency = 1 - level
	local fadeLevel, fadeCue = sampleLevel(cues, "fade", t, 0)
	local boxLevel = sampleLevel(cues, "letterbox", t, 0)

	-- tint:多条并发取强度最大的一条上镜
	local bestIntensity = 0
	local bestCue: CutsceneFormat.ScreenCue? = nil
	for _, cue in cues do
		if cue.kind == "tint" then
			local i = envelope(cue, t, cue.hold or 0)
			if i > bestIntensity then
				bestIntensity, bestCue = i, cue
			end
		end
	end

	local splashes: { SplashState } = {}
	for i, cue in cues do
		if cue.kind ~= "splash" then
			continue
		end
		local dur = durOf(cue)
		local imageId = cue.imageId
		if imageId and imageId ~= "" and t >= cue.t and t <= cue.t + dur then
			local holdSec = dur * math.clamp(cue.holdRatio or 0.3, 0, 1)
			table.insert(splashes, {
				key = "splash_" .. tostring(i),
				seed = i,
				count = math.max(cue.count or 3, 1),
				imageId = imageId,
				alpha = 1 - envelope(cue, t, holdSec),
			})
		end
	end

	return {
		fadeAlpha = 1 - fadeLevel,
		fadeColor = if fadeCue then fadeCue.color else nil,
		letterbox = boxLevel,
		tintIntensity = bestIntensity,
		tintColor = if bestCue then bestCue.tintColor else nil,
		tintSaturation = if bestCue then bestCue.saturation else nil,
		splashes = splashes,
	}
end

return ScreenSampler
