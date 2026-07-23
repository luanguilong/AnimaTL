--!strict
-- AnimaBootstrap — 进游戏按键播放过场(绑定表见 CUTSCENE_BINDINGS)。
-- 依赖: ReplicatedStorage.Anima(Runtime + Cutscenes.<名>)、ForgeVFX、场景 vcam。

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Anima = ReplicatedStorage:WaitForChild("Anima")
local CutscenePlayer = require(Anima.Runtime.CutscenePlayer)
local ForgeEffectPlay = require(Anima.Shared.ForgeEffectPlay)

-- 按键绑定来自过场模块的 Attribute `AnimaPlayKey`(插件 📂 → ⌨ 绑定按键 写入,零代码)。
-- 整个 Cutscenes 里一个 Attribute 都没有时,退回下面的默认表(兼容旧场景)。
local DEFAULT_BINDINGS: { [string]: string } = {
	V = "Player_lvti",
	One = "axe_finisher",
}
local VFX_PACK_NAME = "驴踢"

local localPlayer = Players.LocalPlayer
local activeCutscenePlayer: any = nil

local function findForgeVfxModule(): ModuleScript?
	local rs = ReplicatedStorage:FindFirstChild("ForgeVFX")
	if rs and rs:IsA("ModuleScript") then
		return rs
	end
	local ws = workspace:FindFirstChild("ForgeVFX")
	if ws and ws:IsA("ModuleScript") then
		return ws
	end
	return nil
end

local function findVfxTemplate(): Model?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if assets then
		local m = assets:FindFirstChild(VFX_PACK_NAME)
		if m and m:IsA("Model") then
			return m
		end
	end
	local m = ReplicatedStorage:FindFirstChild(VFX_PACK_NAME)
	if m and m:IsA("Model") then
		return m
	end
	m = workspace:FindFirstChild(VFX_PACK_NAME, true)
	if m and m:IsA("Model") then
		return m
	end
	return nil
end

do
	local forgeVfx = findForgeVfxModule()
	if forgeVfx and ForgeEffectPlay.resolveApi(forgeVfx) then
		print("[anima] ForgeVFX init OK — forge 特效轨将使用 vfx.emit")
	end
end

local function vfxMountPart(character: Model): BasePart?
	local mount = character:FindFirstChild("Torso")
		or character:FindFirstChild("UpperTorso")
		or character:FindFirstChild("HumanoidRootPart")
	if mount and mount:IsA("BasePart") then
		return mount
	end
	return nil
end

-- 特效包零件多为 Anchored,克隆/换父级不会跟随角色,必须显式 PivotTo 到挂点。
local function alignVfxPack(character: Model)
	local pack = character:FindFirstChild(VFX_PACK_NAME, true)
	local mount = vfxMountPart(character)
	if pack and pack:IsA("Model") and mount then
		pack:PivotTo(mount.CFrame)
	end
end

local function attachVfxPackToCharacter(character: Model)
	if character:FindFirstChild(VFX_PACK_NAME, true) then
		alignVfxPack(character)
		return
	end
	local template = findVfxTemplate()
	if not template then
		warn(`[anima] 未找到 VFX 模板「{VFX_PACK_NAME}」,Forge 特效轨可能无目标`)
		return
	end
	local clone = template:Clone()
	local mount = vfxMountPart(character)
	clone.Parent = mount or character
	alignVfxPack(character)
end

local function bindingResolver(name: string): Instance?
	if name == "Player" or name == "Rig1" then
		return localPlayer.Character
	end
	if name == "Camera" then
		return workspace.CurrentCamera
	end
	if name == VFX_PACK_NAME then
		local char = localPlayer.Character
		if char then
			local inChar = char:FindFirstChild(VFX_PACK_NAME, true)
			if inChar then
				return inChar
			end
		end
	end
	return workspace:FindFirstChild(name, true)
end

local function loadCutsceneModule(name: string): ModuleScript?
	local cutscenes = Anima:WaitForChild("Cutscenes")
	local mod = cutscenes:FindFirstChild(name)
	if mod and mod:IsA("ModuleScript") then
		return mod
	end
	warn(`[anima] 缺少 Cutscenes.{name} — 请在 Timeline 💾 导出模块名 {name}`)
	return nil
end

