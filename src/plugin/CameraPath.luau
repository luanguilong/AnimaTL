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

local CameraPath = {}
CameraPath.__index = CameraPath

local FOLDER = "AnimaCameraPath"
local STEP = 0.1 -- 采样步长(秒)
local MAX_SEG = 240 -- 段数上限

-- 机位把手被 Studio 工具挪动后的回报(kfIndex = 选中相机轨 keyframes 里的序号)
export type HandleEdit = { kfIndex: number, cf: CFrame }

type Handle = { part: BasePart, lastCF: CFrame, kfIndex: number }

export type CameraPath = typeof(setmetatable(
	{} :: {
		folder: Folder,
		curve: Folder,
		markers: Folder,
		handles: Folder,
		head: BasePart,
		visible: boolean,
		_handles: { Handle },
	},
	CameraPath
))

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

	local head = newPart("Head", Vector3.new(0.7, 0.7, 0.7), Color3.fromRGB(255, 220, 60))
	head.Shape = Enum.PartType.Ball
	head.Parent = folder

	folder.Parent = workspace

	return setmetatable({
		folder = folder,
		curve = curve,
		markers = markers,
		handles = handles,
		head = head,
		visible = true,
		_handles = {},
	}, CameraPath)
end

-- 机位把手:可被 Studio 选中并用移动/旋转工具直接摆(反向编辑),
-- 与 newPart 的纯可视化部件不同 —— 不锁定、可点选;长方体让朝向可见。
local function newHandle(index: number): BasePart
	local p = Instance.new("Part")
	p.Name = "机位" .. index
	p.Size = Vector3.new(0.7, 0.7, 1.2)
	p.Color = Color3.fromRGB(90, 230, 200)
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

-- 选中某条相机轨:画该轨的运镜轨迹(蓝)+ 机位标记。
-- 未选中 / 非相机轨:画"整条成片运镜"(橙,全时间轴求值的最终镜头轨迹),
-- 让轨迹在场景里常驻可见,不会一取消选中就消失。
function CameraPath.rebuild(
	self: CameraPath,
	cutscene: CutsceneFormat.Cutscene,
	selected: CutsceneFormat.Track?
)
	self.curve:ClearAllChildren()
	self.markers:ClearAllChildren()

	if not selected or selected.kind ~= "camera" then
		-- 无选中轨 → 没有可编辑的机位,清掉把手
		for _, h in self._handles do
			h.part:Destroy()
		end
		table.clear(self._handles)
		local dur = cutscene.duration
		if dur > 0 then
			local n = math.clamp(math.floor(dur / STEP), 1, MAX_SEG)
			local composite = Color3.fromRGB(255, 170, 60)
			local prev: Vector3? = nil
			for i = 0, n do
				local cf = CameraDirector.evaluate(cutscene, dur * (i / n))
				if cf then
					if prev then
						connect(self.curve, prev, cf.Position, composite)
					end
					prev = cf.Position
				else
					prev = nil -- 无相机覆盖的时间段自然断开
				end
			end
		end
		return
	end
	local tr = selected
	local color = Color3.fromRGB(80, 160, 255)

	-- 曲线:沿该轨每个生效段 [from,to] 采样它自己的位姿(有 keyframes 则运动,否则静态/运动轨);段间断开
	for _, sgm in CutsceneFormat.segmentsOf(tr) do
		local span = math.max(sgm.to - sgm.from, 0)
		local n = math.clamp(math.floor(span / STEP), 1, MAX_SEG)
		local prev: Vector3? = nil
		for i = 0, n do
			local t = sgm.from + span * (i / n)
			local cf = CameraDirector.evaluate(cutscene, t)
			if cf then
				local pos = cf.Position
				if prev then
					connect(self.curve, prev, pos, color)
				end
				prev = pos
			else
				prev = nil
			end
		end
	end

	-- 机位把手:该轨每个关键帧一个,可用 Studio 移动/旋转工具直接摆(反向编辑)。
	-- 就地复用已有把手(拖拽中销毁重建会让 Studio 工具丢失目标),多退少补;
	-- 只有数据侧变了(undo / 面板编辑)才把位姿写回把手,不打断进行中的拖拽。
	local wanted: { { kfIndex: number, cf: CFrame } } = {}
	if tr.keyframes then
		for i, kf in tr.keyframes do
			if kf.value then
				table.insert(wanted, { kfIndex = i, cf = kf.value })
			end
		end
	end
	for i = #self._handles + 1, #wanted do
		local part = newHandle(i)
		part.Parent = self.handles
		self._handles[i] = { part = part, lastCF = CFrame.new(math.huge, 0, 0), kfIndex = 0 }
	end
	for i = #self._handles, #wanted + 1, -1 do
		self._handles[i].part:Destroy()
		self._handles[i] = nil
	end
	for i, w in wanted do
		local h = self._handles[i]
		h.kfIndex = w.kfIndex
		if cfDiffers(h.lastCF, w.cf) then
			h.part.CFrame = w.cf
			h.lastCF = w.cf
		end
		-- 朝向短杆(纯可视化,随重画刷新)
		local look = w.cf.Position - w.cf.LookVector * 1.6
		connect(self.markers, w.cf.Position, look, Color3.fromRGB(230, 200, 90))
	end
end

-- 收集自上次以来被 Studio 工具挪动过的把手(返回其关键帧序号 + 新位姿)。
-- 由 init 侧每帧调用并写回数据;lastCF 随之更新,写回后的 rebuild 不会回弹。
function CameraPath.consumeHandleEdits(self: CameraPath): { HandleEdit }
	local out: { HandleEdit } = {}
	for _, h in self._handles do
		if h.part.Parent and h.kfIndex > 0 and cfDiffers(h.lastCF, h.part.CFrame) then
			h.lastCF = h.part.CFrame
			table.insert(out, { kfIndex = h.kfIndex, cf = h.part.CFrame })
		end
	end
	return out
end

-- 每帧更新播放头处的滑动点。
function CameraPath.updateHead(self: CameraPath, cutscene: CutsceneFormat.Cutscene, t: number)
	local cf = CameraDirector.evaluate(cutscene, t)
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
