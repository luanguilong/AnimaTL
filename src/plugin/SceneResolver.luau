--!strict
-- SceneResolver — 编辑时把过场里的逻辑名解析成场景实例。
-- "Player" 在编辑期没有真实玩家,用场景里的占位角色(第一个带 Humanoid 的 Model)代替。

local SceneResolver = {}

-- 场景里的占位角色(编辑期代表运行时的真实 Character)。
function SceneResolver.placeholderRig(): Model?
	for _, d in workspace:GetDescendants() do
		if d:IsA("Humanoid") and d.Parent and d.Parent:IsA("Model") then
			return d.Parent :: Model
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
