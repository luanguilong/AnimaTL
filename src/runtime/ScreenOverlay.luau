--!strict
-- ScreenOverlay — 演出轨(22 spec)的屏幕层载体:全屏遮罩 / 黑边 / 专用 ColorCorrection /
-- 溅血贴图 / 跳过按钮。仅客户端;destroy() 全部销毁还原,绝不修改用户已有后期实例。

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")

local ScreenSampler = require(script.Parent.Parent.Shared.ScreenSampler)

local ScreenOverlay = {}
ScreenOverlay.__index = ScreenOverlay

export type Config = {
	displayOrder: number?, -- 缺省 999
}

export type ScreenOverlay = typeof(setmetatable(
	{} :: {
		gui: ScreenGui,
		_fade: Frame,
		_letterTop: Frame,
		_letterBottom: Frame,
		_splashRoot: Frame,
		_splashes: { [string]: { ImageLabel } }, -- cueKey -> 该 cue 的贴图组
		_colorCorrection: ColorCorrectionEffect?,
		_skipButton: TextButton?,
		_skipFill: Frame?,
		_skipHeld: number,
		_destroyed: boolean,
	},
	ScreenOverlay
))

local function fullscreenFrame(color: Color3, parent: Instance): Frame
	local f = Instance.new("Frame")
	f.BackgroundColor3 = color
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.Size = UDim2.fromScale(1, 1)
	f.ZIndex = 1
	f.Parent = parent
	return f
end

function ScreenOverlay.new(config: Config?): ScreenOverlay?
	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return nil
	end
	local playerGui = localPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return nil
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "AnimaScreenOverlay"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = (config and config.displayOrder) or 999
	gui.Parent = playerGui

	local self = setmetatable({
		gui = gui,
		_fade = fullscreenFrame(Color3.new(0, 0, 0), gui),
		_letterTop = Instance.new("Frame"),
		_letterBottom = Instance.new("Frame"),
		_splashRoot = Instance.new("Frame"),
		_splashes = {},
		_colorCorrection = nil,
		_skipButton = nil,
		_skipFill = nil,
		_skipHeld = 0,
		_destroyed = false,
	}, ScreenOverlay)

	for _, bar in { self._letterTop, self._letterBottom } do
		bar.BackgroundColor3 = Color3.new(0, 0, 0)
		bar.BorderSizePixel = 0
		bar.Size = UDim2.fromScale(1, 0)
		bar.ZIndex = 3
		bar.Parent = gui
	end
	self._letterBottom.AnchorPoint = Vector2.new(0, 1)
	self._letterBottom.Position = UDim2.fromScale(0, 1)

	self._splashRoot.BackgroundTransparency = 1
	self._splashRoot.Size = UDim2.fromScale(1, 1)
	self._splashRoot.ZIndex = 2
	self._splashRoot.Parent = gui

	return self
end

-- alpha:0 = 全遮(不透明),1 = 全透。
function ScreenOverlay.setFade(self: ScreenOverlay, alpha: number, color: Color3?)
	if self._destroyed then
		return
	end
	self._fade.BackgroundTransparency = math.clamp(alpha, 0, 1)
	if color then
		self._fade.BackgroundColor3 = color
	end
end

-- frac:单边黑边高占屏幕比(0..0.5)。
function ScreenOverlay.setLetterbox(self: ScreenOverlay, frac: number)
	if self._destroyed then
		return
	end
	frac = math.clamp(frac, 0, 0.5)
	self._letterTop.Size = UDim2.fromScale(1, frac)
	self._letterBottom.Size = UDim2.fromScale(1, frac)
end

-- intensity:0..1;0 时还原并保持专用实例待命。
function ScreenOverlay.setTint(
	self: ScreenOverlay,
	intensity: number,
	tintColor: Color3?,
	saturation: number?
)
	if self._destroyed then
		return
	end
	local cc = self._colorCorrection
	if not cc then
		if intensity <= 0 then
			return
		end
		cc = Instance.new("ColorCorrectionEffect")
		cc.Name = "AnimaScreenTint"
		cc.Parent = Lighting
		self._colorCorrection = cc
	end
	intensity = math.clamp(intensity, 0, 1)
	local target = tintColor or Color3.fromRGB(255, 60, 60)
	cc.TintColor = Color3.new(1, 1, 1):Lerp(target, intensity)
	cc.Saturation = (saturation or 0) * intensity
