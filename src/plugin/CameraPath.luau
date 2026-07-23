--!strict
-- CameraPath — 在 3D 视口里可视化运镜轨迹(类 Cinemachine dolly track)。
--
-- 沿时间轴等步长采样相机 CFrame(CameraDirector),把相邻采样点连成一条发光曲线;
-- 每个 vcam 机位画一个球 + 朝向短杆;播放头处画一个滑动的高亮点。
-- 全部实体放在 workspace.AnimaCameraPath 下(锁定、不可查询、不可归档),
-- 导出/发布时忽略。revision 变化时重画曲线,每帧只挪当前点。

local Shared = script.Parent.Shared
local CameraDirector = require(Shared.CameraDirector)
local CutsceneFormat = require(Shared.CutsceneFormat)
local FollowAnchor = require(Shared.FollowAnchor)
local VCamPose = require(Shared.VCamPose)
local SceneResolver = require(script.Parent.SceneResolver)
local PathPreviewPrefs = require(script.Parent.PathPreviewPrefs)

local CameraPath = {}
CameraPath.__index = CameraPath

local FOLDER = "AnimaCameraPath"
local STEP = 0.1 -- 采样步长(秒)

-- 机位把手被 Studio 工具挪动后的回报(指向具体轨 + keyframes 序号)
export type HandleEdit = { track: CutsceneFormat.Track, kfIndex: number, cf: CFrame }

export type TangentEdit = {
	track: CutsceneFormat.Track,
	kfIndex: number,
	field: "out" | "in",
	worldControl: Vector3,
}

export type RebuildOpts = {
	hideTangentGizmos: boolean?,
	previewPrefs: PathPreviewPrefs.Prefs?,
}

type TangentHandle = {
	part: BasePart,
	lastPos: Vector3,
	kfIndex: number,
	field: "out" | "in",
	track: CutsceneFormat.Track,
}

type Handle = {
	part: BasePart,
	lastCF: CFrame,
	kfIndex: number,
	track: CutsceneFormat.Track,
}

export type CameraPath = typeof(setmetatable(
	{} :: {
		folder: Folder,
		curve: Folder,
		markers: Folder,
		handles: Folder,
		tangentArms: Folder,
		tangentHandles: Folder,
		head: BasePart,
		visible: boolean,
		_hideTangentGizmos: boolean,
		_handles: { Handle },
		_tangentHandles: { TangentHandle },
	},
	CameraPath
))

local COLOR_CURVE = Color3.fromRGB(80, 160, 255)
local COLOR_HANDLE_CAM = Color3.fromRGB(90, 230, 200)
local COLOR_HANDLE_MOVE = Color3.fromRGB(210, 140, 255)
local COLOR_COMPOSITE = Color3.fromRGB(255, 170, 60)
local COLOR_TANGENT_ARM = Color3.fromRGB(140, 140, 160)
local COLOR_TANGENT_OUT = Color3.fromRGB(255, 120, 180)
local COLOR_TANGENT_IN = Color3.fromRGB(120, 200, 255)

local function isVcamRelatedTrack(tr: CutsceneFormat.Track?): boolean
	return tr ~= nil and (tr.kind == "camera" or tr.kind == "cameraMove") and tr.target ~= ""
end

local function findCameraTrackForTarget(
	cutscene: CutsceneFormat.Cutscene,
	name: string
): CutsceneFormat.Track?
	for _, tr in cutscene.tracks do
		if tr.kind == "camera" and tr.target == name then
			return tr
		end
	end
	return nil
end

-- 在某 camera 轨生效段内,该 vcam 此刻的位姿(轨上 key 优先,否则 cameraMove / 静态机位)。
local function poseOnCameraTrack(
	cutscene: CutsceneFormat.Cutscene,
	camTr: CutsceneFormat.Track,
	t: number
): CFrame?
	return CameraDirector.poseForCameraTrack(cutscene, camTr, t, SceneResolver.resolve)
end

local HANDLE_POS_EPS = 0.01
local HANDLE_ROT_EPS = 0.005

local function cfDiffers(a: CFrame, b: CFrame): boolean
	-- UpVector 一并比较,绕镜头轴的纯滚转(dutch angle)才检测得到
	return (a.Position - b.Position).Magnitude > HANDLE_POS_EPS
		or (a.LookVector - b.LookVector).Magnitude > HANDLE_ROT_EPS
		or (a.UpVector - b.UpVector).Magnitude > HANDLE_ROT_EPS