local function playCutscene(name: string)
	if activeCutscenePlayer and activeCutscenePlayer._playing then
		return
	end
	local char = localPlayer.Character
	if not char then
		warn("[anima] 角色未就绪,无法播放过场")
		return
	end
	attachVfxPackToCharacter(char)

	local mod = loadCutsceneModule(name)
	if not mod then
		return
	end

	local cutscene = require(mod)
	local forgeVfx = findForgeVfxModule()
	if not forgeVfx then
		warn("[anima] 未找到 ForgeVFX ModuleScript,forge 特效轨将跳过")
	end

	activeCutscenePlayer = CutscenePlayer.new(cutscene, {
		resolver = bindingResolver,
		camera = workspace.CurrentCamera,
		forgeVfxModule = forgeVfx,
		onEvent = function(ev)
			print(`[anima] event '{ev.name}' @ {ev.t}s`)
		end,
	})
	activeCutscenePlayer:play(function()
		print(`[anima] {name} 播放完成`)
		activeCutscenePlayer = nil
	end)
end

local function onCharacterAdded(char: Model)
	char:WaitForChild("Humanoid")
	attachVfxPackToCharacter(char)
end

if localPlayer.Character then
	onCharacterAdded(localPlayer.Character)
end
localPlayer.CharacterAdded:Connect(onCharacterAdded)

local DIGIT_TO_KEY: { [string]: string } = {
	["0"] = "Zero",
	["1"] = "One",
	["2"] = "Two",
	["3"] = "Three",
	["4"] = "Four",
	["5"] = "Five",
	["6"] = "Six",
	["7"] = "Seven",
	["8"] = "Eight",
	["9"] = "Nine",
}

local function keyCodeFromText(raw: string): Enum.KeyCode?
	local name = DIGIT_TO_KEY[raw] or raw
	local ok, kc = pcall(function()
		return (Enum.KeyCode :: any)[name]
	end)
	if ok and typeof(kc) == "EnumItem" then
		return kc :: Enum.KeyCode
	end
	return nil
end

local boundActions: { string } = {}

local function rebindAll()
	for _, action in boundActions do
		ContextActionService:UnbindAction(action)
	end
	table.clear(boundActions)

	local bindings: { [Enum.KeyCode]: string } = {}
	local foundAttr = false
	local cutscenes = Anima:FindFirstChild("Cutscenes")
	if cutscenes then
		for _, m in cutscenes:GetDescendants() do
			if m:IsA("ModuleScript") then
				local keyRaw = m:GetAttribute("AnimaPlayKey")
				if typeof(keyRaw) == "string" and keyRaw ~= "" then
					local kc = keyCodeFromText(keyRaw)
					if kc then
						bindings[kc] = m.Name
						foundAttr = true
					else
						warn(`[anima] 过场 '{m.Name}' 的按键 '{keyRaw}' 无法识别`)
					end
				end
			end
		end
	end
	if not foundAttr then
		for keyName, cutsceneName in DEFAULT_BINDINGS do
			local kc = keyCodeFromText(keyName)
			if kc then
				bindings[kc] = cutsceneName
			end
		end
	end

	local desc = {}
	for kc, cutsceneName in bindings do
		local action = "AnimaPlay_" .. cutsceneName
		table.insert(boundActions, action)
		ContextActionService:BindAction(action, function(_name, inputState)
			if inputState == Enum.UserInputState.Begin then
				playCutscene(cutsceneName)
			end
			return Enum.ContextActionResult.Pass
		end, false, kc)
		table.insert(desc, kc.Name .. "→" .. cutsceneName)
	end
	print(
		"[anima] 过场按键:"
			.. (if #desc > 0 then table.concat(desc, " · ") else "(无绑定)")
			.. ' · 或 _G.AnimaPlay("模块名")'
	)
end

rebindAll()
do
	local cutscenes = Anima:FindFirstChild("Cutscenes")
	if cutscenes then
		cutscenes.ChildAdded:Connect(function()
			task.defer(rebindAll)
		end)
	end
end

-- selene: allow(global_usage) -- 刻意暴露的调试入口:_G.AnimaPlay("模块名")
_G.AnimaPlay = playCutscene
-- selene: allow(global_usage) -- 旧入口兼容
_G.AnimaPlayPlayerLvTi = function()
	playCutscene("Player_lvti")
end
