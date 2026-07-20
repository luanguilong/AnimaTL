--!strict
-- boss_intro — 手写的第一个过场(MVP 验证用)。
-- 时序:0s 人物开门动画 + 门转开 → 1~4s 镜头环绕人物 → 4~6s 拉远到 Boss 站位。
--
-- 说明:CFrame 数值是占位示例,真实数值应在 Studio 里用插件采集。
-- target 逻辑名:"Player"=本地真实 Character,"Door"/"Boss"=场景物体。

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CutsceneFormat = require(ReplicatedStorage.Anima.Shared.CutsceneFormat)

-- 环绕人物的镜头:绕原点一圈,盯着人物头部高度(y≈3)。
local function orbit(radius: number, angleDeg: number, height: number): CFrame
	local a = math.rad(angleDeg)
	local pos = Vector3.new(math.cos(a) * radius, height, math.sin(a) * radius)
	return CFrame.lookAt(pos, Vector3.new(0, 3, 0))
end

local cutscene: CutsceneFormat.Cutscene = {
	name = "boss_intro",
	duration = 6,
	takeCameraControl = true,
	tracks = {
		-- 人物开门手势
		{
			kind = "animation",
			target = "Player",
			name = "开门动作",
			clips = {
				{
					animationId = "rbxassetid://0", -- TODO: 换成真实开门动画 id
					startAt = 0,
					fadeTime = 0.1,
					speed = 1,
					looped = false,
				},
			},
		},

		-- 门:0~1s 绕铰链转开 90°
		{
			kind = "transform",
			target = "Door",
			name = "门转开",
			keyframes = {
				{ t = 0, value = CFrame.new(6, 3, 0) },
				{
					t = 1,
					value = CFrame.new(6, 3, 0) * CFrame.Angles(0, math.rad(-90), 0),
					easing = "cubicInOut",
				},
			},
		},

		-- Boss:4~6s 从远处站位出现(先在地下,推到地面)
		{
			kind = "transform",
			target = "Boss",
			name = "Boss 出现",
			keyframes = {
				{ t = 4, value = CFrame.new(0, -10, -40) },
				{ t = 6, value = CFrame.new(0, 0, -40), easing = "quadOut" },
			},
		},

		-- 镜头:0~1 拉近正面 → 1~4 环绕人物 → 4~6 拉远对准 Boss
		{
			kind = "camera",
			target = "Camera",
			name = "主镜头",
			keyframes = {
				{ t = 0, value = orbit(8, 0, 4) },
				{ t = 1, value = orbit(6, 0, 3), easing = "quadInOut" },
				{ t = 2, value = orbit(6, 120, 3), easing = "linear" },
				{ t = 3, value = orbit(6, 240, 3), easing = "linear" },
				{ t = 4, value = orbit(6, 360, 3), easing = "quadInOut" },
				-- 拉远,越过人物看向 -Z 的 Boss
				{
					t = 6,
					value = CFrame.lookAt(Vector3.new(0, 6, 20), Vector3.new(0, 1, -40)),
					easing = "cubicInOut",
				},
			},
		},

		-- 事件:切镜/音效点
		{
			kind = "event",
			target = "Boss",
			name = "事件",
			events = {
				{ t = 0, name = "cutscene_start" },
				{ t = 4, name = "boss_reveal", payload = { sound = "roar" } },
				{ t = 6, name = "cutscene_end" },
			},
		},
	},
}

return cutscene
