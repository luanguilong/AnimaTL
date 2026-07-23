--!strict
-- ForgeApproxFx — 编辑期对 Forge 高级组件(mesh 特效 / 属性 tweener)的近似回放。
-- 独立实现,只依赖 Forge 的属性/结构约定(Start/End、EmitDelay、_END_VALUE 等),
-- 不加载官方模块(VFX-DL 禁止插件加载)。mesh 克隆是普通 Part 动画,
-- 因此在 ViewportFrame 小窗里也能渲染(粒子/Beam 则是引擎级不支持)。

local RunService = game:GetService("RunService")

local ForgeApproxFx = {}

export type EmitOpts = {
	-- scrub 停止/回退后返回 false,所有延迟与动画立即中止
	isLive: () -> boolean,
	-- 注册停止时的清理(EffectTrack 在 stop 时逐个 pcall)
	addCleanup: (fn: () -> ()) -> (),
	-- mesh 克隆生成时回调(EffectTrack 用来记录 _spawned + 触发克隆里的粒子)
	onSpawn: ((clone: BasePart) -> ())?,
}

local function attrNumber(inst: Instance, name: string): number?
	local v = inst:GetAttribute(name)
	if typeof(v) == "number" then
		return v
	end
	return nil
end

-- Forge 的时长属性可能是 number 或 NumberRange(随机区间);预览取中值求稳定
local function attrDuration(inst: Instance, name: string): number?
	local v = inst:GetAttribute(name)
	if typeof(v) == "number" then
		return v
	end
	if typeof(v) == "NumberRange" then
		return (v.Min + v.Max) / 2
	end
	return nil
end

function ForgeApproxFx.isMeshVfx(inst: Instance): boolean
	if not inst:IsA("Model") then
		return false
	end
	local start = inst:FindFirstChild("Start")
	local goal = inst:FindFirstChild("End")
	return start ~= nil and start:IsA("BasePart") and goal ~= nil and goal:IsA("BasePart")
end

-- 克隆的挂点:小窗预览时必须挂回 WorldModel(ViewportFrame 只渲染自身子树)
local function containerFor(inst: Instance): Instance
	return inst:FindFirstAncestorOfClass("WorldModel") or workspace
end

local function lerpNumber(a: number, b: number, alpha: number): number
	return a + (b - a) * alpha
end

-- mesh 特效:克隆 Start,EffectDuration 内插值到 End 的 CFrame/Size/网格缩放/透明度。
-- 简化:线性缓动;忽略 SpreadAngle/旋速/随机器;EmitCount>1 因无随机差异只放一份。
function ForgeApproxFx.emitMesh(model: Model, opts: EmitOpts)
	local start = model:FindFirstChild("Start")
	local goal = model:FindFirstChild("End")
	if not (start and goal and start:IsA("BasePart") and goal:IsA("BasePart")) then
		return
	end
	-- Enabled=true 的常驻型 mesh 由 Forge 常驻系统驱动,不属于一次性 emit
	if model:GetAttribute("Enabled") == true then
		return
	end

	local delay = attrNumber(model, "EmitDelay") or 0
	local duration = attrDuration(model, "EffectDuration") or attrDuration(model, "Duration") or 1
	duration = math.max(duration, 0.05)

	local tpDefault = if start:FindFirstChildOfClass("Decal") then 1 else 0
	local tpStart = attrNumber(model, "Part_Transparency_Start")
		or attrNumber(model, "Mesh_StartTransparency")
		or tpDefault
	local tpEnd = attrNumber(model, "Part_Transparency_End")
		or attrNumber(model, "Mesh_EndTransparency")
		or tpDefault
	local decalStart = attrNumber(model, "Decal_StartTransparency") or 0
	local decalEnd = attrNumber(model, "Decal_EndTransparency") or 1

	local function spawn()
		if not opts.isLive() or not start.Parent then
			return
		end
		local clone = start:Clone()
		clone.Name = "AnimaForgeMeshPreview"
		clone.Archivable = false
		clone.Anchored = true
		clone.CanCollide = false
		clone.CanQuery = false
		clone.CanTouch = false
		clone.CastShadow = false
		clone.Transparency = tpStart

		local startCF = start.CFrame
		local goalOffset = startCF:ToObjectSpace(goal.CFrame)
		local sizeStart, sizeEnd = start.Size, goal.Size

		local cloneMesh = clone:FindFirstChildOfClass("SpecialMesh")
		local meshScaleStart: Vector3? = nil
		local meshScaleEnd: Vector3? = nil
		do
			local sm = start:FindFirstChildOfClass("SpecialMesh")
			local gm = goal:FindFirstChildOfClass("SpecialMesh")
			if cloneMesh and sm and gm then
				meshScaleStart, meshScaleEnd = sm.Scale, gm.Scale
			end
		end

		local decals: { Decal } = {}
		for _, d in clone:GetDescendants() do
			if d:IsA("Decal") then
				d.Transparency = decalStart
				table.insert(decals, d)
			end
		end

		clone.Parent = containerFor(model)
		if opts.onSpawn then
			opts.onSpawn(clone)
		end

		local t0 = os.clock()
		local conn: RBXScriptConnection? = nil
		local function finish()
			if conn then
				conn:Disconnect()
				conn = nil
			end
			clone:Destroy()
		end
		conn = RunService.Heartbeat:Connect(function()
			if not opts.isLive() or not clone.Parent then
				finish()
				return
			end
			local alpha = math.clamp((os.clock() - t0) / duration, 0, 1)
			clone.CFrame = startCF * CFrame.new():Lerp(goalOffset, alpha)
			clone.Size = sizeStart:Lerp(sizeEnd, alpha)
			clone.Transparency = lerpNumber(tpStart, tpEnd, alpha)
			if cloneMesh and meshScaleStart and meshScaleEnd then
				cloneMesh.Scale = meshScaleStart:Lerp(meshScaleEnd, alpha)
			end
			for _, d in decals do
				d.Transparency = lerpNumber(decalStart, decalEnd, alpha)
			end
			if alpha >= 1 then
				finish()
			end
		end)
		opts.addCleanup(finish)
	end

	if delay > 0 then
		task.delay(delay, spawn)
	else
		spawn()
	end
