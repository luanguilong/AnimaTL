--!strict
-- CutsceneBrowser — 枚举/载入 ReplicatedStorage.Anima.Cutscenes 下已导出的过场模块。
-- 载入用"克隆到 scratch 再 require"绕开 require 缓存,重复打开总能拿到最新 Source。

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CutsceneFormat = require(script.Parent.Shared.CutsceneFormat)

local CutsceneBrowser = {}

export type Entry = {
	module: ModuleScript,
	path: string, -- 相对 Cutscenes 根的显示路径,如 "Skills/Ult/ult_slash"
	subPath: string, -- 所在子目录,如 "Skills/Ult"(根目录为 "")
}

local function cutscenesRoot(): Instance?
	local anima = ReplicatedStorage:FindFirstChild("Anima")
	if not anima then
		return nil
	end
	return anima:FindFirstChild("Cutscenes")
end

local function collect(parent: Instance, prefix: string, out: { Entry })
	for _, child in parent:GetChildren() do
		if child:IsA("ModuleScript") then
			table.insert(out, {
				module = child,
				path = if prefix == "" then child.Name else prefix .. "/" .. child.Name,
				subPath = prefix,
			})
		elseif child:IsA("Folder") then
			local sub = if prefix == "" then child.Name else prefix .. "/" .. child.Name
			collect(child, sub, out)
		end
	end
end

-- 递归列出 Cutscenes 下全部过场模块,按路径排序。
function CutsceneBrowser.list(): { Entry }
	local out: { Entry } = {}
	local root = cutscenesRoot()
	if root then
		collect(root, "", out)
	end
	table.sort(out, function(a, b)
		return a.path < b.path
	end)
	return out
end

-- 载入一个过场模块:克隆 → require → 校验 → 销毁克隆(不受 require 缓存影响)。
function CutsceneBrowser.load(mod: ModuleScript): CutsceneFormat.Cutscene?
	local scratch = Instance.new("Folder")
	scratch.Name = "AnimaBrowserScratch"
	scratch.Archivable = false
	local clone = mod:Clone()
	clone.Parent = scratch
	scratch.Parent = script.Parent
	local ok, data = pcall(require, clone)
	scratch:Destroy()
	if not ok or type(data) ~= "table" then
		return nil
	end
	if type(data.duration) ~= "number" or type(data.tracks) ~= "table" then
		return nil
	end
	return data :: CutsceneFormat.Cutscene
end

return CutsceneBrowser
