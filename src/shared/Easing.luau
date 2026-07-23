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
	-- T5 扩展档(21 spec):Expo / Back / Elastic / Bounce
	expoIn = function(a)
		return if a == 0 then 0 else 2 ^ (10 * a - 10)
	end,
	expoOut = function(a)
		return if a == 1 then 1 else 1 - 2 ^ (-10 * a)
	end,
	expoInOut = function(a)
		if a == 0 or a == 1 then
			return a
		end
		if a < 0.5 then
			return 2 ^ (20 * a - 10) / 2
		end
		return (2 - 2 ^ (-20 * a + 10)) / 2
	end,
	backIn = function(a)
		local c = 1.70158
		return (c + 1) * a * a * a - c * a * a
	end,
	backOut = function(a)
		local c = 1.70158
		local b = a - 1
		return 1 + (c + 1) * b * b * b + c * b * b
	end,
	backInOut = function(a)
		local c = 1.70158 * 1.525
		if a < 0.5 then
			return ((2 * a) ^ 2 * ((c + 1) * 2 * a - c)) / 2
		end
		return ((2 * a - 2) ^ 2 * ((c + 1) * (2 * a - 2) + c) + 2) / 2
	end,
	elasticOut = function(a)
		if a == 0 or a == 1 then
			return a
		end
		return 2 ^ (-10 * a) * math.sin((a * 10 - 0.75) * (2 * math.pi / 3)) + 1
	end,
	bounceOut = function(a)
		local n, d = 7.5625, 2.75
		if a < 1 / d then
			return n * a * a
		elseif a < 2 / d then
			a -= 1.5 / d
			return n * a * a + 0.75
		elseif a < 2.5 / d then
			a -= 2.25 / d
			return n * a * a + 0.9375
		end
		a -= 2.625 / d
		return n * a * a + 0.984375
	end,
}

-- 菜单/映射共用的全量名单(顺序即 UI 展示顺序)。
Easing.names = {
	"linear",
	"quadIn",
	"quadOut",
	"quadInOut",
	"cubicInOut",
	"sine",
	"expoIn",
	"expoOut",
	"expoInOut",
	"backIn",
	"backOut",
	"backInOut",
	"elasticOut",
	"bounceOut",
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
