# 06 — 相机轨跟随绑定（Follow Binding）

> Milestone M0 约定。M1+ 实现以本文为准；变更需团队对表后再改代码。  
> 与 [05 — 视口 A 透视编辑](05-camera-authoring-spec.md) 分工：A 仍只负责采视口世界构图；写入前 `ToObjectSpace(anchor)`，进入 authoring / 双击 K 时用 `anchor * relative` 还原世界位姿。**禁止**在 authoring 里每帧跟锚点。

## 目标

相机轨关键帧在绑定角色（或场景 Part/Attachment）后，存储 **相对锚点的 CFrame**；求值时 `world = anchor * relative`，使同一过场在不同世界坐标、不同玩家位置播放时镜头构图相对角色一致（Cinemachine Follow + 固定 offset 模型）。

## 现状（M0 对表）

| 模块 | 现状 |
|------|------|
| `CutsceneFormat.Track` | 仅有 `target`（vcam 名）、`keyframes[].value` 为世界 CFrame |
| `CameraDirector.evaluate` | 直接 `Sampler.sampleCFrame`，无锚点 |
| `App.luau` | `bindingChip` 刻意跳过 camera；`cameraRowControls` 只有 ◠ / ⏺ |
| `EditorState.captureFrame` | 原样写入世界 CFrame |
| `SceneResolver` | 已有 Player → 占位 rig，可复用为插件侧 resolver |
| 求值入口 | `LivePreview`、`CameraPath`、`PreviewViewport`、`CameraTrack` 均走同一 `CameraDirector.evaluate`（**禁止两套公式**） |

## 数据模型（M1）

在 **`kind == "camera"`** 的轨上增加 **轨级** 字段（段间共享，段内禁止改绑）：

| 字段 | 类型 | 说明 |
|------|------|------|
| `followBinding` | `Binding?` | 逻辑绑定名，如 `"Player"`；缺省 / 空 = 世界空间 key（与旧数据一致） |
| `followPart` | `string?` | 锚点在实例下的相对路径；缺省 `"HumanoidRootPart"` |

- 一条 camera 轨 **一个** `followBinding` + `followPart`。
- **同轨多段蓝条**共享同一绑定；**不允许**段内或段间在同轨上改绑（避免同轨前半世界、后半相对）。多角色过场 → 多条 camera 轨或不同 vcam，而不是一段里换绑。
- `cameraMove` 轨 MVP **不**做 follow（仍世界 CFrame 驱动 vcam Part）；若日后需要再单开规格。

## 语义与公式

### 存储

- 有 `followBinding` 且解析到锚点 `anchor: CFrame` 时，key 存 **相对** CFrame：  
  `relative = anchor:ToObjectSpace(worldAtCapture)`
- 无绑定或录制时无锚点：key 仍存 **世界** CFrame（legacy）。

### 求值（唯一公式，M2）

```text
relative = Sampler.sampleCFrame(track.keyframes, t, track.smooth)  -- 或 VCamPose 分支见下
若 track.followBinding 且 resolveFollowAnchor 成功:
  world = anchor * relative
否则:
  world = relative   -- 含缺失锚点回退，见下
```

- 若 `followBinding` 有值但 **keyframes 为空**，仍走现有 `VCamPose.at`（MVP 不对 vcam 静态位做跟绑）。
- **相对旋转（M0 定稿）**：全程使用 **完整相对 CFrame**（位置 + 旋转均在锚点局部空间），与 Follow + 固定 offset 一致；环绕、过肩、跟手武器均在此模型下。

### Phase 2（非 MVP，仅枚举占位）

若需要「位置跟 HRP、朝向偏世界 / 固定 pitch」（LookAt 混合），再增加轨级 `followRotationMode: "full" | "positionOnly"` 或 `followSpace`。**M1–M4 不实现**，避免两套求值分叉。

## 锚点解析（M1 — `FollowAnchor.luau`）

统一 API（插件 SceneResolver 与 runtime `BindingResolver` **同路径语义**）：

```text
resolveFollowAnchor(
  followBinding: Binding,
  followPart: string?,
  resolveBinding: (Binding) -> Instance?
) -> CFrame?
```

| 路径末节点 | CFrame 来源 |
|------------|-------------|
| `Attachment` | `Attachment.WorldCFrame` |
| `BasePart` | `Part.CFrame` |
| 缺省 `followPart` | 实例下 `HumanoidRootPart`（Character）或实例自身（Model 无 HRP 时 warn） |

