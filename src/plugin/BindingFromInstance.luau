--!strict
-- BindingFromInstance — 把 Explorer 里选中的 Instance 转成过场 binding + followPart 路径。

local BindingFromInstance = {}

local DEFAULT_FOLLOW_PART = "HumanoidRootPart"

local function characterModelAncestor(inst: Instance): Model?
	local cur: Instance? = inst
	while cur do
		if cur:IsA("Model") and cur:FindFirstChildOfClass("Humanoid") then
			return cur
		end
		cur = cur.Parent
	end
	return nil
end

local function bindingRoot(inst: Instance): Instance?
	local char = characterModelAncestor(inst)
	if char then
		return char
	end
	if inst:IsA("Model") then
		return inst
	end
	if inst:IsA("BasePart") or inst:IsA("Attachment") then
		local p = inst.Parent
		while p do
			if p:IsA("Model") then
				return p
			end
			if p == workspace then
				return if inst:IsA("BasePart") then inst else nil
			end
			p = p.Parent
		end
	end
	return nil
end

local function relativePathFromRoot(root: Instance, node: Instance): string?
	if node == root then
		return DEFAULT_FOLLOW_PART
	end
	local segments: { string } = {}
	local cur: Instance? = node
	while cur and cur ~= root do
		table.insert(segments, 1, cur.Name)
		cur = cur.Parent
	end
	if cur ~= root then
		return nil
	end
	return table.concat(segments, "/")
end

-- 返回 (逻辑 binding 名, 锚点相对路径)。解析失败返回 nil。
function BindingFromInstance.resolve(inst: Instance): (string?, string?)
	if not inst:IsDescendantOf(game) then
		return nil, nil
	end
	local root = bindingRoot(inst)
	if not root then
		return nil, nil
	end
	local binding = root.Name
	if binding == "" then
		return nil, nil
	end
	local followPart = relativePathFromRoot(root, inst)
	if not followPart or followPart == "" then
		followPart = DEFAULT_FOLLOW_PART
	end
	if inst == root and root:IsA("Model") then
		local hrp = root:FindFirstChild(DEFAULT_FOLLOW_PART)
		followPart = if hrp then DEFAULT_FOLLOW_PART else root.Name
	end
	return binding, followPart
end

function BindingFromInstance.tryDragData(dragData: { [string]: any }): Instance?
	local data = dragData.Data
	if typeof(data) == "Instance" then
		return data
	end
	return nil
end

return BindingFromInstance
