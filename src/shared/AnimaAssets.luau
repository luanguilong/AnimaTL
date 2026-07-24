--!strict
-- AnimaAssets — 美术资源引用规则(25 spec,2026-07-24 放宽)。插件与运行时共用。
-- 规则:特效包(Model)放在 **ReplicatedStorage 下任意位置** 即可;选择器递归扫描
-- 全库列出(跳过 Anima 自身运行时树),按相对路径显示。workspace 命中视为旧位置,
-- warn 提示迁移(场景实体不随复制走,不该做资源库)。

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnimaAssets = {}

-- 扫描时跳过的 ReplicatedStorage 顶层子树(anima 自身运行时/过场数据,不是美术资源)
local SCAN_SKIP: { [string]: boolean } = {
	Anima = true,
}

export type PackEntry = {
	name: string,
	path: string, -- 相对 ReplicatedStorage 的路径(含自身名,如 "VFX/驴踢"),选择器显示用
	model: Model,
}

-- 递归列出 ReplicatedStorage 下全部 Model(不进入 Model 内部;按路径字典序)。
function AnimaAssets.listPacks(): { PackEntry }
	local out: { PackEntry } = {}
	local function visit(inst: Instance, prefix: string)
		for _, child in inst:GetChildren() do
			if prefix == "" and SCAN_SKIP[child.Name] then
				continue
			end
			local path = if prefix == "" then child.Name else prefix .. "/" .. child.Name
			if child:IsA("Model") then
				table.insert(out, { name = child.Name, path = path, model = child })
			else
				visit(child, path)
			end
		end
	end
	visit(ReplicatedStorage, "")
	table.sort(out, function(a, b)
		return a.path < b.path
	end)
	return out
end

local _warnedLegacy: { [string]: boolean } = {}
local _warnedDup: { [string]: boolean } = {}

-- 按名字找包。查找顺序:ReplicatedStorage 递归 → workspace 递归(旧位置,warn 提示迁移)。
-- 返回 (Model?, 是否来自旧位置)。重名取路径序第一个并 warn 一次。
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
				`[anima] ReplicatedStorage 下有 {#hits} 个同名包 '{name}',使用 '{hits[1].path}'——建议改名区分`
			)
		end
		return hits[1].model, false
	end

	-- 旧位置兜底:workspace(提示迁移,不自动搬)
	local legacy = workspace:FindFirstChild(name, true)
	if legacy and legacy:IsA("Model") then
		if not _warnedLegacy[name] then
			_warnedLegacy[name] = true
			warn(
				`[anima] 包 '{name}' 在 workspace({legacy:GetFullName()})找到——建议移入 ReplicatedStorage`
			)
		end
		return legacy, true
	end
	return nil, false
end

return AnimaAssets
