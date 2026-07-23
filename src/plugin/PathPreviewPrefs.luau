--!strict
-- PathPreviewPrefs — CameraPath 3D 预览折线采样段数(仅编辑器偏好,不写 Cutscene)。

local ContextMenu = require(script.Parent.ContextMenu)
local InputPrompt = require(script.Parent.InputPrompt)

local PathPreviewPrefs = {}

export type Mode = "auto" | "fixed" | "scale"

export type Prefs = {
	mode: Mode,
	fixedSegments: number,
	scale: number,
}

local SETTING_KEY = "AnimaCameraPathPreview_v1"
local MIN_SEG = 4
local MAX_SEG = 240

local DEFAULT: Prefs = {
	mode = "auto",
	fixedSegments = 32,
	scale = 1,
}

function PathPreviewPrefs.minSegments(): number
	return MIN_SEG
end

function PathPreviewPrefs.maxSegments(): number
	return MAX_SEG
end

function PathPreviewPrefs.default(): Prefs
	return {
		mode = DEFAULT.mode,
		fixedSegments = DEFAULT.fixedSegments,
		scale = DEFAULT.scale,
	}
end

local function clampPrefs(p: Prefs): Prefs
	return {
		mode = p.mode,
		fixedSegments = math.clamp(math.floor(p.fixedSegments + 0.5), MIN_SEG, MAX_SEG),
		scale = math.clamp(p.scale, 0.25, 8),
	}
end

function PathPreviewPrefs.load(plugin: { GetSetting: (self: any, key: string) -> any }): Prefs
	local raw = plugin:GetSetting(SETTING_KEY)
	if type(raw) ~= "table" then
		return PathPreviewPrefs.default()
	end
	local mode = raw.mode
	if mode ~= "auto" and mode ~= "fixed" and mode ~= "scale" then
		mode = "auto"
	end
	return clampPrefs({
		mode = mode,
		fixedSegments = if type(raw.fixedSegments) == "number" then raw.fixedSegments else DEFAULT.fixedSegments,
		scale = if type(raw.scale) == "number" then raw.scale else DEFAULT.scale,
	})
end

function PathPreviewPrefs.save(
	plugin: { SetSetting: (self: any, key: string, value: any) -> () },
	prefs: Prefs
)
	plugin:SetSetting(SETTING_KEY, clampPrefs(prefs))
end

function PathPreviewPrefs.sampleCountForSpan(spanSec: number, sampleStep: number, prefs: Prefs?): number
	local step = math.max(sampleStep, 1e-6)
	local span = math.max(spanSec, 0)
	local autoN = math.clamp(math.floor(span / step), 1, MAX_SEG)
	local p = prefs or DEFAULT
	if p.mode == "fixed" then
		return math.clamp(p.fixedSegments, MIN_SEG, MAX_SEG)
	end
	if p.mode == "scale" then
		return math.clamp(math.floor(autoN * p.scale), MIN_SEG, MAX_SEG)
	end
	return autoN
end

function PathPreviewPrefs.describe(prefs: Prefs): string
	if prefs.mode == "auto" then
		return "自动"
	end
	if prefs.mode == "fixed" then
		return `固定 {prefs.fixedSegments}(每段生效区间)`
	end
	return `自动 ×{prefs.scale}`
end

function PathPreviewPrefs.apply(
	plugin: { SetSetting: (self: any, key: string, value: any) -> () },
	prefs: Prefs,
	onChanged: () -> ()
)
	PathPreviewPrefs.save(plugin, prefs)
	print(`[anima] 路径预览段数: {PathPreviewPrefs.describe(prefs)}`)
	onChanged()
end

function PathPreviewPrefs.menuItems(
	gui: PluginGui,
	plugin: { GetSetting: (self: any, key: string) -> any, SetSetting: (self: any, key: string, value: any) -> () },
	onChanged: () -> ()
): { ContextMenu.Item }
	local cur = PathPreviewPrefs.load(plugin)
	local items: { ContextMenu.Item } = {
		{ kind = "header", text = "路径预览折线(段数)" },
		{
			text = if cur.mode == "auto" then "✓ 自动" else "  自动",
			onClick = function()
				PathPreviewPrefs.apply(plugin, { mode = "auto", fixedSegments = cur.fixedSegments, scale = cur.scale }, onChanged)
			end,
		},
		{ kind = "sep" },
		{ kind = "header", text = "固定(每段生效区间)" },
	}
	for _, n in { 8, 16, 32, 64, 128 } do
		local fixed = n
		table.insert(items, {
			text = if cur.mode == "fixed" and cur.fixedSegments == fixed
				then `  ✓ {fixed} 段`
				else `    {fixed} 段`,
			onClick = function()
				PathPreviewPrefs.apply(
					plugin,
					{ mode = "fixed", fixedSegments = fixed, scale = cur.scale },
					onChanged
				)
			end,
		})
	end
	table.insert(items, {
		text = "  自定义固定段数…",
		onClick = function()
			InputPrompt.show(gui, {
				title = `固定段数 ({MIN_SEG}–{MAX_SEG})`,
				default = tostring(cur.fixedSegments),
				placeholder = "如 32",
				onSubmit = function(txt)
					local n = tonumber(txt)
					if n then
						PathPreviewPrefs.apply(
							plugin,
							{ mode = "fixed", fixedSegments = n, scale = cur.scale },
							onChanged
						)
					end
				end,
			})
		end,
	})
	table.insert(items, { kind = "sep" })
	table.insert(items, { kind = "header", text = "倍率(基于自动)" })
	for _, mul in { 0.5, 1, 2, 4 } do
		local scale = mul
		table.insert(items, {
			text = if cur.mode == "scale" and math.abs(cur.scale - scale) < 0.001
				then `  ✓ ×{scale}`
				else `    ×{scale}`,
			onClick = function()
				PathPreviewPrefs.apply(
					plugin,
					{ mode = "scale", fixedSegments = cur.fixedSegments, scale = scale },
					onChanged
				)
			end,
		})
	end
	return items
end

function PathPreviewPrefs.showContextMenu(
	gui: PluginGui,
	plugin: { GetSetting: (self: any, key: string) -> any, SetSetting: (self: any, key: string, value: any) -> () },
	onChanged: () -> ()
)
	ContextMenu.show(gui, PathPreviewPrefs.menuItems(gui, plugin, onChanged))
end

return PathPreviewPrefs
