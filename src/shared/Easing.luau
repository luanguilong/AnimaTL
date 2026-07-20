--!strict
-- Easing — 缓动函数。输入/输出均为 [0,1] 的归一化进度 alpha。
-- 名字与 CutsceneFormat.EasingName 对应。

local Easing = {}

export type EasingFn = (alpha: number) -> number

local function clamp01(a: number): number
	if a < 0 then
		return 0
	elseif a > 1 then
		return 1
	end
	return a
end

local fns: { [string]: EasingFn } = {
	linear = function(a)
		return a
	end,
	quadIn = function(a)
		return a * a
	end,
	quadOut = function(a)
		return 1 - (1 - a) * (1 - a)
	end,
	quadInOut = function(a)
		if a < 0.5 then
			return 2 * a * a
		end
		return 1 - (-2 * a + 2) ^ 2 / 2
	end,
	cubicInOut = function(a)
		if a < 0.5 then
			return 4 * a * a * a
		end
		return 1 - (-2 * a + 2) ^ 3 / 2
	end,
	sine = function(a)
		return -(math.cos(math.pi * a) - 1) / 2
	end,
}

-- 取缓动函数;未知名回退 linear。
function Easing.get(name: string?): EasingFn
	if name and fns[name] then
		return fns[name]
	end
	return fns.linear
end

-- 直接对 alpha 应用具名缓动。
function Easing.apply(name: string?, alpha: number): number
	return Easing.get(name)(clamp01(alpha))
end

return Easing
