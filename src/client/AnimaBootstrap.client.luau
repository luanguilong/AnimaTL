--!strict
-- AnimaBootstrap — 进游戏按 V 播放 Player_lvti。
-- 依赖: ReplicatedStorage.Anima(Runtime + Cutscenes.Player_lvti)、ForgeVFX、场景 vcam。

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Anima = ReplicatedStorage:WaitForChild("Anima")
local CutscenePlayer = require(Anima.Runtime.CutscenePlayer)
local ForgeEffectPlay = require(Anima.Shared.ForgeEffectPlay)

local CUTSCENE_MODULE_NAME = "Player_lvti"
local VFX_PACK_NAME = "驴踢"
local PLAY_KEY = Enum.KeyCode.V
local PLAY_ACTION = "AnimaPlayPlayerLvTi"

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

local function loadCutsceneModule(): ModuleScript?
	local cutscenes = Anima:WaitForChild("Cutscenes")
	local mod = cutscenes:FindFirstChild(CUTSCENE_MODULE_NAME)
	if mod and mod:IsA("ModuleScript") then
		return mod
	end
	warn(
		`[anima] 缺少 Cutscenes.{CUTSCENE_MODULE_NAME} — 请在 Timeline 💾 导出模块名 {CUTSCENE_MODULE_NAME}`
	)
	return nil
end

local function playPlayerLvTi()
	if activeCutscenePlayer and activeCutscenePlayer._playing then
		return
	end
	local char = localPlayer.Character
	if not char then
		warn("[anima] 角色未就绪,无法播放过场")
		return
	end
	attachVfxPackToCharacter(char)

	local mod = loadCutsceneModule()
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
		print(`[anima] {CUTSCENE_MODULE_NAME} 播放完成`)
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

ContextActionService:BindAction(PLAY_ACTION, function(_name, inputState)
	if inputState == Enum.UserInputState.Begin then
		playPlayerLvTi()
	end
	return Enum.ContextActionResult.Pass
end, false, PLAY_KEY)

-- selene: allow(global_usage)
_G.AnimaPlayPlayerLvTi = playPlayerLvTi
-- selene: allow(global_usage) -- 刻意暴露的调试入口
_G.AnimaPlayRig1LvTi = playPlayerLvTi
-- selene: allow(global_usage)
_G.AnimaPlayBossIntro = playPlayerLvTi

print(
	`[anima] 进游戏按 {PLAY_KEY.Name} 播放 {CUTSCENE_MODULE_NAME} · 或 _G.AnimaPlayPlayerLvTi()`
)
