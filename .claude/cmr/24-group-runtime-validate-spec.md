# 24 — 运行时尊重分组 + 导出校验(T8)规格

**状态:V1 实现中(2026-07-24 起草即动工)。**

## 目标 / 价值

1. **整组静音/隐藏**:分组(group)目前纯组织用;要能一键把整组轨道从预览/播放里拿掉
   (排查"哪组在捣乱"、临时关掉一条支线演出)。
2. **导出校验**:导出前把悬空 vcam、空轨、越界 key、占位 id 这类"到运行时才炸"的数据
   问题提前报出来。

## 设计决策:整组隐藏不加契约

原 roadmap 设想"group 进运行时语义"。实际更优解:**编辑器批量翻子轨的 `track.hidden`**,
一步撤销。运行时/预览/导出本来就尊重 `hidden`,于是"运行时尊重分组"零契约、零运行时
改动地成立。不引入组级第二真相(避免 hidden 与 groupHidden 两处状态合成)。

- `EditorState.setGroupHidden(group, hidden)`:批量设该组全部轨道 hidden,pushUndo 一次。
- 分组表头右键菜单加「🙈 隐藏整组 / 👁 显示整组」(组内全 hidden 时显示后者);
  表头标题在整组隐藏时追加"(已隐藏)"。

## 导出校验(plugin/CutsceneValidate.luau)

`CutsceneValidate.run(cutscene) -> { string }`(提醒列表,空 = 干净)。V1 全部 **warn 不阻断**
(编辑器数据经常故意半成品,阻断反而烦);逐条打 Output,导出成功日志带提醒计数。

检查项(V1):
- **悬空 vcam**:camera/cameraMove 轨 target 在场景找不到 vcam(VCam.find nil)。
- **悬空绑定**:animation/transform/property/rigAnim/sound/effect 轨 target 与相机
  followBinding 用 SceneResolver 解析失败(编辑期场景为准;运行时另有 resolver,提示级)。
- **空轨**:轨道无任何内容(keyframes/clips/events/cues/segments 全空)。
- **永不上镜**:camera 轨有 keyframes 但生效段为空(segments 空且无 legacy from/to)。
- **越界 key**:任何 t / clip.endAt / segment.to 超出 [0, duration]。
- **占位动画 id**:clip.animationId 为空或 `rbxassetid://0`。
- **splash 缺贴图**:screen splash cue 无 imageId(运行时会静默不渲染)。
- **隐藏计数**:hidden 轨道数量(提醒"导出后运行时会跳过 N 条")。

接线:init.server 导出 onSubmit 里、slice 之后 writeModule 之前跑一次,
`warn("[anima] 导出校验:...")` 逐条输出。

## 非目标

- 不做阻断式校验 / 校验结果 UI 面板(V2 看需求)。
- 不做组级运行时语义字段(见上,刻意不加)。
- 不校验运行时 resolver 能否解析(客户端绑定与编辑期场景不同,只按编辑期提示)。

## 里程碑

- M1 setGroupHidden + 分组菜单项 + 表头(已隐藏)标记。
- M2 CutsceneValidate + 导出接线。
