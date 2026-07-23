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
export type TrackKind =
	"animation"
	| "camera"
	| "transform"
	| "event"
	| "cameraMove"
	| "sound"
	| "effect"
	| "property"
	| "rigAnim"

-- 数据契约版本(17 spec):无 formatVersion 字段的旧数据视为 1;property 轨落地起为 2。
CutsceneFormat.FORMAT_VERSION = 2

-- 缓动名(见 Easing.luau)
export type EasingName = "linear" | "quadIn" | "quadOut" | "quadInOut" | "cubicInOut" | "sine"

-- 相机 / cameraMove 轨路径插值(07 spec);缺省 linear。legacy smooth 仍可用 Catmull-Rom。
export type PathMode = "linear" | "bezier"

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
	-- camera / cameraMove 贝塞尔(07):相对锚点位置的切线 offset;缺省 = 直线段
	outTangent: Vector3?,
	inTangent: Vector3?,
}

-- FOV 关键帧(camera 轨可选):到达 t 时视野角为 value,easing 同 CFrame 关键帧语义。
export type FovKeyframe = {
	t: number,
	value: number,
	easing: EasingName?,
}

-- 事件点:到达 t 时触发一个具名信号,payload 交给 EventTrack 的处理器。
export type CutsceneEvent = {
	t: number,
	name: string,
	payload: { [string]: any }?,
}

-- 音效 cue(09 spec):到 t 播 SoundId;target 决定 3D 挂点(或 Camera 绑定 2D)。
export type SoundCue = {
	t: number,
	soundId: string,
	volume: number?,
	playbackSpeed: number?,
	looped: boolean?,
	maxDistance: number?,
}

-- 特效 cue(09 + 16 spec):particle 或 Forge vfx.emit。
export type EffectEmitMode = "particle" | "forge"

export type EffectCue = {
	t: number,
	emitMode: EffectEmitMode?, -- 缺省 particle
	particleAssetId: string?,
	templateName: string?,
	emitCount: number?,
	duration: number?,
	forgeRoot: string?, -- forge: 绑定下子实例名;空 = 整绑定
	forgeScale: number?, -- forge: vfx.emit 缩放;缺省 1
}

function CutsceneFormat.effectEmitMode(cue: EffectCue): EffectEmitMode
	if cue.emitMode == "forge" then
		return "forge"
	end
	return "particle"
end

-- 属性轨(17 spec):K 任意 Instance 属性。V1 值类型:number/Vector3/Color3 插值,
-- boolean 阶梯(到 key 即切换)。EnumItem/Sequence 等留 V2(阶梯)。
export type PropValue = number | boolean | Vector3 | Color3

-- 预留:V2 支持 K Attribute;V1 恒 "property"。
export type PropertyKind = "property" | "attribute"

export type PropKeyframe = {
	t: number,
	value: PropValue,
	easing: EasingName?, -- 到达本帧的缓动;不可插值类型忽略
}

-- 值是否可插值(number/Vector3/Color3);false = 阶梯
function CutsceneFormat.propValueLerpable(v: any): boolean
	local tn = typeof(v)
	return tn == "number" or tn == "Vector3" or tn == "Color3"
end

-- 动画片段仅适用于该 Rig;nil = R6 与 R15 均匹配(兼容旧数据)。见 08 spec。
export type RigTypeName = "R6" | "R15"

-- 动画片段:在 target 角色上播一个 AnimationId。
export type AnimationClip = {
	animationId: string, -- "rbxassetid://..."
	startAt: number, -- 过场时间轴上的起播时刻(秒)
	endAt: number?, -- 时间轴上的结束时刻(秒);nil = 预览/运行时用源动画 Length÷speed 推断
	fadeTime: number?, -- 淡入时间;缺省 0.1
	speed: number?, -- 播放速度;缺省 1
	looped: boolean?, -- 是否循环;缺省 false
	rigType: RigTypeName?, -- 缺省 nil = 不限 Rig
}

