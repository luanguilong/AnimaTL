--!strict
-- ViewportFxFeedback — 小窗预览到点时的 2D 反馈(ViewportFrame 内粒子常不可见)。

local TweenService = game:GetService("TweenService")

local ViewportFxFeedback = {}

local _overlay: Frame? = nil

function ViewportFxFeedback.bindViewport(viewportFrame: ViewportFrame)
	local existing = viewportFrame:FindFirstChild("AnimaFxFlash")
	if existing and existing:IsA("Frame") then
		_overlay = existing
		return
	end
	local flash = Instance.new("Frame")
	flash.Name = "AnimaFxFlash"
	flash.BackgroundColor3 = Color3.fromRGB(255, 120, 40)
	flash.BackgroundTransparency = 1
	flash.BorderSizePixel = 0
	flash.Size = UDim2.fromScale(1, 1)
	flash.ZIndex = 50
	flash.Active = false
	flash.Parent = viewportFrame
	_overlay = flash
end

function ViewportFxFeedback.pulse(viewportFrame: ViewportFrame?)
	local overlay = _overlay
	if viewportFrame then
		if not overlay or overlay.Parent ~= viewportFrame then
			ViewportFxFeedback.bindViewport(viewportFrame)
			overlay = _overlay
		end
	end
	if not overlay then
		return
	end
	overlay.BackgroundTransparency = 0.35
	local tween = TweenService:Create(
		overlay,
		TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 1 }
	)
	tween:Play()
end

return ViewportFxFeedback
