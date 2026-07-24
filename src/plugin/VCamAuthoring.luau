--!strict
-- VCamAuthoring — 在场景里创建/管理"虚拟相机"实体(带 gizmo,可用 Studio 移动/旋转工具摆位)。
-- 位姿解析(名字→CFrame)复用 shared/VCam;这里只负责创建看得见、可操作的实体。

local Shared = script.Parent.Shared
local VCam = require(Shared.VCam)

local VCamAuthoring = {}

-- 生成一个不重复的 vcam 名字。
function VCamAuthoring.nextName(): string
	local i = 1
	while VCam.find("VCam" .. i) do
		i += 1
	end
	return "VCam" .. i
end

-- 给 gizmo 加一个朝向箭头(贴在 Front/-Z 面,标示相机看向)。
local function addArrow(part: BasePart)
	local tex = Instance.new("Texture")
	tex.Face = Enum.NormalId.Front
	tex.Texture = "rbxasset://textures/ui/Settings/Help/CursorImage.png"
	tex.StudsPerTileU = 2
	tex.StudsPerTileV = 2
	tex.Parent = part
end

-- 真视锥 wireframe(T9):从相机原点沿 -Z 展开的四棱锥线框,张角随 FOV attribute,
-- 宽高比按 16:9,远平面 6 studs。FOV 改变时整组重建。
local FRUSTUM_DEPTH = 6
local FRUSTUM_ASPECT = 16 / 9
local FRUSTUM_COLOR = Color3.fromRGB(120, 200, 255)

local function frustumLine(part: BasePart, folder: Folder, from: Vector3, to: Vector3)
	local line = Instance.new("LineHandleAdornment")
	line.Adornee = part
	line.CFrame = CFrame.lookAt(from, to)
	line.Length = (to - from).Magnitude
	line.Thickness = 2
	line.Color3 = FRUSTUM_COLOR
	line.Transparency = 0.25
	line.AlwaysOnTop = true
	line.ZIndex = 0
	line.Parent = folder
end

local function buildFrustum(part: BasePart)
	local old = part:FindFirstChild("FrustumLines")
	if old then
		old:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "FrustumLines"

	local fovAttr = part:GetAttribute("FOV")
	local fov = if typeof(fovAttr) == "number" then fovAttr :: number else 70
	local halfH = FRUSTUM_DEPTH * math.tan(math.rad(fov / 2))
	local halfW = halfH * FRUSTUM_ASPECT
	local origin = Vector3.zero
	local corners = {
		Vector3.new(-halfW, halfH, -FRUSTUM_DEPTH),
		Vector3.new(halfW, halfH, -FRUSTUM_DEPTH),
		Vector3.new(halfW, -halfH, -FRUSTUM_DEPTH),
		Vector3.new(-halfW, -halfH, -FRUSTUM_DEPTH),
	}
	for i, c in corners do
		frustumLine(part, folder, origin, c)
		frustumLine(part, folder, c, corners[i % 4 + 1])
	end
	folder.Parent = part
end

-- 确保 vcam 带视锥线框(create 时/面板打开时对存量 vcam 补建),并跟随 FOV 变化。
function VCamAuthoring.ensureFrustum(part: BasePart)
	if not part:FindFirstChild("FrustumLines") then
		buildFrustum(part)
		part:GetAttributeChangedSignal("FOV"):Connect(function()
			buildFrustum(part)
		end)
	end
end

-- 给 gizmo 加一个悬浮名字标签。
local function addLabel(part: BasePart, name: string)
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromOffset(120, 24)
	bb.StudsOffset = Vector3.new(0, 1.6, 0)
	bb.AlwaysOnTop = true
	bb.Parent = part
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Text = "🎥 " .. name
	label.TextColor3 = Color3.fromRGB(120, 200, 255)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 14
	label.Parent = bb
end

-- 创建一个 vcam 实体,放在给定位姿。返回其 Part。
function VCamAuthoring.create(name: string, cf: CFrame): BasePart
	local container = VCam.getContainer(true) :: Folder

	local part = Instance.new("Part")
	part.Name = name
	part.Size = Vector3.new(1.2, 1.2, 2) -- 长 Z 暗示朝向
	part.CFrame = cf
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 0.4
	part.Color = Color3.fromRGB(30, 90, 160)
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth

	addArrow(part)
	addLabel(part, name)
	VCamAuthoring.ensureFrustum(part)

	part.Parent = container
	return part
end

-- 设/清除某 vcam 的 LookAt 目标(空字符串=清除)。
function VCamAuthoring.setLookAt(name: string, targetName: string)
	local part = VCam.find(name)
	if part then
		part:SetAttribute("LookAt", targetName)
	end
end

return VCamAuthoring
