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
		active: boolean,
	},
	LivePreview
))

function LivePreview.new(): LivePreview
	return setmetatable({
		_conn = nil,
		_savedType = nil,
		_savedCF = nil,
		active = false,
	}, LivePreview)
end

-- 求某时刻的相机 CFrame(独立相机轨:覆盖 t 的上层轨上镜,见 CameraDirector)。
local function evalCamera(cutscene: CutsceneFormat.Cutscene, t: number): CFrame?
	local cf = CameraDirector.evaluate(cutscene, t)
	return cf
end

-- 应用一帧:相机 + transform 物体。
function LivePreview.applyFrame(getCutscene: () -> CutsceneFormat.Cutscene, getTime: () -> number)
	local cutscene = getCutscene()
	local t = getTime()
	local camCF = evalCamera(cutscene, t)
	if camCF then
		local cam = workspace.CurrentCamera
		if cam then
			cam.CFrame = camCF
		end
	end
	-- transform 轨道(不含相机)
	Preview.applyAt(cutscene, t, false)
end

-- 开启实时预览:接管相机,每帧驱动。
function LivePreview.start(
	self: LivePreview,
	getCutscene: () -> CutsceneFormat.Cutscene,
	getTime: () -> number
)
	if self.active then
		return
	end
	local cam = workspace.CurrentCamera
	if cam then
		self._savedType = cam.CameraType
		self._savedCF = cam.CFrame
		cam.CameraType = Enum.CameraType.Scriptable
	end
	self.active = true
	self._conn = RunService.RenderStepped:Connect(function()
		local ok, err = pcall(LivePreview.applyFrame, getCutscene, getTime)
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
	local cam = workspace.CurrentCamera
	if cam then
		cam.CameraType = self._savedType or Enum.CameraType.Custom
	end
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
