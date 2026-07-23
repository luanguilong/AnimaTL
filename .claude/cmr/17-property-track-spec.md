# 17 — 属性轨(kind=property)规格

**状态:V1 已实现(2026-07-23,M1–M4 全部落地,selene/双构建通过;待 Studio 实测→V2 批)。**
实现:`CutsceneFormat`(PropValue/PropKeyframe/formatVersion=2)、`Sampler.sampleValue`、
`Serializer`、`runtime/PropertyTrack.luau`、`CutscenePlayer` 接线、`EditorState`(addPropertyTrack/
capturePropFrame/prop 关键帧全套 + 时长收敛/内容端点)、`App`(propDiamond/建轨菜单/轨道菜单含
keepOnDone 开关)、`plugin/PropertyPreview.luau`(workspace+viewport 双 context 还原)、导出 slice。

## 目标 / 价值

K 任意 Instance 的属性随时间变化(透明度、颜色、光照亮度、粒子参数、FOV 之外的数值),
补齐对 Moon Animator 最大的功能缺口(Moon 可 K 任意属性,anima 目前只有 CFrame)。
运行时与编辑器共用同一套求值(所见即所得),并与 Forge tweener 近似预览共享插值代码。

## 非目标(本批不做)

- 不做 graph editor / 逐 key 贝塞尔(T5)。
- 不做属性自动发现 UI(下拉列出实例全部属性);V1 手输属性名。
- 不做多属性一轨(一条轨 = 一个目标实例的一个属性)。
- 不做 Attribute 支持(V1 只 K 真属性;Attribute 留 V2,契约预留字段)。

## 数据契约(CutsceneFormat)

```lua
-- Track 新 kind = "property"
{
  kind = "property",
  target = "Door/Glow",         -- 绑定路径,复用现有 Binding 语义
  propertyName = "Transparency", -- 属性名
  propertyKind = "property",     -- 预留:"property" | "attribute"(V1 恒 property)
  propKeyframes = {              -- 与 Keyframe 区分,值是 any
    { t = 0,   value = 1,   easing = "quadOut" },
    { t = 0.5, value = 0.2 },
  },
}
```

- 支持值类型 V1:**number / Color3 / Vector3 / boolean**。
  - number/Vector3/Color3:插值(复用 Easing;Color3 用 :Lerp)。
  - boolean(及未来其它不可插值类型):阶梯——到达 key 即切换,无插值。
- 序列化:Serializer 按 typeof 分派输出构造表达式(Color3.fromRGB / Vector3.new / true/false / 数字)。
- `sliceForExport` 同其它轨:裁区间、t 平移(参考 14 号规格 effectCues 处理)。

## 求值(shared/PropSampler 或并入 Sampler)

```lua
Sampler.sampleValue(propKeyframes, t) -> any?
```

- t 在首 key 前 → 首 key 值;末 key 后 → 末 key 值(clamp,与 CFrame 轨一致)。
- 区间内:按右 key 的 easing 求 alpha 后插值;不可插值类型取左 key 值(阶梯)。
- **不做** Catmull-Rom(数值属性无"平滑路径"需求)。

## 运行时(runtime/PropertyTrack.luau)

- `new(track, target)`:解析绑定,记录**播放前原值**。
- `update(t)`:sampleValue → 直接赋值(pcall,属性不存在时 warn 一次即静默)。
- `stop()`:**还原原值**(编辑 scrub 与正式播放同规则;正式播放可通过
  `track.keepOnDone = true` 保留终值——V1 契约里放这个布尔,默认 false 还原)。
- CutscenePlayer 接线:与 TransformTrack 并列,每帧 update。

## 编辑器

- **建轨**:「＋轨道」菜单加"属性轨→选目标→输属性名"(InputPrompt 两步;从选中实例
  预填目标)。轨道行显示 `名 · 属性名` 芯片。
- **打帧**:复用关键帧菱形整套交互(长按拖 t / 右键 定位/改值/缓动/删除)。
  "改值"用 InputPrompt 按类型解析(数字 / `r,g,b` / `x,y,z` / true/false)。
- **取值打帧**(核心手感):右键菜单/快捷入口"**以当前值打帧**"——读目标实例此刻的
  属性值直接落 key(改场景→打帧→改场景→打帧的 Record 式流程)。
- **scrub 预览**:Preview.applyAt 对 property 轨逐帧求值应用到场景实例;
  离开预览/停止时还原原值(复用 MediaPreview 的 reset 时机;还原表按 track 记录)。
- 小窗预览:PreviewViewport 克隆体上同步应用(克隆解析失败静默)。

## 与现有系统的边界声明

- **vcam FOV 不走属性轨**:相机 FOV 已有专用 `fovKeyframes`(Moon 导入在用),property 轨
  不用于 Camera/vcam 的 FOV,避免同一语义两套数据。文档与建轨入口都要挡(target 解析出
  vcam/Camera 且属性名 FieldOfView 时提示改用相机轨)。
- **契约版本号**:本批给 Cutscene 加 `formatVersion = 2`(无字段视为 1)。EditorState
  载入时按 cloneTrack 迁移模式兜底;Serializer 恒输出当前版本。
- **建轨即校验**:输完属性名立即在目标实例上试读一次(pcall),读不到就地报错并拒绝建轨
  ——把"属性名拼错"挡在数据进契约之前;"以当前值打帧"入口天然免此问题。
- **还原表按 context 隔离**:workspace scrub 与小窗克隆是两个还原上下文(参考
  MediaPreview `_contexts` 模式),各自记录原值、各自还原;换 cutscene/revision 变更时
  两边都必须清。

## V2 扩展位(本批只留接口,不实现)

- `propertyKind = "attribute"`:K Attribute(Forge 特效调参会用到)。
- 阶梯型支持 EnumItem(Material 等)与 NumberSequence/ColorSequence(粒子曲线):
  不插值、到 key 即赋值;Serializer 需对应构造式输出。

## 边界 / 风险

- 属性写失败(只读/类型不符):pcall + 每轨 warn 一次,不刷屏。
- 还原责任:scrub 中途换 cutscene / 关面板必须还原——挂进现有 revision reset 链。
- 与 transform 轨同目标同帧冲突:不做仲裁,后 update 的轨生效(文档声明即可)。
- 撤销:数据操作走现有快照栈;场景属性改动不进撤销(与 vcam gizmo 同取舍)。

## 里程碑

- M1 契约 + Sampler.sampleValue + Serializer(纯数据,selene/构建过)。
- M2 runtime PropertyTrack + CutscenePlayer 接线(命令栏可播)。
- M3 编辑器建轨/打帧/改值 UI + scrub 预览还原。
- M4 "以当前值打帧" + 导出 slice + 小窗同步,MCP 实测一条透明度轨全链路。
