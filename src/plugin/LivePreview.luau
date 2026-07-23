--!strict
-- LivePreview — 编辑器实时预览(WYSIWYG)。
-- 打开后用 RenderStepped 持续把当前过场在 playhead 时刻求值,驱动:
--   · 编辑视口相机(workspace.CurrentCamera,Scriptable)
--   · transform 目标物体(门/Boss/任意物体)
-- 于是拖时间轴 / 挪 vcam,编辑界面立刻看到效果。关闭时恢复相机。

local RunService = game:GetService("RunService")

local Shared = script.Parent.Shared
local CameraDirector = require(Shared.CameraDirector)
local VCam = require(Shared.VCam)
local CutsceneFormat = require(Shared.CutsceneFormat)
local Preview = require(script.Parent.Preview)

local LivePreview = {}
LivePreview.__index = LivePreview

export type LivePreview = typeof(setmetatable(
	{} :: {
		_conn: RBXScriptConnection?,
		_savedType: Enum.CameraType?,
		_savedCF: CFrame?,
		_resolveBinding: CutsceneFormat.BindingResolver?,
		active: boolean,
	},
	LivePreview
))

function LivePreview.new(): LivePreview
	return setmetatable({
		_conn = nil,
		_savedType = nil,
		_savedCF = nil,
		_resolveBinding = nil,
		active = false,
	}, LivePreview)
end

-- 求某时刻的相机 CFrame(独立相机轨:覆盖 t 的上层轨上镜,见 CameraDirector)。
local function evalCamera(
	cutscene: CutsceneFormat.Cutscene,
	t: number,
	resolveBinding: CutsceneFormat.BindingResolver?
): (CFrame?, number?)
	local cf, name = CameraDirector.evaluate(cutscene, t, resolveBinding)
	local fov: number? = nil
	if name then
		local part = VCam.find(name)
		local f = part and part:GetAttribute("FOV")
		if typeof(f) == "number" then
			fov = f
		end
	end
	return cf, fov
end

-- 应用一帧:相机 + transform 物体。
function LivePreview.applyFrame(self: LivePreview, getCutscene: () -> CutsceneFormat.Cutscene, getTime: () -> number)
	local cutscene = getCutscene()
	local t = getTime()
	local camCF, fov = evalCamera(cutscene, t, self._resolveBinding)
	if camCF then
		local cam = workspace.CurrentCamera
		if cam then
			cam.CFrame = camCF
			if fov then
				cam.FieldOfView = fov
			end
		end
	end
	-- transform 轨道(不含相机)
	Preview.applyAt(cutscene, t, false)
end

-- 开启实时预览:接管相机,每帧驱动。
function LivePreview.start(
	self: LivePreview,
	getCutscene: () -> CutsceneFormat.Cutscene,
	getTime: () -> number,
	resolveBinding: CutsceneFormat.BindingResolver?
)
	if self.active then
		return
	end
	self._resolveBinding = resolveBinding
	local cam = workspace.CurrentCamera
	if cam then
		self._savedType = cam.CameraType
		self._savedCF = cam.CFrame
		cam.CameraType = Enum.CameraType.Scriptable
	end
	self.active = true
	self._conn = RunService.RenderStepped:Connect(function()
		local ok, err = pcall(function()
			self:applyFrame(getCutscene, getTime)
		end)
		if not ok then
			warn("[anima] 预览帧出错:", err)
		end
	end)
end

-- 关闭实时预览:恢复相机控制。
function LivePreview.stop(self: LivePreview)
	if not self.active then
		return
	end
	self.active = false
	if self._conn then
		self._conn:Disconnect()
		self._conn = nil
	end
	self._resolveBinding = nil
	local cam = workspace.CurrentCamera
	if cam then
		cam.CameraType = self._savedType or Enum.CameraType.Custom
	end
	Preview.clearAnimationCache()
end

-- 一次性把视口相机跳到"某 vcam 此刻的位姿"(取景用,不需开预览)。
function LivePreview.lookThrough(vcamName: string): boolean
	local cf = VCam.resolvePose(vcamName)
	local cam = workspace.CurrentCamera
	if cf and cam then
		cam.CFrame = cf
		return true
	end
	return false
end

return LivePreview
