--!strict
-- SceneResolver — 编辑时把过场里的逻辑名解析成场景实例。
-- "Player":Play 模式用 LocalPlayer.Character;编辑期用 Workspace 具名 Rig,避免误绑到无关 Humanoid。

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local VCam = require(script.Parent.Shared.VCam)

local SceneResolver = {}

local IGNORE_MODEL_NAMES: { [string]: boolean } = {
	[VCam.CONTAINER] = true,
	AnimaCameraPath = true,
}

local function isPreviewTargetModel(model: Model): boolean
	if not model:IsDescendantOf(workspace) then
		return false
	end
	if IGNORE_MODEL_NAMES[model.Name] then
		return false
	end
	return model:FindFirstChildOfClass("Humanoid") ~= nil
end

-- 编辑期占位角色(勿扫全场景后代,否则会绑到 Boss/道具里的 Humanoid)。
function SceneResolver.placeholderRig(): Model?
	if RunService:IsRunning() then
		local lp = Players.LocalPlayer
		local char = lp and lp.Character
		if char and char:IsDescendantOf(workspace) and char:FindFirstChildOfClass("Humanoid") then
			return char
		end
	end
	for _, name in { "Player", "Rig", "Character" } do
		local inst = workspace:FindFirstChild(name)
		if inst and inst:IsA("Model") and isPreviewTargetModel(inst) then
			return inst
		end
	end
	for _, child in workspace:GetChildren() do
		if child:IsA("Model") and isPreviewTargetModel(child) then
			return child
		end
	end
	return nil
end

function SceneResolver.resolve(name: string): Instance?
	if name == "Camera" then
		return workspace.CurrentCamera
	end
	if name == "Player" then
		return SceneResolver.placeholderRig()
	end
	return workspace:FindFirstChild(name, true)
end

return SceneResolver