end

local function newPart(name: string, size: Vector3, color: Color3): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = Enum.Material.Neon
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Locked = true
	p.Archivable = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	return p
end

function CameraPath.new(): CameraPath
	-- 清掉上一次残留
	local old = workspace:FindFirstChild(FOLDER)
	if old then
		old:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = FOLDER
	folder.Archivable = false

	local curve = Instance.new("Folder")
	curve.Name = "Curve"
	curve.Parent = folder

	local markers = Instance.new("Folder")
	markers.Name = "Markers"
	markers.Parent = folder

	local handles = Instance.new("Folder")
	handles.Name = "Handles"
	handles.Parent = folder

	local tangentArms = Instance.new("Folder")
	tangentArms.Name = "TangentArms"
	tangentArms.Parent = folder

	local tangentHandles = Instance.new("Folder")
	tangentHandles.Name = "TangentHandles"
	tangentHandles.Parent = folder

	local head = newPart("Head", Vector3.new(0.7, 0.7, 0.7), Color3.fromRGB(255, 220, 60))
	head.Shape = Enum.PartType.Ball
	head.Parent = folder

	folder.Parent = workspace

	return setmetatable({
		folder = folder,
		curve = curve,
		markers = markers,
		handles = handles,
		tangentArms = tangentArms,
		tangentHandles = tangentHandles,
		head = head,
		visible = true,
		_hideTangentGizmos = false,
		_handles = {},
		_tangentHandles = {},
	}, CameraPath)
end

-- 机位把手:可被 Studio 选中并用移动/旋转工具直接摆(反向编辑),
-- 与 newPart 的纯可视化部件不同 —— 不锁定、可点选;长方体让朝向可见。
local function newHandle(label: string, color: Color3): BasePart
	local p = Instance.new("Part")
	p.Name = label
	p.Size = Vector3.new(0.7, 0.7, 1.2)
	p.Color = color
	p.Material = Enum.Material.Neon
	p.Transparency = 0.15
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = true
	p.CanTouch = false
	p.Locked = false
	p.Archivable = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	return p
end

-- 连接两点成一段发光线。
local function connect(parent: Instance, a: Vector3, b: Vector3, color: Color3)
	local dist = (b - a).Magnitude
	if dist < 1e-3 then
		return
	end
	local seg = newPart("Seg", Vector3.new(0.12, 0.12, dist), color)
	seg.CFrame = CFrame.lookAt((a + b) / 2, b)
	seg.Parent = parent
end

local function newTangentHandle(label: string, color: Color3): BasePart
	local p = Instance.new("Part")
	p.Name = label
	p.Size = Vector3.new(0.45, 0.45, 0.45)
	p.Shape = Enum.PartType.Ball
	p.Color = color
	p.Material = Enum.Material.Neon
	p.Transparency = 0.1
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = true
	p.CanTouch = false
	p.Locked = false
	p.Archivable = false
	return p
end

local function controlWorld(
	track: CutsceneFormat.Track,
	storedCf: CFrame,
	storedOffset: Vector3?,
	resolveBinding: CutsceneFormat.BindingResolver
): (Vector3, Vector3)
	local worldAnchor = FollowAnchor.worldFromKeyframeCFrame(track, storedCf, resolveBinding)
	local p0 = worldAnchor.Position
	local delta = FollowAnchor.storedOffsetToWorldDelta(track, storedOffset or Vector3.zero, resolveBinding)
	return p0, p0 + delta
end

local function posDiffers(a: Vector3, b: Vector3): boolean
	return (a - b).Magnitude > HANDLE_POS_EPS
end