end

local function tweenerTarget(rv: RayValue): Instance?
	local objectValue = rv:FindFirstChildOfClass("ObjectValue")
	if objectValue and objectValue.Value then
		return objectValue.Value
	end
	local parent = rv.Parent
	while parent and parent:IsA("Folder") do
		parent = parent.Parent
	end
	return parent
end

local function lerpValue(a: any, b: any, alpha: number): any
	if typeof(a) == "number" then
		return lerpNumber(a, b, alpha)
	end
	local ok, v = pcall(function()
		return (a :: any):Lerp(b, alpha)
	end)
	if ok then
		return v
	end
	-- 不可插值类型(bool/string 等):走到一半直接切终值
	return if alpha >= 0.5 then b else a
end

-- 属性 tweener:RayValue 名=目标属性/Attribute 名,_END_VALUE=终值,
-- Duration 内从当前值 tween 过去,ResetOnFinish(缺省 true)结束还原。
-- 震屏(CameraShake)与随机器不做编辑期预览。
function ForgeApproxFx.emitTweener(rv: RayValue, opts: EmitOpts)
	if rv:HasTag("CameraShake") or rv:HasTag("PropertyRandomizer") or rv:HasTag("AttributeRandomizer") then
		return
	end
	local isAttribute = rv:HasTag("AttributeTweener")
	local target = tweenerTarget(rv)
	if not target then
		return
	end
	local name = rv.Name
	local endValue = rv:GetAttribute("_END_VALUE")
	if endValue == nil then
		return
	end
	local delay = attrNumber(rv, "EmitDelay") or 0
	local reset = rv:GetAttribute("ResetOnFinish") ~= false
	local duration = math.max(attrDuration(rv, "Duration") or 1, 0.05)

	local function run()
		if not opts.isLive() or not target.Parent then
			return
		end
		local startValue: any
		if isAttribute then
			startValue = target:GetAttribute(name)
		else
			local ok, v = pcall(function()
				return (target :: any)[name]
			end)
			if not ok then
				return
			end
			startValue = v
		end
		local override = rv:GetAttribute("_START_VALUE")
		if override ~= nil then
			startValue = override
		end
		if typeof(startValue) ~= typeof(endValue) then
			return
		end

		local function setValue(v: any)
			pcall(function()
				if isAttribute then
					target:SetAttribute(name, v)
				else
					(target :: any)[name] = v
				end
			end)
		end

		local restored = false
		local function restore()
			if restored then
				return
			end
			restored = true
			setValue(startValue)
		end
		-- scrub 停止时无条件还原(哪怕 ResetOnFinish=false,编辑期不能留脏状态)
		opts.addCleanup(restore)

		local t0 = os.clock()
		local conn: RBXScriptConnection? = nil
		conn = RunService.Heartbeat:Connect(function()
			if not opts.isLive() or not target.Parent then
				if conn then
					conn:Disconnect()
				end
				restore()
				return
			end
			local alpha = math.clamp((os.clock() - t0) / duration, 0, 1)
			setValue(lerpValue(startValue, endValue, alpha))
			if alpha >= 1 then
				if conn then
					conn:Disconnect()
				end
				if reset then
					restore()
				end
			end
		end)
	end

	if delay > 0 then
		task.delay(delay, run)
	else
		run()
	end
