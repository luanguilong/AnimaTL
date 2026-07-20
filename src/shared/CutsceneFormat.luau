--!strict
-- CutsceneFormat — anima 过场数据契约(唯一真相)。
--
-- 插件"生产"这些数据(写成 cutscenes/*.luau),运行时"消费"它。
-- 两边都只依赖本文件的类型,不互相依赖。
--
-- 概念模型借鉴 UE Sequencer / Unity Timeline:
--   Cutscene ── tracks[] ── keyframes[]
--   每条 track 有一个 target(Binding:逻辑名),运行时映射到真实实例。
--
-- 坐标/朝向统一用 CFrame。时间单位:秒。

local CutsceneFormat = {}

-- 轨道类型
--   cameraMove: 用 keyframes(CFrame) 驱动某台 vcam(target=vcam 名)自己的运动。
--   相机求值时若某 vcam 有 cameraMove 轨则采样它、否则用静态机位。
export type TrackKind = "animation" | "camera" | "transform" | "event" | "cameraMove"

-- 缓动名(见 Easing.luau)
export type EasingName = "linear" | "quadIn" | "quadOut" | "quadInOut" | "cubicInOut" | "sine"

-- Binding:逻辑目标名。运行时由 CharacterBinder / 场景查找映射到真实实例。
-- 约定的角色槽位名:"Player"(本地玩家真实 Character);其余为场景物体名。
export type Binding = string

-- 单个关键帧。value 的具体类型取决于所在 track 的 kind:
--   camera / transform → CFrame
--   animation → 不用 keyframes(见 AnimationTrack)
--   event → 不用 value(靠 events[])
export type Keyframe = {
	t: number, -- 相对过场起点的时间(秒)
	value: CFrame?, -- camera / transform 用
	easing: EasingName?, -- 到达本帧使用的缓动;缺省 linear
}

-- 事件点:到达 t 时触发一个具名信号,payload 交给 EventTrack 的处理器。
export type CutsceneEvent = {
	t: number,
	name: string,
	payload: { [string]: any }?,
}

-- 动画片段:在 target 角色上播一个 AnimationId。
export type AnimationClip = {
	animationId: string, -- "rbxassetid://..."
	startAt: number, -- 过场时间轴上的起播时刻(秒)
	fadeTime: number?, -- 淡入时间;缺省 0.1
	speed: number?, -- 播放速度;缺省 1
	looped: boolean?, -- 是否循环;缺省 false
}

-- 相机轨的一个生效区间段(同一台相机可在一条轨上有多个不连续的段)。
export type CameraSegment = {
	from: number, -- 段起(秒)
	to: number, -- 段止(秒)
}

-- 一条轨道
export type Track = {
	kind: TrackKind,
	target: Binding, -- 作用目标的逻辑名
	name: string?, -- 便于阅读/UI 显示
	group: string?, -- 所属对象分组名(UE Sequencer 式;纯组织用,运行时忽略)

	-- kind == "camera"(每相机独立轨模型):一个或多个生效区间段 + 可选运动关键帧。target = vcam 名。
	-- 求值时覆盖 t(落在任一段内)的相机轨中"时间轴最上层"那条上镜;有 keyframes 则驱动该相机运动,
	-- 无 keyframes 则回退该 vcam 的 cameraMove 运动轨 / 静态机位(见 VCamPose)。
	segments: { CameraSegment }?, -- 多段生效区间(新)。
	from: number?, -- 【遗留】单区间起;仅兼容旧数据,新数据用 segments。
	to: number?, -- 【遗留】单区间止。
	smooth: boolean?, -- true = 关键帧间平滑曲线(Catmull-Rom);缺省 false = 直线

	-- kind == "camera" | "transform" | "cameraMove" 时用:
	keyframes: { Keyframe }?,

	-- kind == "animation" 时用:
	clips: { AnimationClip }?,

	-- kind == "event" 时用:
	events: { CutsceneEvent }?,
}

-- 一个完整过场
export type Cutscene = {
	name: string,
	duration: number, -- 总时长(秒)
	tracks: { Track },

	-- 可选:编辑时的帧率(时间轴显示/吸附用;运行时按秒播,与此无关)。缺省 30。
	fps: number?,

	-- 可选:过场开始时是否接管本地 Camera(默认 true)。
	takeCameraControl: boolean?,
}

-- 运行时提供的绑定解析器:把逻辑名解析成真实实例。
-- 由调用方(client 启动脚本)构造,注入 CutscenePlayer。
export type BindingResolver = (name: Binding) -> Instance?

-- 取相机轨的生效区间段列表:新 segments 优先;兼容旧单 from/to;都无则空。
function CutsceneFormat.segmentsOf(tr: Track): { CameraSegment }
	if tr.segments and #tr.segments > 0 then
		return tr.segments
	end
	if tr.from and tr.to then
		return { { from = tr.from, to = tr.to } }
	end
	return {}
end

-- 相机轨在时刻 t 是否生效(落在任一段内)。
function CutsceneFormat.coversAt(tr: Track, t: number): boolean
	for _, s in CutsceneFormat.segmentsOf(tr) do
		if s.from <= t and t <= s.to then
			return true
		end
	end
	return false
end

return CutsceneFormat
