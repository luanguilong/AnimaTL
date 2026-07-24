--!strict
-- BindingDrop — Explorer 对象绑到 Timeline 芯片(PluginDragDropped + 点选槽)。
-- 注:Studio 暂不支持从 Explorer 拖入插件;拖入时会尝试 Selection 与 dragData。

local GuiService = game:GetService("GuiService")
local Selection = game:GetService("Selection")

local BindingFromInstance = require(script.Parent.BindingFromInstance)

local BindingDrop = {}

local _installed = false
local _gui: PluginGui? = nil
local _zones: { [GuiObject]: (Instance) -> () } = {}

local function screenMouseForPlugin(gui: PluginGui): Vector2
	local rel = gui:GetRelativeMousePosition()
	local pos = gui.AbsolutePosition
	return Vector2.new(pos.X + rel.X, pos.Y + rel.Y)
end

local function zoneAt(gui: PluginGui): ((Instance) -> ())?
	local mouse = screenMouseForPlugin(gui)
	local hits = GuiService:GetGuiObjectsAtPosition(mouse.X, mouse.Y)
	for _, hit in hits do
		local cur: Instance? = hit
		while cur do
			local cb = _zones[cur :: GuiObject]
			if cb then
				return cb
			end
			cur = cur.Parent
		end
	end
	return nil
end

local function dispatchInstance(gui: PluginGui, inst: Instance)
	local cb = zoneAt(gui)
	if cb then
		cb(inst)
	end
end

function BindingDrop.install(gui: PluginGui)
	if _installed and _gui == gui then
		return
	end
	_installed = true
	_gui = gui
	gui.PluginDragDropped:Connect(function(dragData)
		local inst = BindingFromInstance.tryDragData(dragData)
		if not inst then
			local sel = Selection:Get()
			if #sel == 1 then
				inst = sel[1]
			end
		end
		if inst then
			dispatchInstance(gui, inst)
		end
	end)
end

function BindingDrop.register(zone: GuiObject, onInstance: (Instance) -> ())
	_zones[zone] = onInstance
end

function BindingDrop.unregister(zone: GuiObject)
	_zones[zone] = nil
end

-- 用当前 Explorer 选中(须 1 个)绑定;否则进入点选模式(下一次单选生效)。
function BindingDrop.bindFromSelectionOrPick(_gui: PluginGui, onInstance: (Instance) -> ())
	local sel = Selection:Get()
	if #sel == 1 then
		onInstance(sel[1])
		return
	end
	print(
		"[anima] 请在 Explorer 或视口中选中一个对象(Part/Model/Attachment),将自动绑定"
	)
	local conn: RBXScriptConnection?
	conn = Selection.SelectionChanged:Connect(function()
		local s = Selection:Get()
		if #s ~= 1 then
			return
		end
		if conn then
			conn:Disconnect()
			conn = nil
		end
		onInstance(s[1])
	end)
end

return BindingDrop
