--!strict
-- OverlayHost — 插件浮层(菜单/输入/拖拽遮罩)统一挂点,始终叠在 AnimaTimeline 之上。

local Theme = require(script.Parent.Theme)

local OverlayHost = {}

function OverlayHost.ensure(gui: PluginGui): Frame
	local existing = gui:FindFirstChild("AnimaOverlayHost")
	local host: Frame
	if existing and existing:IsA("Frame") then
		host = existing
	else
		host = Instance.new("Frame")
		host.Name = "AnimaOverlayHost"
		host.BackgroundTransparency = 1
		host.Size = UDim2.fromScale(1, 1)
		host.BorderSizePixel = 0
		host.Active = false
		host.ClipsDescendants = false
	end
	host.ZIndex = Theme.overlayZIndex
	OverlayHost.bringToFront(gui, host)
	return host
end

-- 浮层须为 PluginGui 最后一个子级,且 ZIndex 高于 AnimaTimeline 全树(含播放头 ZIndex 50+)。
function OverlayHost.bringToFront(gui: PluginGui, host: Frame?)
	local h = host or gui:FindFirstChild("AnimaOverlayHost")
	if h and h:IsA("Frame") then
		h.Parent = nil
		h.Parent = gui
	end
end

return OverlayHost
