--!strict
-- ScreenTrack — 演出轨(22 spec):每帧用 shared/ScreenSampler 纯求值,写入 ScreenOverlay。
-- 求值与插件 scrub 预览共用同一套代码(所见即所得);seek / 迟到进场 / 重播天然一致。

local CutsceneFormat = require(script.Parent.Parent.Shared.CutsceneFormat)
local ScreenSampler = require(script.Parent.Parent.Shared.ScreenSampler)
local ScreenOverlay = require(script.Parent.ScreenOverlay)

local ScreenTrack = {}
ScreenTrack.__index = ScreenTrack

export type ScreenTrack = typeof(setmetatable(
	{} :: {
		cues: { CutsceneFormat.ScreenCue },
		overlay: ScreenOverlay.ScreenOverlay,
		_activeSplash: { [string]: boolean },
	},
	ScreenTrack
))

function ScreenTrack.new(
	track: CutsceneFormat.Track,
	overlay: ScreenOverlay.ScreenOverlay
): ScreenTrack
	return setmetatable({
		cues = track.screenCues or {},
		overlay = overlay,
		_activeSplash = {},
	}, ScreenTrack)
end

function ScreenTrack.update(self: ScreenTrack, t: number)
	local overlay = self.overlay
	local s = ScreenSampler.sample(self.cues, t)

	overlay:setFade(s.fadeAlpha, s.fadeColor)
	overlay:setLetterbox(s.letterbox)
	overlay:setTint(s.tintIntensity, s.tintColor, s.tintSaturation)

	local nowActive: { [string]: boolean } = {}
	for _, sp in s.splashes do
		nowActive[sp.key] = true
		overlay:ensureSplashes(sp.key, sp.seed, sp.count, sp.imageId)
		overlay:setSplashAlpha(sp.key, sp.alpha)
	end
	-- 出窗口的 splash 销毁
	for key in self._activeSplash do
		if not nowActive[key] then
			overlay:clearSplashes(key)
		end
	end
	self._activeSplash = nowActive
end

-- 归零(不销毁 overlay;overlay 生命周期归 CutscenePlayer 管)。
function ScreenTrack.reset(self: ScreenTrack)
	local overlay = self.overlay
	overlay:setFade(1)
	overlay:setLetterbox(0)
	overlay:setTint(0)
	for key in self._activeSplash do
		overlay:clearSplashes(key)
	end
	self._activeSplash = {}
end

return ScreenTrack
