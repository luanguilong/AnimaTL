--!strict
-- InputPrompt — 模态文本输入浮层(原生 Instance)。
-- 遮罩 + 中央面板(标题 + TextBox + 确定/取消)。回车或点确定提交,点取消/遮罩关闭。
-- 供 AnimationId / 事件名 / speed / vcam 改名等复用。

local Theme = require(script.Parent.Theme)
local OverlayHost = require(script.Parent.OverlayHost)

local InputPrompt = {}

export type Options = {
	title: string,
	default: string?,
	placeholder: string?,
	onSubmit: (text: string) -> (),
}

local current: Frame? = nil

function InputPrompt.close()
	if current then
		current:Destroy()
		current = nil
	end
end

function InputPrompt.show(gui: PluginGui, opts: Options)
	InputPrompt.close()

	local baseZ = 1

	-- 注意:DockWidget 里嵌套 ScreenGui 不渲染,浮层必须用普通 Frame
	-- 直接挂在 PluginGui 下(同 ContextMenu / DragController overlay 做法)。
	local holder = Instance.new("Frame")
	holder.Name = "AnimaInputPrompt"
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromScale(1, 1)
	holder.ZIndex = baseZ
	holder.Parent = OverlayHost.ensure(gui)
	current = holder
	OverlayHost.bringToFront(gui)

	local shade = Instance.new("TextButton")
	shade.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	shade.BackgroundTransparency = 0.5
	shade.Size = UDim2.fromScale(1, 1)
	shade.Text = ""
	shade.AutoButtonColor = false
	shade.ZIndex = baseZ
	shade.Activated:Connect(InputPrompt.close)
	shade.Parent = holder

	local panel = Instance.new("Frame")
	panel.BackgroundColor3 = Theme.color.panelAlt
	panel.BorderSizePixel = 0
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(320, 118)
	panel.ZIndex = baseZ + 1
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = panel
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 14)
	pad.PaddingRight = UDim.new(0, 14)
	pad.PaddingTop = UDim.new(0, 12)
	pad.PaddingBottom = UDim.new(0, 12)
	pad.Parent = panel
	panel.Parent = holder

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, 0, 0, 18)
	title.Text = opts.title
	title.TextColor3 = Theme.color.text
	title.Font = Theme.font.bold
	title.TextSize = 13
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 3
	title.Parent = panel

	local box = Instance.new("TextBox")
	box.Position = UDim2.fromOffset(0, 26)
	box.Size = UDim2.new(1, 0, 0, 30)
	box.BackgroundColor3 = Theme.color.bg
	box.BorderSizePixel = 0
	box.Text = opts.default or ""
	box.PlaceholderText = opts.placeholder or ""
	box.TextColor3 = Theme.color.text
	box.Font = Theme.font.main
	box.TextSize = 13
	box.ClearTextOnFocus = false
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.ZIndex = 3
	local bcorner = Instance.new("UICorner")
	bcorner.CornerRadius = UDim.new(0, 4)
	bcorner.Parent = box
	local bpad = Instance.new("UIPadding")
	bpad.PaddingLeft = UDim.new(0, 8)
	bpad.PaddingRight = UDim.new(0, 8)
	bpad.Parent = box
	box.Parent = panel

	local function submit()
		local text = box.Text
		InputPrompt.close()
		opts.onSubmit(text)
	end

	box.FocusLost:Connect(function(enterPressed: boolean)
		if enterPressed then
			submit()
		end
	end)

	local function mkButton(text: string, x: number, color: Color3, onClick: () -> ())
		local btn = Instance.new("TextButton")
		btn.AnchorPoint = Vector2.new(1, 1)
		btn.Position = UDim2.new(1, x, 1, 0)
		btn.Size = UDim2.fromOffset(70, 26)
		btn.BackgroundColor3 = color
		btn.Text = text
		btn.TextColor3 = Theme.color.text
		btn.Font = Theme.font.bold
		btn.TextSize = 12
		btn.ZIndex = 3
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 4)
		c.Parent = btn
		btn.Activated:Connect(onClick)
		btn.Parent = panel
		return btn
	end

	mkButton("取消", -78, Theme.color.panel, InputPrompt.close)
	mkButton("确定", 0, Theme.color.accent, submit)

	box:CaptureFocus()
end

return InputPrompt
