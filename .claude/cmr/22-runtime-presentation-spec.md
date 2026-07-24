# 22 — 运行时演出语汇(T6)规格

**状态:🟡 M1–M5 已实现(2026-07-23 当天起草并落地,selene/双构建通过;待 Studio 实测)。**
实现:`CutsceneFormat`(ScreenCue/blendIn/skippable/formatVersion=3)、`shared/ScreenSampler`
(运行时与插件预览共用求值)、`runtime/ScreenOverlay + ScreenTrack + CutsceneNet`、
`CameraDirector` crossfade、`CutscenePlayer`(overlay 生命周期/skip/startAt seek)、
`Serializer`、`EditorState`(演出轨+cue CRUD+blendIn+skippable)、`App`(演出轨菜单/
cue 标记/段 crossfade 菜单/时长菜单跳过开关)、`plugin/ScreenFxPreview`(CoreGui 简化预览)。

## 目标 / 价值

把"在游戏里放戏"这层做厚,拉开与 Moon(纯创作工具)的差距。四件事:

1. **镜头 crossfade**:相机段切换从硬切升级为可配混合(位姿 + FOV 插值)。
2. **屏幕演出层(screen 轨)**:淡入淡出、黑边(letterbox)、受击红屏(tint)、
   **溅血贴图(splash)** 等叠在屏幕上的效果成为时间轴一等公民,不再靠事件轨手写 handler。
3. **跳过按钮**:`skippable` 过场内建"按住跳过"UI。
4. **服务器触发全员播放**:剧情节点一声令下,所有客户端同步看戏(含迟到补偿)。

## 非目标(本批不做)

- 不做画中画 / 多相机同屏;不做录屏回放。
- 不做相机抖动(shake)、vignette、径向模糊(V2 扩展位)。
- 不内置任何版权素材:splash 血渍图集 assetId 由项目自备、cue 里引用。
- 许可红线照旧:不加载/搬运 Forge、Moon 代码。

## 数据契约(CutsceneFormat,formatVersion=3)

### 1) 新轨 kind = "screen"(演出轨,整场至多一条)

`target` 固定 `"Screen"`,**不走 BindingResolver**(消费端自建屏幕层)。

```lua
{
  kind = "screen",
  target = "Screen",
  screenCues = {
    -- 通用字段:t(起点秒)、kind、duration(效果总时长,秒)
    { t = 0,   kind = "fade",      duration = 0.8, from = 1, to = 0, color = Color3.new(0,0,0) },
    { t = 0,   kind = "letterbox", duration = 0.5, to = 0.12 },      -- to = 单边黑边高占比;0 = 收起
    { t = 3.2, kind = "tint",      duration = 0.6, tintColor = Color3.fromRGB(255,60,60),
      saturation = -0.5, hold = 0.2 },                               -- 攻上去 hold 秒后按余下时长回落
    { t = 3.2, kind = "splash",    duration = 1.5, imageId = "rbxassetid://...",
      count = 3, holdRatio = 0.3 },                                  -- count 张血渍随机角落,淡入-停留-淡出
  },
}
```

- `fade`:全屏 Frame,`BackgroundTransparency` 从 `from`(缺省当前值)插值到 `to`。
- `letterbox`:上下两条黑 Frame,高度占比插值到 `to`。
- `tint`:专用 `ColorCorrectionEffect`(Lighting 下新建,不碰用户已有后期),
  `duration` 内攻至目标 → `hold` → 回落还原。
- `splash`:`count` 个 `ImageLabel` 随机分布屏幕边角(伪随机种子 = cue 下标,禁 `math.random` 裸用,
  保证重播一致),按 `duration` 与 `holdRatio` 做淡入-停留-淡出。
- 值全部可选 + 有缺省;插值复用 `Easing`(cue 可带 `easing` 字段,缺省 quadOut)。

### 2) 相机段新增 `blendIn: number?`(秒)

放在 camera 轨的段(segment)上:进入该段的前 `blendIn` 秒,与上一镜位姿/FOV 插值混合。
缺省 nil = 硬切,旧数据零迁移。

### 3) Cutscene 顶层

```lua
skippable = true,        -- 缺省 false
skipHoldSec = 0.8,       -- 按住时长;缺省 0(点按即跳)
```

- `formatVersion` 升 **3**;所有新字段可选,v1/v2 数据原样可播。
- Serializer / sliceForExport 照既有模式支持 screenCues(裁区间 + t 平移,参照 effectCues)。

## 运行时

- **`runtime/ScreenOverlay.luau`**:懒建 `ScreenGui`(PlayerGui 下,`IgnoreGuiInset`、
  `ResetOnSpawn=false`、`DisplayOrder` 可配缺省 999)+ 专用 ColorCorrection。
  `destroy()` 全部销毁还原。仅 `RunService:IsClient()` 时创建;server 播放时 warn 一次并跳过 screen 轨。
