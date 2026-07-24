--!strict
-- AnimaAssets — 美术资源文件夹约定(25 spec)。插件与运行时共用。
-- 唯一资源根:ReplicatedStorage.AnimaAssets(子文件夹随意分类,VFX 包 = 其中的 Model)。
-- 兼容旧位置(Assets 子级 / ReplicatedStorage 顶层 / workspace 递归),命中时 warn 提示迁移。

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnimaAssets = {}

AnimaAssets.FOLDER_NAME = "AnimaAssets"

export type PackEntry = {
	name: string,
	path: string, -- 相对 AnimaAssets 的路径(含自身名,如 "VFX/驴踢"),选择器显示用
	model: Model,
}

-- 资源根文件夹;create=true 时不存在则创建(编辑器「一键创建」用)。
function AnimaAssets.root(create: boolean?): Folder?
	local folder = ReplicatedStorage:FindFirstChild(AnimaAssets.FOLDER_NAME)
	if folder and folder:IsA("Folder") then
		return folder
	end
	if create then
		local f = Instance.new("Folder")
		f.Name = AnimaAssets.FOLDER_NAME
		f.Parent = ReplicatedStorage
		return f
	end
	return nil
end

-- 递归列出资源根下全部 Model(按路径字典序,选择器直接展示)。
function AnimaAssets.listPacks(): { PackEntry }
	local out: { PackEntry } = {}
	local rootFolder = AnimaAssets.root(false)
	if not rootFolder then
		return out
	end
	local function visit(inst: Instance, prefix: string)
		for _, child in inst:GetChildren() do
			local path = if prefix == "" then child.Name else prefix .. "/" .. child.Name
			if child:IsA("Model") then
				table.insert(out, { name = child.Name, path = path, model = child })
			else
				visit(child, path)
			end
		end
	end
	visit(rootFolder, "")
	table.sort(out, function(a, b)
		return a.path < b.path
	end)
	return out
end

local _warnedLegacy: { [string]: boolean } = {}
local _warnedDup: { [string]: boolean } = {}

-- 按名字找包。查找顺序:AnimaAssets 递归 → 旧位置(Assets 子级/顶层/workspace 递归)。
-- 返回 (Model?, 是否来自旧位置)。AnimaAssets 内重名取路径序第一个并 warn 一次。
function AnimaAssets.findPack(name: string): (Model?, boolean)
	if name == "" then
		return nil, false
	end
	local hits: { PackEntry } = {}
	for _, entry in AnimaAssets.listPacks() do
		if entry.name == name then
			table.insert(hits, entry)
		end
	end
	if #hits > 0 then
		if #hits > 1 and not _warnedDup[name] then
			_warnedDup[name] = true
			warn(
				`[anima] AnimaAssets 内有 {#hits} 个同名包 '{name}',使用 '{hits[1].path}'——建议改名区分`
			)
		end
		return hits[1].model, false
	end

	-- 旧位置兜底(25 spec:提示迁移,不自动搬)
	local legacy: Instance? = nil
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if assets then
		legacy = assets:FindFirstChild(name)
	end
	if not (legacy and legacy:IsA("Model")) then
		legacy = ReplicatedStorage:FindFirstChild(name)
	end
	if not (legacy and legacy:IsA("Model")) then
		legacy = workspace:FindFirstChild(name, true)
	end
	if legacy and legacy:IsA("Model") then
		if not _warnedLegacy[name] then
			_warnedLegacy[name] = true
			warn(
				`[anima] 包 '{name}' 在旧位置({legacy:GetFullName()})找到——建议移入 ReplicatedStorage.{AnimaAssets.FOLDER_NAME}`
			)
		end
		return legacy, true
	end
	return nil, false
end

return AnimaAssets
