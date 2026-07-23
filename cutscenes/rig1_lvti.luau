--!strict
-- rig1_lvti — Player + 驴踢 Forge 演示过场。
-- 建议在 Anima Timeline 调好后 💾 导出模块名 rig1_lvti 覆盖本文件(保留 Player / 驴踢 / forge 绑定)。
-- 当前为可 Play 的兜底数据(动画轨已绑 Player,特效 @1.33s)。

local cutscene = {
	name = "rig1_lvti",
	duration = 3.5,
	fps = 30,
	takeCameraControl = true,
	tracks = {
		{
			kind = "animation",
			target = "Player",
			name = "开门动作",
			clips = {
				{
					animationId = "rbxassetid://118973047515809",
					startAt = 0,
					endAt = 2.5,
					fadeTime = 0.1,
					speed = 1,
					looped = false,
				},
			},
		},
		{
			kind = "effect",
			target = "驴踢",
			name = "驴踢 Forge",
			effectCues = {
				{ t = 1.33, emitMode = "forge", forgeScale = 1 },
			},
		},
		{
			kind = "camera",
			target = "VCam16",
			name = "相机轨道",
			segments = {
				{ from = 0, to = 3.5 },
			},
		},
	},
}

return cutscene
