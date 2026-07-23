--!strict
-- CameraTrack — 运行时相机导演。逐帧把 workspace.CurrentCamera.CFrame 设为
-- CameraDirector 求值结果(每相机独立轨:覆盖 t 的相机轨中上层优先)。
-- 一整个 cutscene 只建一个 CameraTrack(不是每条 camera 轨一个)。
-- 镜头是每客户端本地的,所以过场必须在 client 端跑本轨道。

local CameraDirector = require(script.Parent.Parent.Shared.CameraDirector)
local CutsceneFormat = require(script.Parent.Parent.Shared.CutsceneFormat)

local CameraTrack = {}
CameraTrack.__index = CameraTrack

export type CameraTrack = typeof(setmetatable(
	{} :: {
		cutscene: CutsceneFormat.Cutscene,
		camera: Camera,
		_resolveBinding: CutsceneFormat.BindingResolver?,
		_prevType: Enum.CameraType?,
	},
	CameraTrack
))

function CameraTrack.new(
	cutscene: CutsceneFormat.Cutscene,
	camera: Camera,
	resolveBinding: CutsceneFormat.BindingResolver?
): CameraTrack
	return setmetatable({
		cutscene = cutscene,
		camera = camera,
		_resolveBinding = resolveBinding,
		_prevType = nil,
	}, CameraTrack)
end

-- 接管相机:切到 Scriptable,记住原类型以便还原。
function CameraTrack.begin(self: CameraTrack)
	self._prevType = self.camera.CameraType
	self.camera.CameraType = Enum.CameraType.Scriptable
end

-- 在时间 t 更新相机位姿(择一求值)。
function CameraTrack.update(self: CameraTrack, t: number)
	local cf = CameraDirector.evaluate(self.cutscene, t, self._resolveBinding)
	if cf then
		self.camera.CFrame = cf
	end
end

-- 归还相机控制权。
function CameraTrack.finish(self: CameraTrack)
	if self._prevType then
		self.camera.CameraType = self._prevType
	else
		self.camera.CameraType = Enum.CameraType.Custom
	end
end

return CameraTrack