- UI：**M3** 默认只选角色 + HRP；**M5** 二级选骨骼名 / Attachment 相对路径。

## `CameraDirector` API（M2）

共享层扩展，避免 plugin / runtime 各写一遍：

```lua
CameraDirector.evaluate(
  cutscene: Cutscene,
  t: number,
  resolveBinding?: BindingResolver  -- 可选；缺省不跟绑，行为与今一致
): (CFrame?, string?)
```

内部：`relative = sample(...)` → 若当前上镜 `camera` 轨有 `followBinding` 且 `resolveBinding` → `world = anchor * relative`，否则 `world = relative`。

所有消费方传入同一 `config.resolver`（或等价）：`CutscenePlayer`、`LivePreview`、`CameraPath`、`PreviewViewport`、插件 `CameraTrack` 预览。

## 录制与视口 A（M4）

| 步骤 | 行为 |
|------|------|
| **K / captureFrame** | 视口仍采 `CurrentCamera.CFrame`（世界）；若轨有 `followBinding` 且锚点存在 → 写入 `ToObjectSpace(anchor)` |
| **双击 K / snapViewport** | `world = anchor * kf.value` 再 `CameraAuthoring.snapViewport` |
| **LivePreview / 播放** | 仅 `CameraDirector.evaluate` + resolver，authoring 期间不写每帧跟锚 |

共用 helper 建议名：`worldFromTrackKeyframe(track, sampledRelative, resolveBinding)`，与 director 内逻辑一致。

## 缺失锚点回退（M0 写死）

1. **warn 一次**（可按轨 id / 轨引用去重），说明 binding + part 无法解析。
2. 该轨 key **按存储值当世界 CFrame** 求值（与无 `followBinding` 的旧数据一致，不 silent 崩、不插零矩阵）。

## 编辑器（M3 / M5）

| 阶段 | 内容 |
|------|------|
| **M3** | `EditorState.setCameraFollow(track, binding?, followPart?)`；左栏相机行 **「跟随▾」** 芯片（与 transform 绑定 UX 对齐但独立）；改绑 / 改 followPart **各一步 undo** |
| **换绑 A→B** | **保持** key / 切线相对数值；只改 `followBinding`（不经过世界空间重算）。清除跟随时仍迁回世界 key。 |
| **M5** | Attachment / 骨骼路径选择器；「重置相对原点」等工具 |

`bindingChip` 对 camera 轨 **不再跳过**；仍不混淆 `target`（vcam 名）与 `followBinding`（跟谁）。

## 与 05 模式 A/B 的关系

- **模式 A（authoring）**：进入时一次性 `snapViewport` / 初始 CFrame；**不** RenderStepped 跟锚。
- **模式 B（LivePreview / 成片）**：Scriptable + 按 playhead 走 `CameraDirector.evaluate`（含 follow）。
- 绑跟随时 A 的 WASD + K 语义不变：人眼对世界构图，数据层相对锚。

## 实现顺序

| 阶段 | 要点 |
|------|------|
| **M1** | `CutsceneFormat` 字段 + `shared/FollowAnchor.luau` |
| **M2** | `CameraDirector` + `CutscenePlayer` / `CameraTrack` 传入 `resolveBinding` |
| **M3** | `EditorState.setCameraFollow` + 左栏「跟随▾」+ undo |
| **M4** | `captureFrame` / Recorder / LivePreview / `CameraPath.poseOnCameraTrack` 共用 director 或同一 world helper |
| **M5** | Attachment 选择器、重置相对原点等 |

## 验收（M0）

- [ ] 绑 Player + HRP，3 个相对 K，拖 HRP → LivePreview 镜头贴人。
- [ ] 导出后在不同世界坐标播 cutscene，镜头相对角色一致。
- [ ] 无 `followBinding` 的轨 / `boss_intro` **零行为变更**。
- [ ] 无 Model / 解析失败 → warn + 世界 K 回退。
- [ ] 改绑 / 改 `followPart` 各一步 undo。

## 非目标（MVP）

- 段内 / 同轨换绑；`cameraMove` follow；vcam 静态位跟绑；`followRotationMode` 实现；运行时与插件两套求值公式。

## 团队对表

对本文无异议即可从 **M1** 起开工。变更字段语义或回退策略前先改本文。
