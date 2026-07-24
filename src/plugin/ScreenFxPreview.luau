--!strict
-- ScreenFxPreview — 演出轨 scrub 简化预览(22 spec ⚠️ 声明):
-- 求值走 shared/ScreenSampler(与运行时同源),但呈现是近似——插件画不进 PlayerGui,
-- 改画 CoreGui:fade/黑边用 Frame;tint 用半透明色框近似(不碰 Lighting);splash 出真图。
-- 真实效果以 Play 模式为准。

local CoreGui = game:GetService("CoreGui")

local CutsceneFormat = require(script.Parent.Shared.CutsceneFormat)
local ScreenSampler = require(script.Parent.Shared.ScreenSampler)

local ScreenFxPreview = {}

local _gui: ScreenGui? = nil
local _fade: Frame? = nil
local _letterTop: Frame? = nil
local _letterBottom: Frame? = nil
local _tint: Frame? = nil
local _splashRoot: Frame? = nil
local _splashes: { [string]: { ImageLabel } } = {}

local function ensureGui(): ScreenGui
	if _gui and _gui.Parent then
		return _gui :: ScreenGui
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "AnimaScreenFxPreview"
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 999
	gui.Parent = CoreGui

	local fade = Instance.new("Frame")
	fade.BackgroundColor3 = Color3.new(0, 0, 0)
	fade.BackgroundTransparency = 1
	fade.BorderSizePixel = 0
	fade.Size = UDim2.fromScale(1, 1)
	fade.ZIndex = 3
	fade.Parent = gui

	local tint = Instance.new("Frame")
	tint.BackgroundColor3 = Color3.fromRGB(255, 60, 60)
	tint.BackgroundTransparency = 1
	tint.BorderSizePixel = 0
	tint.Size = UDim2.fromScale(1, 1)
	tint.ZIndex = 1
	tint.Parent = gui

	local splashRoot = Instance.new("Frame")
	splashRoot.BackgroundTransparency = 1
	splashRoot.Size = UDim2.fromScale(1, 1)
	splashRoot.ZIndex = 2
	splashRoot.Parent = gui

	local top = Instance.new("Frame")
	local bottom = Instance.new("Frame")
	for _, bar in { top, bottom } do
		bar.BackgroundColor3 = Color3.new(0, 0, 0)
		bar.BorderSizePixel = 0
		bar.Size = UDim2.fromScale(1, 0)
		bar.ZIndex = 4
		bar.Parent = gui
	end
	bottom.AnchorPoint = Vector2.new(0, 1)
	bottom.Position = UDim2.fromScale(0, 1)

	_gui, _fade, _tint, _splashRoot = gui, fade, tint, splashRoot
	_letterTop, _letterBottom = top, bottom
	_splashes = {}
	return gui
end

-- 布点走 ScreenSampler.splashLayout(与运行时 ScreenOverlay 共用同一份伪随机)。
local function ensureSplashes(
	key: string,
	seed: number,
	count: number,
	imageId: string
): { ImageLabel }
	local existing = _splashes[key]
	if existing then
		return existing
	end
	local root = _splashRoot :: Frame
	local imgs: { ImageLabel } = {}
	for _, slot in ScreenSampler.splashLayout(seed, count) do
		local img = Instance.new("ImageLabel")
		img.BackgroundTransparency = 1
		img.Image = imageId
		img.ImageTransparency = 1
		img.AnchorPoint = Vector2.new(0.5, 0.5)
		img.Position = UDim2.fromScale(slot.x, slot.y)
		img.Size = UDim2.fromScale(slot.size, slot.size)
		img.SizeConstraint = Enum.SizeConstraint.RelativeYY
		img.Rotation = slot.rotation
		img.ZIndex = 2
		img.Parent = root
		table.insert(imgs, img)
	end
	_splashes[key] = imgs
	return imgs
end

function ScreenFxPreview.apply(cutscene: CutsceneFormat.Cutscene, t: number)
	local cues: { CutsceneFormat.ScreenCue }? = nil
	for _, tr in cutscene.tracks do
		if tr.kind == "screen" and not tr.hidden and tr.screenCues and #tr.screenCues > 0 then
			cues = tr.screenCues
			break
		end
	end
	if not cues then
		ScreenFxPreview.clear()
		return
	end

	ensureGui()
	local s = ScreenSampler.sample(cues :: { CutsceneFormat.ScreenCue }, t)

	local fade = _fade :: Frame
	fade.BackgroundTransparency = math.clamp(s.fadeAlpha, 0, 1)
	if s.fadeColor then
		fade.BackgroundColor3 = s.fadeColor
	end

	local box = math.clamp(s.letterbox, 0, 0.5);
	(_letterTop :: Frame).Size = UDim2.fromScale(1, box);
	(_letterBottom :: Frame).Size = UDim2.fromScale(1, box)

	-- tint 近似:强度 0..1 → 色框透明度 1..0.65(不做真 ColorCorrection)
	local tint = _tint :: Frame
	if s.tintColor then
		tint.BackgroundColor3 = s.tintColor
	end
	tint.BackgroundTransparency = 1 - math.clamp(s.tintIntensity, 0, 1) * 0.35

	local nowActive: { [string]: boolean } = {}
	for _, sp in s.splashes do
		nowActive[sp.key] = true
		for _, img in ensureSplashes(sp.key, sp.seed, sp.count, sp.imageId) do
			img.ImageTransparency = math.clamp(sp.alpha, 0, 1)
		end
	end
	for key, imgs in _splashes do
		if not nowActive[key] then
			for _, img in imgs do
				img:Destroy()
			end
			_splashes[key] = nil
		end
	end
end

-- 清除预览(离开 scrub / 关面板 / 换 cutscene)。
function ScreenFxPreview.clear()
	if _gui then
		_gui:Destroy()
		_gui, _fade, _tint, _splashRoot = nil, nil, nil, nil
		_letterTop, _letterBottom = nil, nil
		_splashes = {}
	end
end

return ScreenFxPreview
