--!strict
-- VCam — 虚拟相机在场景中的表示与解析(编辑 & 运行时共用)。
--
-- vcam = workspace.AnimaVCams 下的一个隐形 Part:
--   Part.CFrame        → 相机位姿(相机看向 Part 的 Front/-Z 面)
--   Attribute "LookAt" → 可选,填一个目标物体名;有则相机自动看向该目标(位置)
--   Attribute "FOV"    → 可选,视野角
--
-- 只负责"名字 → 位姿"的解析;创建带 gizmo 的实体在 plugin/VCamAuthoring。

local VCam = {}

VCam.CONTAINER = "AnimaVCams"

-- 取(或按 create 创建)vcam 容器文件夹。
function VCam.getContainer(create: boolean): Folder?
	local existing = workspace:FindFirstChild(VCam.CONTAINER)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if create then
		local folder = Instance.new("Folder")
		folder.Name = VCam.CONTAINER
		folder.Parent = workspace
		return folder
	end
	return nil
end

-- 找到某个 vcam 的实体 Part。
function VCam.find(name: string): BasePart?
	local container = VCam.getContainer(false)
	if not container then
		return nil
	end
	local inst = container:FindFirstChild(name)
	if inst and inst:IsA("BasePart") then
		return inst
	end
	return nil
end

-- 解析某 vcam 此刻的相机位姿(含 LookAt)。找不到返回 nil。
function VCam.resolvePose(name: string): CFrame?
	local part = VCam.find(name)
	if not part then
		return nil
	end
	local lookAt = part:GetAttribute("LookAt")
	if typeof(lookAt) == "string" and lookAt ~= "" then
		local target = workspace:FindFirstChild(lookAt, true)
		if target and target:IsA("BasePart") then
			return CFrame.lookAt(part.Position, target.Position)
		elseif target and target:IsA("Model") then
			local ok, pivot = pcall(function()
				return target:GetPivot()
			end)
			if ok then
				return CFrame.lookAt(part.Position, pivot.Position)
			end
		end
	end
	return part.CFrame
end

-- 列出所有 vcam 名字。
function VCam.list(): { string }
	local names = {}
	local container = VCam.getContainer(false)
	if container then
		for _, child in container:GetChildren() do
			if child:IsA("BasePart") then
				table.insert(names, child.Name)
			end
		end
	end
	return names
end

return VCam