-- 选中 camera / cameraMove(同 target):合并蓝线 + 两轨关键帧把手(分色)。
-- 未选中 / 非相机相关轨:画整条成片运镜(橙)。
function CameraPath.rebuild(
	self: CameraPath,
	cutscene: CutsceneFormat.Cutscene,
	selected: CutsceneFormat.Track?,
	opts: RebuildOpts?
)
	local previewPrefs = if opts and opts.previewPrefs then opts.previewPrefs else nil
	self.curve:ClearAllChildren()
	self.markers:ClearAllChildren()
	self.tangentArms:ClearAllChildren()

	if not isVcamRelatedTrack(selected) then
		for _, h in self._handles do
			h.part:Destroy()
		end
		table.clear(self._handles)
		for _, th in self._tangentHandles do
			th.part:Destroy()
		end
		table.clear(self._tangentHandles)
		local dur = cutscene.duration
		if dur > 0 then
			local n = PathPreviewPrefs.sampleCountForSpan(dur, STEP, previewPrefs)
			local prev: Vector3? = nil
			for i = 0, n do
				local cf = CameraDirector.evaluate(cutscene, dur * (i / n), SceneResolver.resolve)
				if cf then
					if prev then
						connect(self.curve, prev, cf.Position, COLOR_COMPOSITE)
					end
					prev = cf.Position
				else
					prev = nil
				end
			end
		end
		return
	end

	local tr = selected :: CutsceneFormat.Track
	local vcamName = tr.target
	local camTr = if tr.kind == "camera" then tr else findCameraTrackForTarget(cutscene, vcamName)
	local sampleStep = STEP
	if tr.pathMode == "bezier" or (camTr and camTr.pathMode == "bezier") then
		sampleStep = STEP * 0.5
	end

	local spans: { { from: number, to: number } } = {}
	if camTr then
		for _, s in CutsceneFormat.segmentsOf(camTr) do
			table.insert(spans, { from = s.from, to = s.to })
		end
	elseif tr.kind == "cameraMove" then
		table.insert(spans, { from = 0, to = cutscene.duration })
	end

	for _, sgm in spans do
		local span = math.max(sgm.to - sgm.from, 0)
		local n = PathPreviewPrefs.sampleCountForSpan(span, sampleStep, previewPrefs)
		local prev: Vector3? = nil
		for i = 0, n do
			local t = sgm.from + span * (i / n)
			local cf: CFrame? = nil
			if camTr then
				cf = poseOnCameraTrack(cutscene, camTr, t)
			else
				cf = VCamPose.at(cutscene, vcamName, t)
			end
			if cf then
				local pos = cf.Position
				if prev then
					connect(self.curve, prev, pos, COLOR_CURVE)
				end
				prev = pos
			else
				prev = nil
			end
		end
	end

	type Wanted = { track: CutsceneFormat.Track, kfIndex: number, cf: CFrame, kind: string }
	local wanted: { Wanted } = {}
	for _, track in cutscene.tracks do
		if (track.kind == "camera" or track.kind == "cameraMove") and track.target == vcamName then
			if track.keyframes then
				for i, kf in track.keyframes do
					if kf.value then
						local worldCf = FollowAnchor.worldFromKeyframeCFrame(
							track,
							kf.value,
							SceneResolver.resolve
						)
						table.insert(wanted, {
							track = track,
							kfIndex = i,
							cf = worldCf,
							kind = track.kind,
						})
					end
				end
			end
		end
	end

	for i = #self._handles + 1, #wanted do
		local w = wanted[i]
		local color = if w.kind == "cameraMove" then COLOR_HANDLE_MOVE else COLOR_HANDLE_CAM
		local prefix = if w.kind == "cameraMove" then "运镜" else "机位"
		local part = newHandle(prefix .. w.kfIndex, color)
		part.Parent = self.handles
		self._handles[i] = {
			part = part,
			lastCF = CFrame.new(math.huge, 0, 0),
			kfIndex = 0,
			track = w.track,
		}
	end
	for i = #self._handles, #wanted + 1, -1 do
		self._handles[i].part:Destroy()
		self._handles[i] = nil
	end
	for i, w in wanted do
		local h = self._handles[i]
		h.kfIndex = w.kfIndex
		h.track = w.track
		local color = if w.kind == "cameraMove" then COLOR_HANDLE_MOVE else COLOR_HANDLE_CAM
		h.part.Color = color
		h.part.Name = (if w.kind == "cameraMove" then "运镜" else "机位") .. w.kfIndex
		if cfDiffers(h.lastCF, w.cf) then
			h.part.CFrame = w.cf
			h.lastCF = w.cf
		end
		local look = w.cf.Position - w.cf.LookVector * 1.6
		connect(self.markers, w.cf.Position, look, Color3.fromRGB(230, 200, 90))
	end

	type TanWanted = {
		track: CutsceneFormat.Track,
		kfIndex: number,
		field: "out" | "in",
		pos: Vector3,
		color: Color3,
	}
	local tanWanted: { TanWanted } = {}
	local hideTangents = if opts then opts.hideTangentGizmos == true else false
	if not hideTangents then
		for _, track in cutscene.tracks do
			if
				(track.kind == "camera" or track.kind == "cameraMove")
				and track.target == vcamName
				and track.pathMode == "bezier"
				and track.keyframes
			then
				for i, kf in track.keyframes do
					if kf.value then
						local anchorPos, outPos =
							controlWorld(track, kf.value, kf.outTangent, SceneResolver.resolve)
						connect(self.tangentArms, anchorPos, outPos, COLOR_TANGENT_ARM)
						table.insert(tanWanted, {
							track = track,
							kfIndex = i,
							field = "out",
							pos = outPos,
							color = COLOR_TANGENT_OUT,
						})
						local _, inPos = controlWorld(track, kf.value, kf.inTangent, SceneResolver.resolve)
						connect(self.tangentArms, anchorPos, inPos, COLOR_TANGENT_ARM)
						table.insert(tanWanted, {
							track = track,
							kfIndex = i,
							field = "in",
							pos = inPos,
							color = COLOR_TANGENT_IN,
						})
					end
				end
			end
		end
	end

	for i = #self._tangentHandles + 1, #tanWanted do
		local w = tanWanted[i]
		local label = if w.field == "out" then "切线出" else "切线入"
		local part = newTangentHandle(label .. w.kfIndex, w.color)
		part.Parent = self.tangentHandles
		self._tangentHandles[i] = {
			part = part,
			lastPos = Vector3.new(math.huge, 0, 0),
			kfIndex = 0,
			field = w.field,
			track = w.track,
		}
	end
	for i = #self._tangentHandles, #tanWanted + 1, -1 do
		self._tangentHandles[i].part:Destroy()
		self._tangentHandles[i] = nil
	end
	for i, w in tanWanted do
		local th = self._tangentHandles[i]
		th.kfIndex = w.kfIndex
		th.field = w.field
		th.track = w.track
		th.part.Color = w.color
		th.part.Name = (if w.field == "out" then "切线出" else "切线入") .. w.kfIndex
		if posDiffers(th.lastPos, w.pos) then
			th.part.CFrame = CFrame.new(w.pos)
			th.lastPos = w.pos
		end
	end
