--!strict
-- Sampler — 在一串按 t 升序排列的 CFrame 关键帧上,按给定时间求值(插值)。
-- camera / transform 轨道共用;camera / cameraMove 路径模式见 sampleTrackCFrame。

local Easing = require(script.Parent.Easing)
local CutsceneFormat = require(script.Parent.CutsceneFormat)
local PathBezier = require(script.Parent.PathBezier)

local Sampler = {}

-- Catmull-Rom 位置插值(平滑穿过各点)。p0/p3 为相邻控制点(边界用端点复制)。
local function catmullRom(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, u: number): Vector3
	local u2 = u * u
	local u3 = u2 * u
	return 0.5
		* (
			(2 * p1)
			+ (-p0 + p2) * u
			+ (2 * p0 - 5 * p1 + 4 * p2 - p3) * u2
			+ (-p0 + 3 * p1 - 3 * p2 + p3) * u3
		)
end

local function sampleInterval(
	keyframes: { CutsceneFormat.Keyframe },
	i: number,
	t: number,
	track: CutsceneFormat.Track?
): CFrame?
	local a = keyframes[i]
	local b = keyframes[i + 1]
	local av = a.value
	local bv = b.value
	if not av or not bv then
		return av or bv
	end
	local span = b.t - a.t
	local alpha = if span > 0 then (t - a.t) / span else 1
	local eased = Easing.apply(b.easing, alpha)
	local n = #keyframes
	local pathMode = if track then track.pathMode else nil
	if pathMode == "bezier" then
		return PathBezier.sampleSegment(av, bv, a.outTangent, b.inTangent, eased)
	end
	local smooth = if track then track.smooth else false
	if smooth and n >= 3 then
		local p0 = if keyframes[i - 1] and keyframes[i - 1].value
			then keyframes[i - 1].value :: CFrame
			else av
		local p3 = if keyframes[i + 2] and keyframes[i + 2].value
			then keyframes[i + 2].value :: CFrame
			else bv
		local pos = catmullRom(p0.Position, av.Position, bv.Position, p3.Position, eased)
		return CFrame.new(pos) * av:Lerp(bv, eased).Rotation
	end
	return av:Lerp(bv, eased)
end

local function sampleAtTime(
	keyframes: { CutsceneFormat.Keyframe },
	t: number,
	track: CutsceneFormat.Track?
): CFrame?
	local n = #keyframes
	if n == 0 then
		return nil
	end
	local first = keyframes[1]
	if t <= first.t then
		return first.value
	end
	local last = keyframes[n]
	if t >= last.t then
		return last.value
	end
	for i = 1, n - 1 do
		local a = keyframes[i]
		local b = keyframes[i + 1]
		if t >= a.t and t <= b.t then
			return sampleInterval(keyframes, i, t, track)
		end
	end
	return last.value
end

-- 在 keyframes 上采样时间 t 处的 CFrame(兼容 transform 等:smooth 第三参)。
function Sampler.sampleCFrame(
	keyframes: { CutsceneFormat.Keyframe },
	t: number,
	smooth: boolean?
): CFrame?
	local tr: CutsceneFormat.Track? = nil
	if smooth ~= nil then
		tr = { kind = "transform", target = "", smooth = smooth }
	end
	return sampleAtTime(keyframes, t, tr)
end

-- 在数值关键帧(如 FOV)上采样:端点 clamp,段内 lerp + 目标帧 easing。
function Sampler.sampleNumber(keyframes: { CutsceneFormat.FovKeyframe }, t: number): number?
	local n = #keyframes
	if n == 0 then
		return nil
	end
	if t <= keyframes[1].t then
		return keyframes[1].value
	end
	if t >= keyframes[n].t then
		return keyframes[n].value
	end
	for i = 1, n - 1 do
		local a = keyframes[i]
		local b = keyframes[i + 1]
		if t >= a.t and t <= b.t then
			local span = b.t - a.t
			local alpha = if span > 0 then (t - a.t) / span else 1
			local eased = Easing.apply(b.easing, alpha)
			return a.value + (b.value - a.value) * eased
		end
	end
	return keyframes[n].value
end

local function lerpPropValue(
	a: CutsceneFormat.PropValue,
	b: CutsceneFormat.PropValue,
	alpha: number
): CutsceneFormat.PropValue
	if typeof(a) ~= typeof(b) then
		return a
	end
	if typeof(a) == "number" then
		return (a :: number) + ((b :: number) - (a :: number)) * alpha
	end
	if typeof(a) == "Vector3" then
		return (a :: Vector3):Lerp(b :: Vector3, alpha)
	end
	if typeof(a) == "Color3" then
		return (a :: Color3):Lerp(b :: Color3, alpha)
	end
	-- 阶梯(boolean 等):段内取左值,到达右 key 由端点分支返回右值
	return a
end

-- 属性关键帧采样(17 spec):端点 clamp;段内按右 key easing 插值;
-- 不可插值类型阶梯(到 key 才切换)。
function Sampler.sampleValue(
	keyframes: { CutsceneFormat.PropKeyframe },
	t: number
): CutsceneFormat.PropValue?
	local n = #keyframes
	if n == 0 then
		return nil
	end
	if t <= keyframes[1].t then
		return keyframes[1].value
	end
	if t >= keyframes[n].t then
		return keyframes[n].value
	end
	for i = 1, n - 1 do
		local a = keyframes[i]
		local b = keyframes[i + 1]
		if t >= a.t and t <= b.t then
			local span = b.t - a.t
			local alpha = if span > 0 then (t - a.t) / span else 1
			return lerpPropValue(a.value, b.value, Easing.apply(b.easing, alpha))
		end
	end
	return keyframes[n].value
end

-- 带轨级 pathMode / smooth 的采样(camera / cameraMove)。
function Sampler.sampleTrackCFrame(track: CutsceneFormat.Track, t: number): CFrame?
	local kfs = track.keyframes
	if not kfs or #kfs == 0 then
		return nil
	end
	return sampleAtTime(kfs, t, track)
end

return Sampler