end

-- 确保 cueKey 对应的 count 张贴图存在并返回;布点走 ScreenSampler.splashLayout
-- (与插件预览共用同一份伪随机,重播/两端一致)。
function ScreenOverlay.ensureSplashes(
	self: ScreenOverlay,
	cueKey: string,
	seed: number,
	count: number,
	imageId: string
): { ImageLabel }
	local existing = self._splashes[cueKey]
	if existing then
		return existing
	end
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
		img.Parent = self._splashRoot
		table.insert(imgs, img)
	end
	self._splashes[cueKey] = imgs
	return imgs
end

function ScreenOverlay.setSplashAlpha(self: ScreenOverlay, cueKey: string, alpha: number)
	local imgs = self._splashes[cueKey]
	if not imgs then
		return
	end
	for _, img in imgs do
		img.ImageTransparency = math.clamp(alpha, 0, 1)
	end
end

function ScreenOverlay.clearSplashes(self: ScreenOverlay, cueKey: string)
	local imgs = self._splashes[cueKey]
	if not imgs then
		return
	end
	for _, img in imgs do
		img:Destroy()
	end
	self._splashes[cueKey] = nil
end

-- 跳过按钮:holdSec<=0 点按即触发;否则按住充能(进度条),中途松开清零。
function ScreenOverlay.showSkipButton(self: ScreenOverlay, holdSec: number, onSkip: () -> ())
	if self._destroyed or self._skipButton then
		return
	end
	local btn = Instance.new("TextButton")
	btn.Name = "AnimaSkip"
	btn.AnchorPoint = Vector2.new(1, 1)
	btn.Position = UDim2.new(1, -24, 1, -24)
	btn.Size = UDim2.fromOffset(120, 36)
	btn.BackgroundColor3 = Color3.new(0, 0, 0)
	btn.BackgroundTransparency = 0.4
	btn.BorderSizePixel = 0
	btn.Text = if holdSec > 0 then "按住跳过 ▸" else "跳过 ▸"
	btn.TextColor3 = Color3.new(1, 1, 1)
	btn.TextSize = 16
	btn.ZIndex = 5
	btn.Parent = self.gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = btn

	local fill = Instance.new("Frame")
	fill.BackgroundColor3 = Color3.new(1, 1, 1)
	fill.BackgroundTransparency = 0.7
	fill.BorderSizePixel = 0
	fill.AnchorPoint = Vector2.new(0, 1)
	fill.Position = UDim2.fromScale(0, 1)
	fill.Size = UDim2.fromOffset(0, 3)
	fill.ZIndex = 6
	fill.Parent = btn

	self._skipButton = btn
	self._skipFill = fill
	self._skipHeld = 0

	if holdSec <= 0 then
		btn.Activated:Connect(function()
			if not self._destroyed then
				onSkip()
			end
		end)
		return
	end

	local heartbeat: RBXScriptConnection? = nil
	local function stopCharge()
		if heartbeat then
			heartbeat:Disconnect()
			heartbeat = nil
		end
		self._skipHeld = 0
		if fill.Parent then
			fill.Size = UDim2.fromOffset(0, 3)
		end
	end
	btn.MouseButton1Down:Connect(function()
		if heartbeat then
			return
		end
		heartbeat = game:GetService("RunService").Heartbeat:Connect(function(dt)
			if self._destroyed then
				stopCharge()
				return
			end
			self._skipHeld += dt
			fill.Size = UDim2.new(math.clamp(self._skipHeld / holdSec, 0, 1), 0, 0, 3)
			if self._skipHeld >= holdSec then
				stopCharge()
				onSkip()
			end
		end)
	end)
	btn.MouseButton1Up:Connect(stopCharge)
	btn.MouseLeave:Connect(stopCharge)
end

function ScreenOverlay.destroy(self: ScreenOverlay)
	if self._destroyed then
		return
	end
	self._destroyed = true
	if self._colorCorrection then
		self._colorCorrection:Destroy()
		self._colorCorrection = nil
	end
	self.gui:Destroy()
end

return ScreenOverlay
