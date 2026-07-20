--!strict
-- AnimaBootstrap — client 端示例启动脚本(放在 StarterPlayerScripts)。
-- 演示如何:构造 BindingResolver(把 "Player" 解析成本地真实 Character)、
-- 注册事件 handler、播放 boss_intro。
--
-- 这是"消费者"示例;正式游戏里由你自己的战斗/剧情流程在合适时机调用。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Anima = ReplicatedStorage:WaitForChild("Anima")
local CutscenePlayer = require(Anima.Runtime.CutscenePlayer)

local localPlayer = Players.LocalPlayer

local function waitForCharacter(): Model
	local char = localPlayer.Character or localPlayer.CharacterAdded:Wait()
	char:WaitForChild("Humanoid")
	return char
end

-- BindingResolver:逻辑名 → 真实实例。
-- "Player" 给本地真实 Character(装扮自动跟随);其余去 workspace 找同名物体。
local function makeResolver(): (name: string) -> Instance?
	local character = waitForCharacter()
	return function(name: string): Instance?
		if name == "Player" then
			return character
		end
		if name == "Camera" then
			return workspace.CurrentCamera
		end
		return workspace:FindFirstChild(name, true)
	end
end

-- 事件 handler 示例:这里只打印;真实项目里接音效/粒子/UI。
local function onEvent(event, _target)
	print(`[anima] >>> {event.name}`, event.payload)
end

-- 手动触发一次(演示)。真实项目请在需要时调用。
local function playBossIntro()
	local cutscene = require(Anima.Cutscenes.boss_intro)
	local player = CutscenePlayer.new(cutscene, {
		resolver = makeResolver(),
		camera = workspace.CurrentCamera,
		onEvent = onEvent,
	})
	player:play(function()
		print("[anima] boss_intro 播放完成")
	end)
end

-- 暴露到 _G 方便在 Studio 命令栏 / MCP 里手动触发:_G.AnimaPlayBossIntro()
-- selene: allow(global_usage)
_G.AnimaPlayBossIntro = playBossIntro

print("[anima] client bootstrap ready — 调用 _G.AnimaPlayBossIntro() 播放")
