--!strict
-- ContextMenu — 右键上下文菜单(原生 Instance,一次性弹出)。
-- 出现在鼠标处;点选项执行并关闭,点菜单外或再次右键关闭。
-- 支持三种行:item(可点) / header(分组标题) / sep(分隔线)。

local Theme = require(script.Parent.Theme)
local OverlayHost = require(script.Parent.OverlayHost)

local ContextMenu = {}

export type Item = {
	kind: ("item" | "header" | "sep")?,
	text: string?,
	color: Color3?,
	onClick: (() -> ())?,
}

export type ShowOpts = {
	position: Vector2?, -- 相对 PluginGui 的左上角坐标(不传则用鼠标)
	width: number?,
	anchor: Vector2?, -- 锚点(默认左上);如 (0,0) 菜单向右下展开,(1,0) 向左下展开
	minX: number?, -- 菜单左缘下限(默认:鼠标弹窗避开左轨道列)
}

local MENU_MARGIN = 8

local current: Frame? = nil
local lastShownAt = 0

function ContextMenu.close()
	if current then
		current:Destroy()
		current = nil
	end
end

-- 刚刚(同帧内)是否弹过菜单。供重叠元素仲裁:子元素菜单已弹时,
-- 父级(轨道行)在 task.defer 里检查到 true 就放弃自己的菜单。
function ContextMenu.justShown(): boolean
	return os.clock() - lastShownAt < 0.05
end

