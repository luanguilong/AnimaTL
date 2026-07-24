--!strict
-- test_showcase — 全功能演示过场(2026-07-24,覆盖 formatVersion=3 全部新能力)。
-- 设计为**零场景依赖**:相机全用手写 CFrame 关键帧(不需要 vcam 实体),
-- 唯一的软依赖是 Baseplate(属性轨闪烁演示;没有就 warn-and-skip,顺便验证降级路径)。
--
-- 跑法:
--   编辑器:📂 过场浏览器 → test_showcase → 空格播放(验证 scrub/简化屏幕预览)。
--   Play 模式:进游戏按 1(AnimaPlayKey 见 test_showcase.meta.json)。
--
-- 验收清单(按时间):
--   0.0s  从黑淡入(screen fade) + 黑边压入(letterbox)
--   0–8s  镜头 A 环绕推进,FOV 70→40 变焦(fovKeyframes 插值)
--   1.0s  事件 cutscene_start(Output 打印)
--   8.0s  受击:红屏 tint + 溅血 splash(4 张,占位烟雾贴图)+ 音效 + 事件 hit
--         (payload damage=25)+ Baseplate 透明度闪烁(属性轨)
--   8–9.5s 镜头 A→B **crossfade 1.5s**(平滑混合,对比后面的硬切)
--   14.0s 镜头 B→C **硬切**(blendIn 未设,对比 crossfade)
--   14–20s 镜头 C 拉远,FOV 45→80(拉远变广角)
--   16.0s 黑边收起
--   18.5s 淡出到黑;19.5s 事件 cutscene_end
--   全程:右下角「按住跳过」按钮(0.8s 充能)——中途跳过应:无音效炸响、
--         Baseplate 透明度复原、cutscene_end 等事件照发、onComplete(skipped=true)

local LOOK_AT = Vector3.new(0, 4, 0)

local cutscene = {
	name = "test_showcase",
	formatVersion = 3,
	duration = 20,
	fps = 30,
	takeCameraControl = true,
	skippable = true,
	skipHoldSec = 0.8,
	tracks = {
		-- 镜头 A(0–8s):环绕推进 + 变焦
		{
			kind = "camera",
			target = "TestShotA",
			name = "镜头A·环绕推焦",
			segments = { { from = 0, to = 8 } },
			keyframes = {
				{ t = 0, value = CFrame.lookAt(Vector3.new(16, 7, 0), LOOK_AT) },
				{
					t = 4,
					value = CFrame.lookAt(Vector3.new(11, 6, 11), LOOK_AT),
					easing = "quadInOut",
				},
				{
					t = 8,
					value = CFrame.lookAt(Vector3.new(0, 5, 14), LOOK_AT),
					easing = "quadInOut",
				},
			},
			fovKeyframes = {
				{ t = 0, value = 70 },
				{ t = 7.5, value = 40, easing = "quadInOut" },
			},
		},
		-- 镜头 B(8–14s):低角度侧移;进段 crossfade 1.5s
		{
			kind = "camera",
			target = "TestShotB",
			name = "镜头B·crossfade进",
			segments = { { from = 8, to = 14, blendIn = 1.5 } },
			keyframes = {
				{ t = 8, value = CFrame.lookAt(Vector3.new(-11, 2.5, 7), LOOK_AT) },
				{
					t = 14,
					value = CFrame.lookAt(Vector3.new(-8, 3.5, -9), LOOK_AT),
					easing = "sine",
				},
			},
			fovKeyframes = {
				{ t = 8, value = 55 },
			},
		},
		-- 镜头 C(14–20s):高机位拉远 + 广角;硬切进(与 B 的 crossfade 对比)
		{
			kind = "camera",
			target = "TestShotC",
			name = "镜头C·硬切拉远",
			segments = { { from = 14, to = 20 } },
			keyframes = {
				{ t = 14, value = CFrame.lookAt(Vector3.new(0, 22, -26), LOOK_AT) },
				{
					t = 20,
					value = CFrame.lookAt(Vector3.new(0, 34, -42), LOOK_AT),
					easing = "quadOut",
				},
			},
			fovKeyframes = {
				{ t = 14, value = 45 },
				{ t = 20, value = 80, easing = "quadInOut" },
			},
		},
		-- 演出轨:淡入淡出/黑边/受击红屏/溅血
		{
			kind = "screen",
			target = "Screen",
			name = "演出轨",
			screenCues = {
				{ t = 0, kind = "fade", duration = 1.2, from = 1, to = 0 },
				{ t = 0.5, kind = "letterbox", duration = 0.8, to = 0.12 },
				{
					t = 8,
					kind = "tint",
					duration = 1.2,
					hold = 0.3,
					tintColor = Color3.fromRGB(255, 60, 60),
					saturation = -0.6,
				},
				{
					t = 8,
					kind = "splash",
					duration = 2,
					count = 4,
					holdRatio = 0.35,
					-- 占位:引擎自带烟雾贴图;项目素材就位后换 rbxassetid
					imageId = "rbxasset://textures/particles/smoke_main.dds",
				},
				{ t = 16, kind = "letterbox", duration = 0.8, to = 0 },
				{ t = 18.5, kind = "fade", duration = 1.5, to = 1 },
			},
		},
		-- 事件轨:含 payload(19 spec)
		{
			kind = "event",
			target = "Player",
			name = "标记轨",
			events = {
				{ t = 1, name = "cutscene_start" },
				{ t = 8, name = "hit", payload = { damage = 25, source = "test_showcase" } },
				{ t = 19.5, name = "cutscene_end" },
			},
		},
		-- 音效轨:受击瞬间(挂 Camera = 2D 播放;引擎自带音效免外部资源)
		{
			kind = "sound",
			target = "Camera",
			name = "音效轨",
			soundCues = {
				{ t = 8, soundId = "rbxasset://sounds/electronicpingshort.wav", volume = 0.8 },
			},
		},
		-- 属性轨(17 spec):受击瞬间 Baseplate 透明度闪一下,播完还原(keepOnDone 缺省 false)。
		-- 场景没有 Baseplate 时应看到 warn 并整轨跳过(顺便验证降级路径)。
		{
			kind = "property",
			target = "Baseplate",
			name = "地面闪烁",
			propertyName = "Transparency",
			propKeyframes = {
				{ t = 7.9, value = 0 },
				{ t = 8.3, value = 0.6, easing = "quadOut" },
				{ t = 9.2, value = 0, easing = "quadIn" },
			},
		},
	},
}

return cutscene