- **`runtime/ScreenTrack.luau`**:每帧对活跃 cue 求值写 Overlay;`stop()` 调 `overlay:destroy()`,
  挂进 `CutscenePlayer.stop()` 现有清理链(与 property/sound 轨并列)。
- **crossfade**:实现在 `CameraDirector` 层——`poseAt` 返回当前镜时,若当前段有 `blendIn`
  且 `t - 段起点 < blendIn`,对**上一镜位姿**(其段已结束则用段末冻结值)做
  `CFrame:Lerp` + FOV 数值插值。插件预览与运行时共用同一函数,所见即所得。
- **skip**:`skippable` 时 Overlay 附带右下角"跳过"按钮(按住 `skipHoldSec` 充能圈),
  触发 → `_step(duration)` → `stop()` → `onComplete(skipped=true)`(onComplete 增加可选参数,
  既有调用零改动)。

## 编辑器

- 「＋轨道」菜单加**「演出轨(屏幕)」**,单例(已存在则菜单置灰)。
- cue 菱形复用特效轨整套交互;右键按 `kind` 出对应 InputPrompt 字段;新建 cue 先选类型
  (淡入淡出 / 黑边 / 红屏 / 溅血)。
- **scrub 预览取舍(⚠️ 声明)**:插件无法往游戏 PlayerGui 画,V1 在**主视口上叠简化预览**
  (半透明 Frame 模拟 fade/黑边;tint 用主视口套色框近似;splash 显示占位图标不出真图),
  真实效果以 Play 模式为准。小窗(PreviewViewport)同步简化叠层。
- 相机段右键菜单加「混入时长(crossfade)…」。

## 网络设计(全员播放)——必读章节

- **模块**:`runtime/CutsceneNet.luau`。server 侧启动时在 `ReplicatedStorage.Anima.Remotes`
  下创建 `RemoteEvent "AnimaCutscene"`;client 侧 `CutsceneNet.listen(config)` 接线。
- **权威**:只有 server 广播 `play { name, startClock = workspace:GetServerTimeNow() }`。
  client 收到后按 `name` 在 `ReplicatedStorage.Anima.Cutscenes` **白名单树内** FindFirstChild
  (拒绝任意路径/Instance 引用,防注入),require 后播放。
- **同步起点**:client 本地 `t0 = GetServerTimeNow() - startClock`,从 `t0` seek 进场
  (EventTrack 已支持跳跃补发;动画 clip 起播判定 `t >= startAt` 天然兼容)。
- **迟到玩家**:server 记录 `activeCutscene { name, startClock, duration }`;
  PlayerAdded 时若仍在播 → 单发同一 remote,client 走同一条 seek 路径。
  可配 `lateJoinMode = "seek"(缺省) | "skip"(迟到不播)`。
- **skip 语义**:本地 skip 只结束本客户端演出,不上报 server、不影响他人;
  server 强制全员 stop 留 V2(remote 协议预留 `stop` 消息型)。
- **StreamingEnabled 降级**:client 播放前对全部轨 target 预解析;相机 follow / animation
  目标缺失 → `RequestStreamAroundAsync(首个 vcam 位置)` 限时 2s 重试一次;
  仍失败 → 该轨 warn 跳过不阻塞整场(沿用现有 warn-and-skip 惯例)。

## 边界 / 风险

- ColorCorrection 专用实例,stop 必销毁;绝不修改用户已有后期实例。
- crossfade 不动"整场单 CameraTrack"结构,混合只发生在 Director 求值层。
- 屏幕层与游戏 UI 的 DisplayOrder 冲突:暴露 config 覆盖;跳过按钮的手柄/触屏适配放 V2。
- splash 伪随机必须可重播一致(种子取 cue 下标),否则编辑预览与运行时对不上。
- `os.clock`/`GetServerTimeNow` 只用于对时,不进导出数据。

## V2 扩展位

- shake / vignette / 径向模糊 cue;服务器强制全员 stop、暂停/恢复。
- splash 素材包管理(项目级默认图集配置)。
- 跳过按钮样式外部皮肤化。

## 里程碑

- M1 契约(formatVersion=3)+ ScreenOverlay + ScreenTrack(四种 cue),命令行播放可见效果。
- M2 相机 crossfade(段 `blendIn` + Director 混合,插件预览同源)。
- M3 skip 按钮 + `skippable` 契约。
- M4 编辑器演出轨 UI + scrub 简化预览。
- M5 CutsceneNet:全员播放、迟到 seek、Streaming 降级(含白名单校验)。