function ContextMenu.show(gui: PluginGui, items: { Item }, opts: ShowOpts?)
	ContextMenu.close()
	lastShownAt = os.clock()

	-- 注意:DockWidget 里嵌套 ScreenGui 不渲染,浮层必须用普通 Frame
	-- 直接挂在 PluginGui 下(同 DragController 的 overlay 做法)。
	local host = OverlayHost.ensure(gui)

	local holder = Instance.new("Frame")
	holder.Name = "AnimaContextMenu"
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromScale(1, 1)
	holder.ZIndex = 1
	holder.BorderSizePixel = 0
	holder.Parent = host
	current = holder
	OverlayHost.bringToFront(gui)

	-- 全屏遮罩:点外部关闭
	local shade = Instance.new("TextButton")
	shade.BackgroundTransparency = 1
	shade.Size = UDim2.fromScale(1, 1)
	shade.Text = ""
	shade.ZIndex = 1
	shade.AutoButtonColor = false
	shade.Activated:Connect(ContextMenu.close)
	shade.Parent = holder

	-- 计算高度
	local rowH = Theme.size.menuRow
	local height = 6
	for _, it in items do
		local kind = it.kind or "item"
		height += if kind == "sep" then 7 elseif kind == "header" then 18 else rowH
	end

	local menuWidth = if opts and opts.width then opts.width else Theme.size.menuWidth
	local anchor = if opts and opts.anchor then opts.anchor else Vector2.new(0, 0)
	-- 弹在锚点或鼠标处,按面板尺寸夹紧;空间不足时相对锚点翻转
	local panel = gui.AbsoluteSize
	local px: number
	local py: number
	if opts and opts.position then
		px = opts.position.X
		py = opts.position.Y
	else
		local m = gui:GetRelativeMousePosition()
		px = m.X
		py = m.Y
	end

	local minX = MENU_MARGIN
	if opts and opts.minX then
		minX = opts.minX
	elseif not (opts and opts.position) then
		-- 时间轴区右键:勿把菜单 clamp 到 x≈8,否则会叠在左轨道列下缘被挡
		minX = Theme.size.labelWidth + MENU_MARGIN
	end
	local maxX = math.max(minX, panel.X - menuWidth - MENU_MARGIN)
	local maxY = math.max(MENU_MARGIN, panel.Y - height - MENU_MARGIN)

	if anchor.X >= 0.5 then
		local left = px - menuWidth
		if left < minX then
			anchor = Vector2.new(0, anchor.Y)
			px = math.clamp(left, minX, maxX)
		else
			px = math.clamp(px, minX + menuWidth, panel.X - MENU_MARGIN)
		end
	else
		if px + menuWidth > panel.X - MENU_MARGIN then
			px = math.max(minX, px - menuWidth)
		end
		px = math.clamp(px, minX, maxX)
	end

	if anchor.Y >= 0.5 then
		if py - height < MENU_MARGIN then
			anchor = Vector2.new(anchor.X, 0)
		else
			py = math.clamp(py, MENU_MARGIN + height, panel.Y - MENU_MARGIN)
		end
	else
		if py + height > panel.Y - MENU_MARGIN then
			py = math.max(MENU_MARGIN, py - height - 4)
		end
		py = math.clamp(py, MENU_MARGIN, maxY)
	end

	local menu = Instance.new("Frame")
	menu.BackgroundColor3 = Theme.color.menu
	menu.BorderSizePixel = 0
	menu.AnchorPoint = anchor
	menu.Size = UDim2.fromOffset(menuWidth, height)
	menu.Position = UDim2.fromOffset(px, py)
	menu.ZIndex = 2
	menu.ClipsDescendants = false
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = menu
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 3)
	pad.PaddingBottom = UDim.new(0, 3)
	pad.Parent = menu
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = menu
	menu.Parent = holder

	for i, it in items do
		local kind = it.kind or "item"
		if kind == "sep" then
			local line = Instance.new("Frame")
			line.LayoutOrder = i
			line.BackgroundColor3 = Theme.color.line
			line.BorderSizePixel = 0
			line.Size = UDim2.new(1, -8, 0, 1)
			line.Position = UDim2.fromOffset(4, 0)
			line.ZIndex = 2
			line.Parent = menu
		elseif kind == "header" then
			local h = Instance.new("TextLabel")
			h.LayoutOrder = i
			h.BackgroundTransparency = 1
			h.Size = UDim2.new(1, 0, 0, 18)
			h.Text = it.text or ""
			h.TextColor3 = Theme.color.textDim
			h.Font = Theme.font.bold
			h.TextSize = 10
			h.TextXAlignment = Enum.TextXAlignment.Left
			h.TextTruncate = Enum.TextTruncate.AtEnd
			h.TextTransparency = 0
			h.ZIndex = 3
			local hp = Instance.new("UIPadding")
			hp.PaddingLeft = UDim.new(0, 10)
			hp.Parent = h
			h.Parent = menu
		else
			-- 文字用 TextLabel、点击用透明按钮,避免极高 ZIndex 祖先下 TextButton.Text 不绘制。
			local row = Instance.new("Frame")
			row.LayoutOrder = i
			row.BackgroundColor3 = Theme.color.menuHover
			row.BackgroundTransparency = 1
			row.BorderSizePixel = 0
			row.Size = UDim2.new(1, 0, 0, rowH)
			row.ZIndex = 3

			local lbl = Instance.new("TextLabel")
			lbl.BackgroundTransparency = 1
			lbl.Size = UDim2.new(1, -12, 1, 0)
			lbl.Position = UDim2.fromOffset(12, 0)
			lbl.Text = it.text or ""
			lbl.TextColor3 = it.color or Theme.color.text
			lbl.TextTransparency = 0
			lbl.Font = Theme.font.main
			lbl.TextSize = 12
			lbl.TextXAlignment = Enum.TextXAlignment.Left
			lbl.TextYAlignment = Enum.TextYAlignment.Center
			lbl.ZIndex = 4
			lbl.Parent = row

			local btn = Instance.new("TextButton")
			btn.BackgroundTransparency = 1
			btn.AutoButtonColor = false
			btn.Size = UDim2.fromScale(1, 1)
			btn.Text = ""
			btn.ZIndex = 5
			btn.MouseEnter:Connect(function()
				row.BackgroundTransparency = 0
			end)
			btn.MouseLeave:Connect(function()
				row.BackgroundTransparency = 1
			end)
			local cb = it.onClick
			btn.Activated:Connect(function()
				ContextMenu.close()
				if cb then
					cb()
				end
			end)
			btn.Parent = row
			row.Parent = menu
		end
	end
end

return ContextMenu