-- 关节动画轨(20 spec):Moon 导入的逐关节 Motor6D.Transform 关键帧。
-- path = 关节路径(尾段 = Motor6D.Part1 名);value = Transform 偏移(相对静止位姿)。
export type JointTrack = {
	path: string,
	keyframes: { Keyframe },
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
	hidden: boolean?, -- true = 隐藏/静音:编辑预览与运行时播放都跳过本轨(数据仍保留)

	-- kind == "camera"(每相机独立轨模型):一个或多个生效区间段 + 可选运动关键帧。target = vcam 名。
	-- 求值时覆盖 t(落在任一段内)的相机轨中"时间轴最上层"那条上镜;有 keyframes 则驱动该相机运动,
	-- 无 keyframes 则回退该 vcam 的 cameraMove 运动轨 / 静态机位(见 VCamPose)。
	segments: { CameraSegment }?, -- 多段生效区间(新)。
	from: number?, -- 【遗留】单区间起;仅兼容旧数据,新数据用 segments。
	to: number?, -- 【遗留】单区间止。
	smooth: boolean?, -- true = 关键帧间平滑曲线(Catmull-Rom);缺省 false = 直线
	pathMode: PathMode?, -- bezier = 显式切线;缺省 linear(legacy smooth 仍生效)

	-- kind == "camera" 时可选:关键帧存相对锚点的 CFrame(见 FollowAnchor / 06 spec)
	followBinding: Binding?, -- 跟谁(如 "Player");空 = 世界空间 key
	followPart: string?, -- 锚点相对路径;缺省 HumanoidRootPart

	-- kind == "camera" | "transform" | "cameraMove" 时用:
	keyframes: { Keyframe }?,

	-- kind == "camera" 时可选:FOV 关键帧(上镜期间驱动 FieldOfView;无则用 vcam 的 FOV attribute)
	fovKeyframes: { FovKeyframe }?,

	-- kind == "animation" 时用:
	clips: { AnimationClip }?,

	-- kind == "event" 时用:
	events: { CutsceneEvent }?,

	-- kind == "sound" 时用:
	soundCues: { SoundCue }?,

	-- kind == "effect" 时用:
	effectCues: { EffectCue }?,

	-- kind == "property" 时用(17 spec):
	propertyName: string?, -- 目标实例上的属性名(一轨一属性)
	propertyKind: PropertyKind?, -- 缺省 "property"(V1 仅此)
	propKeyframes: { PropKeyframe }?,
	keepOnDone: boolean?, -- true = 播完保留终值;缺省 false = stop 时还原原值

	-- kind == "rigAnim" 时用(20 spec):target = 角色绑定。
	-- 注意:同一角色勿与 animation 轨同播(Animator 每帧也写 Transform,互踩)。
	jointTracks: { JointTrack }?,
}

-- 一个完整过场
export type Cutscene = {
	name: string,
	duration: number, -- 总时长(秒)
	tracks: { Track },

	-- 可选:数据契约版本;nil = 1(property 轨之前的旧数据)。见 FORMAT_VERSION。
	formatVersion: number?,

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

function CutsceneFormat.clipMatchesRig(clip: AnimationClip, rigType: Enum.HumanoidRigType): boolean
	if clip.rigType == nil then
		return true
	end
	if clip.rigType == "R6" then
		return rigType == Enum.HumanoidRigType.R6
	end
	if clip.rigType == "R15" then
		return rigType == Enum.HumanoidRigType.R15
	end
	return true
end

-- 按 Rig 过滤 clip;同 startAt 多条匹配时保留第一条并 warn(与 runtime 一致)。
function CutsceneFormat.clipsForRig(
	clips: { AnimationClip }?,
	rigType: Enum.HumanoidRigType
): { AnimationClip }
	if not clips then
		return {}
	end
	local out: { AnimationClip } = {}
	local seenStartAt: { [number]: boolean } = {}
	local warnedDup = false
	for _, clip in clips do
		if CutsceneFormat.clipMatchesRig(clip, rigType) then
			if seenStartAt[clip.startAt] then
				if not warnedDup then
					warnedDup = true
					warn(
						`[anima] 同 startAt 多条 clip 匹配 Rig {rigType.Name},仅使用第一条`
					)
				end
				continue
			end
			seenStartAt[clip.startAt] = true
			table.insert(out, clip)
		end
	end
	return out
end

local DEFAULT_CLIP_PLACEHOLDER_SEC = 1.5

-- 时间轴上 clip 右端(秒)。无 endAt 且无源时长时用 placeholder 或 fallbackEnd(如下一条 clip.startAt)。
function CutsceneFormat.clipTimelineEnd(
	clip: AnimationClip,
	fallbackEnd: number?,
	sourceAnimSec: number?
): number
	if clip.endAt then
		return clip.endAt
	end
	if sourceAnimSec and sourceAnimSec > 0 then
		return clip.startAt + sourceAnimSec / (clip.speed or 1)
	end
	if fallbackEnd and fallbackEnd > clip.startAt then
		return fallbackEnd
	end
	return clip.startAt + DEFAULT_CLIP_PLACEHOLDER_SEC
end

-- 窗口内相对源动画的 TimePosition(秒),供预览定帧。
function CutsceneFormat.clipTimePositionAt(
	clip: AnimationClip,
	t: number,
	sourceAnimSec: number
): number
	if t < clip.startAt then
		return 0
	end
	local speed = clip.speed or 1
	local endT = CutsceneFormat.clipTimelineEnd(clip, nil, sourceAnimSec)
	if clip.endAt and t > endT then
		t = endT
	end
	local pos = (t - clip.startAt) * speed
	if sourceAnimSec > 0 then
		if clip.looped then
			pos %= sourceAnimSec
		else
			pos = math.clamp(pos, 0, sourceAnimSec)
		end
	end
	return pos
end

return CutsceneFormat