end

-- 收集自上次以来被 Studio 工具挪动过的把手(返回其关键帧序号 + 新位姿)。
-- 由 init 侧每帧调用并写回数据;lastCF 随之更新,写回后的 rebuild 不会回弹。
function CameraPath.consumeHandleEdits(self: CameraPath): { HandleEdit }
	local out: { HandleEdit } = {}
	for _, h in self._handles do
		if h.part.Parent and h.kfIndex > 0 and cfDiffers(h.lastCF, h.part.CFrame) then
			h.lastCF = h.part.CFrame
			table.insert(out, { track = h.track, kfIndex = h.kfIndex, cf = h.part.CFrame })
		end
	end
	return out
end

function CameraPath.consumeTangentEdits(self: CameraPath): { TangentEdit }
	local out: { TangentEdit } = {}
	for _, th in self._tangentHandles do
		if th.part.Parent and th.kfIndex > 0 and posDiffers(th.lastPos, th.part.Position) then
			th.lastPos = th.part.Position
			table.insert(out, {
				track = th.track,
				kfIndex = th.kfIndex,
				field = th.field,
				worldControl = th.part.Position,
			})
		end
	end
	return out
end

-- 每帧更新播放头处的滑动点。
function CameraPath.updateHead(self: CameraPath, cutscene: CutsceneFormat.Cutscene, t: number)
	local cf = CameraDirector.evaluate(cutscene, t, SceneResolver.resolve)
	if cf then
		self.head.Transparency = 0
		self.head.CFrame = CFrame.new(cf.Position)
	else
		self.head.Transparency = 1
	end
end

function CameraPath.setVisible(self: CameraPath, visible: boolean)
	self.visible = visible
	self.folder.Parent = if visible then workspace else nil
end

function CameraPath.destroy(self: CameraPath)
	self.folder:Destroy()
end

return CameraPath
