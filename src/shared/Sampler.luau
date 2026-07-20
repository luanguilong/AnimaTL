--!strict
-- Sampler — 在一串按 t 升序排列的 CFrame 关键帧上,按给定时间求值(插值)。
-- camera / transform 轨道共用。

local Easing = require(script.Parent.Easing)
local CutsceneFormat = require(script.Parent.CutsceneFormat)

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

-- 在 keyframes 上采样时间 t 处的 CFrame。
-- 规则:t 在首帧前 → 首帧值;末帧后 → 末帧值;之间 → 用后一帧的 easing 插值。
-- smooth=true 且 ≥3 帧时,位置走 Catmull-Rom 平滑曲线(旋转仍 slerp)。
-- keyframes 必须非空且已按 t 升序。
function Sampler.sampleCFrame(
	keyframes: { CutsceneFormat.Keyframe },
	t: number,
	smooth: boolean?
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
	-- 找到 t 落在的区间 [a, b]
	for i = 1, n - 1 do
		local a = keyframes[i]
		local b = keyframes[i + 1]
		if t >= a.t and t <= b.t then
			local av = a.value
			local bv = b.value
			if not av or not bv then
				return av or bv
			end
			local span = b.t - a.t
			local alpha = if span > 0 then (t - a.t) / span else 1
			local eased = Easing.apply(b.easing, alpha)
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
	end
	return last.value
end

return Sampler
