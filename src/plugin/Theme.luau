--!strict
-- Theme — 插件 UI 的配色与尺寸常量(暗色,贴近 Studio)。

local Theme = {
	color = {
		bg = Color3.fromRGB(48, 48, 48),
		panel = Color3.fromRGB(56, 56, 56),
		panelAlt = Color3.fromRGB(62, 62, 62),
		trackHeader = Color3.fromRGB(51, 51, 51),
		line = Color3.fromRGB(35, 35, 35),
		text = Color3.fromRGB(210, 210, 210),
		textDim = Color3.fromRGB(130, 130, 130),
		-- 时间条(绿/蓝等彩色块)内文案:浅字+描边,避免与条色糊在一起
		clipLabelText = Color3.fromRGB(255, 255, 255),
		clipLabelStroke = Color3.fromRGB(0, 0, 0),
		accent = Color3.fromRGB(68, 136, 255),
		playhead = Color3.fromRGB(255, 80, 80),
		selection = Color3.fromRGB(68, 136, 255),
		handle = Color3.fromRGB(240, 240, 240),
		marker = Color3.fromRGB(100, 180, 255),
		clipHeader = Color3.fromRGB(0, 0, 0),
		binding = Color3.fromRGB(42, 42, 42),
		menu = Color3.fromRGB(40, 40, 44),
		menuHover = Color3.fromRGB(0, 120, 200),
		danger = Color3.fromRGB(220, 90, 90),
		-- 各轨道类型的代表色
		track = {
			animation = Color3.fromRGB(76, 175, 80),
			camera = Color3.fromRGB(66, 133, 244),
			cameraMove = Color3.fromRGB(77, 182, 172),
			transform = Color3.fromRGB(255, 167, 38),
			event = Color3.fromRGB(100, 180, 255),
			sound = Color3.fromRGB(156, 120, 255),
			effect = Color3.fromRGB(255, 112, 198),
		},
	},
	-- PluginGui 浮层根(AnimaOverlayHost)统一 ZIndex。子级菜单/输入框用 1–10,勿把 Text 控件设到本值。
	overlayZIndex = 100,
	size = {
		topbar = 34,
		trackHeight = 40,
		labelWidth = 200,
		rulerHeight = 24,
		keyframe = 11,
		padding = 6,
		previewHeight = 156, -- 内嵌预览横条高度
		vcamBar = 26, -- vcam 管理条高度
		menuRow = 24, -- 右键菜单行高
		menuWidth = 200,
		playheadLineWidth = 2,
		playheadHandleWidth = 40,
		playheadHandleExtendUp = 14, -- 倒三角热区向上多出(便于点在帧号上方)
		playheadTriangleWidth = 12,
		playheadTriangleHeight = 10,
	},
	font = {
		main = Enum.Font.Gotham,
		bold = Enum.Font.GothamBold,
	},
}

-- 按轨道类型取色
function Theme.trackColor(kind: string): Color3
	return Theme.color.track[kind] or Theme.color.textDim
end

local CLIP_LABEL_STROKE_TRANSPARENCY = 0.35

-- 动画/相机时间条上的 TextLabel 统一高对比样式
function Theme.styleTimelineClipLabel(label: TextLabel)
	label.TextColor3 = Theme.color.clipLabelText
	label.TextStrokeColor3 = Theme.color.clipLabelStroke
	label.TextStrokeTransparency = CLIP_LABEL_STROKE_TRANSPARENCY
	label.Font = Theme.font.bold
	label.TextSize = 11
end

return Theme