end

-- ============================================================
-- 小窗粒子模拟:ViewportFrame 渲染不了 ParticleEmitter/Beam,
-- 用"贴图面片 + 每帧朝向小窗相机 + 按发射器参数模拟运动"近似。
-- 仅在发射器位于 ViewportFrame/WorldModel 内时使用;主视口走真粒子。
-- ============================================================

local MAX_SPRITES = 240 -- 全局面片预算,防 scrub 连发拖垮编辑器
local _activeSprites = 0

local function evalNumberSequence(seq: NumberSequence, alpha: number): number
	local kps = seq.Keypoints
	if alpha <= kps[1].Time then
		return kps[1].Value
	end
	for i = 1, #kps - 1 do
		local a, b = kps[i], kps[i + 1]
		if alpha >= a.Time and alpha <= b.Time then
			local span = b.Time - a.Time
			local f = if span > 0 then (alpha - a.Time) / span else 0
			return lerpNumber(a.Value, b.Value, f)
		end
	end
	return kps[#kps].Value
end

local function evalColorSequence(seq: ColorSequence, alpha: number): Color3
	local kps = seq.Keypoints
	if alpha <= kps[1].Time then
		return kps[1].Value
	end
	for i = 1, #kps - 1 do
		local a, b = kps[i], kps[i + 1]
		if alpha >= a.Time and alpha <= b.Time then
			local span = b.Time - a.Time
			local f = if span > 0 then (alpha - a.Time) / span else 0
			return a.Value:Lerp(b.Value, f)
		end
	end
	return kps[#kps].Value
end

local function emitterWorldCFrame(emitter: ParticleEmitter): CFrame?
	local p = emitter.Parent
	if p and p:IsA("Attachment") then
		return p.WorldCFrame
	end
	if p and p:IsA("BasePart") then
		return p.CFrame
	end
	return nil
end

local EMISSION_DIR: { [Enum.NormalId]: Vector3 } = {
	[Enum.NormalId.Top] = Vector3.yAxis,
	[Enum.NormalId.Bottom] = -Vector3.yAxis,
	[Enum.NormalId.Front] = -Vector3.zAxis,
	[Enum.NormalId.Back] = Vector3.zAxis,
	[Enum.NormalId.Right] = Vector3.xAxis,
	[Enum.NormalId.Left] = -Vector3.xAxis,
}

local function viewportCameraFor(inst: Instance): Camera?
	local vf = inst:FindFirstAncestorOfClass("ViewportFrame")
	return if vf then vf.CurrentCamera else nil
end

type Sprite = {
	part: BasePart,
	decal: Decal?,
	pos: Vector3,
	vel: Vector3,
	life: number,
	age: number,
}

-- 在小窗 WorldModel 里按发射器参数模拟一次爆发。真粒子的完整语义
-- (Drag/RotSpeed/Squash/Flipbook/LockedToPart)不做,取形似:
-- 贴图/颜色/大小/透明度序列 + Speed/SpreadAngle/EmissionDirection/Acceleration/Lifetime。
function ForgeApproxFx.simulateEmitterBurst(emitter: ParticleEmitter, count: number, opts: EmitOpts)
	local world = emitter:FindFirstAncestorOfClass("WorldModel")
	if not world then
		return
	end
	local originCf = emitterWorldCFrame(emitter)
	if not originCf then
		return
	end

	count = math.clamp(count, 1, 60)
	if _activeSprites + count > MAX_SPRITES then
		count = math.max(0, MAX_SPRITES - _activeSprites)
	end
	if count == 0 then
		return
	end

	local dirLocal = EMISSION_DIR[emitter.EmissionDirection] or Vector3.yAxis
	local spreadX = math.rad(math.abs(emitter.SpreadAngle.X))
	local spreadY = math.rad(math.abs(emitter.SpreadAngle.Y))
	local accel = emitter.Acceleration
	local colorSeq = emitter.Color
	local sizeSeq = emitter.Size
	local transparencySeq = emitter.Transparency
	local texture = emitter.Texture

	local sprites: { Sprite } = {}
	for _ = 1, count do
		local life = math.max(0.05, emitter.Lifetime.Min + math.random() * (emitter.Lifetime.Max - emitter.Lifetime.Min))
		local speed = emitter.Speed.Min + math.random() * (emitter.Speed.Max - emitter.Speed.Min)
		local spread = CFrame.fromOrientation(
			(math.random() * 2 - 1) * spreadX,
			(math.random() * 2 - 1) * spreadY,
			0
		)
		local dirWorld = (originCf * spread):VectorToWorldSpace(dirLocal)

		local part = Instance.new("Part")
		part.Name = "AnimaFxSprite"
		part.Archivable = false
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Material = Enum.Material.Neon
		part.Transparency = 1
		part.Size = Vector3.new(0.1, 0.1, 0.05)

		local decal: Decal? = nil
		if texture ~= "" then
			local d = Instance.new("Decal")
			d.Face = Enum.NormalId.Front
			d.Texture = texture
			d.Parent = part
			decal = d
		end

		part.Parent = world
		_activeSprites += 1
		table.insert(sprites, {
			part = part,
			decal = decal,
			pos = originCf.Position,
			vel = dirWorld * speed,
			life = life,
			age = 0,
		})
	end

	local conn: RBXScriptConnection? = nil
	local finished = false
	local function finish()
		if finished then
			return
		end
		finished = true
		if conn then
			conn:Disconnect()
			conn = nil
		end
		for _, s in sprites do
			_activeSprites -= 1
			s.part:Destroy()
		end
		table.clear(sprites)
	end
	opts.addCleanup(finish)

	conn = RunService.Heartbeat:Connect(function(dt: number)
		if finished then
			return
		end
		if not opts.isLive() or not world.Parent then
			finish()
			return
		end
		local cam = viewportCameraFor(world)
		local camPos = if cam then cam.CFrame.Position else nil
		local alive = 0
		for _, s in sprites do
			if s.age > s.life then
				if s.part.Parent then
					s.part.Transparency = 1
					if s.decal then
						s.decal.Transparency = 1
					end
				end
				continue
			end
			alive += 1
			s.age += dt
			s.vel += accel * dt
			s.pos += s.vel * dt
			local alpha = math.clamp(s.age / s.life, 0, 1)
			local size = math.max(0.05, evalNumberSequence(sizeSeq, alpha))
			local transparency = math.clamp(evalNumberSequence(transparencySeq, alpha), 0, 1)
			local color = evalColorSequence(colorSeq, alpha)
			s.part.Size = Vector3.new(size, size, 0.05)
			s.part.Color = color
			if s.decal then
				s.decal.Color3 = color
				s.decal.Transparency = transparency
				s.part.Transparency = 1
			else
				s.part.Transparency = transparency
			end
			if camPos then
				s.part.CFrame = CFrame.lookAt(s.pos, camPos)
			else
				s.part.CFrame = CFrame.new(s.pos)
			end
		end
		if alive == 0 then
			finish()
		end
	end)
end

-- 小窗 Beam 近似:Attachment0→1 之间拉一条贴图长条,持续 duration 后消失。
function ForgeApproxFx.simulateBeamFlash(beam: Beam, duration: number, opts: EmitOpts)
	local world = beam:FindFirstAncestorOfClass("WorldModel")
	local a0, a1 = beam.Attachment0, beam.Attachment1
	if not world or not a0 or not a1 then
		return
	end
	if _activeSprites >= MAX_SPRITES then
		return
	end

	local part = Instance.new("Part")
	part.Name = "AnimaFxBeamStrip"
	part.Archivable = false
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = evalColorSequence(beam.Color, 0.5)
	part.Transparency = 0.2
	part.Parent = world
	_activeSprites += 1

	local conn: RBXScriptConnection? = nil
	local finished = false
	local function finish()
		if finished then
			return
		end
		finished = true
		if conn then
			conn:Disconnect()
			conn = nil
		end
		_activeSprites -= 1
		part:Destroy()
	end
	opts.addCleanup(finish)

	local t0 = os.clock()
	local width = math.max(0.1, (beam.Width0 + beam.Width1) / 2)
	conn = RunService.Heartbeat:Connect(function()
		if finished then
			return
		end
		if not opts.isLive() or not a0.Parent or not a1.Parent or os.clock() - t0 >= duration then
			finish()
			return
		end
		local p0, p1 = a0.WorldPosition, a1.WorldPosition
		local len = (p1 - p0).Magnitude
		if len < 0.05 then
			part.Transparency = 1
			return
		end
		part.Size = Vector3.new(width, width * 0.25, len)
		part.CFrame = CFrame.lookAt((p0 + p1) / 2, p1)
	end)
end

return ForgeApproxFx
