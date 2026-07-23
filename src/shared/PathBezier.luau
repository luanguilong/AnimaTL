--!strict
-- PathBezier — 相机路径三次贝塞尔(位置);旋转在 Sampler 层与锚点 slerp。

local PathBezier = {}

local function cubicBezier(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, u: number): Vector3
	local om = 1 - u
	local om2 = om * om
	local u2 = u * u
	return om2 * om * p0 + 3 * om2 * u * p1 + 3 * om * u2 * p2 + u2 * u * p3
end

-- anchor0/1 为存储空间 CFrame;切线 offset 相对锚点位置(与 06 / 07 spec 同空间)。
function PathBezier.sampleSegment(
	anchor0: CFrame,
	anchor1: CFrame,
	outTan: Vector3?,
	inTan: Vector3?,
	u: number
): CFrame
	local p0 = anchor0.Position
	local p3 = anchor1.Position
	local out = outTan or Vector3.zero
	local inn = inTan or Vector3.zero
	local p1 = p0 + out
	local p2 = p3 + inn
	local pos = cubicBezier(p0, p1, p2, p3, u)
	return CFrame.new(pos) * anchor0:Lerp(anchor1, u).Rotation
end

return PathBezier
