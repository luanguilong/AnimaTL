# 05 — 相机轨透视编辑（视口 A）行为规格

> Milestone M0 约定。M1+ 实现以本文为准；变更需团队对表后再改代码。

## 模式概览

选中时间轴 **camera 轨**（M4 可扩 **cameraMove**）时进入 **透视选中轨 / 视口 A**：主编辑视口用于 WASD 摆构图并打帧；**不**随播放头对 key 插值驱动主视口。成片预览走 **主视口跟随** 或 **内嵌/独立预览条**（按 playhead 求值）。

## 约定表

| 条目 | 约定 |
|------|------|
| **进入条件** | 时间轴选中 `kind == "camera"` 的轨（`target` = vcam 名）。M4：`cameraMove` 同 target 亦进入。 |
| **退出条件** | 取消选中 / 选中非相机轨 / 开启「跟随成片」/ **播放中** / **视口对帧**（KeyframeAdjust）/ 相机轨行内 ⏺ 录制中 / 全局 Record 录制（互斥时退出并提示）。 |
| **视口 A** | `CurrentCamera.CameraType = Custom`；进入时 `CFrame = VCam.resolvePose(target)` **一次**；**禁止**在 authoring 期间用 RenderStepped 写 `CurrentCamera`（与跟随模式 B 划界）。拖播放头 **不** 改变主视口构图。 |
| **打帧 2a**（M2） | `captureFrame(track, workspace.CurrentCamera.CFrame, currentTime)`；写入轨数据，非 Part（除非 Part 已与视口一致）。 |
| **与 vcam Part** | 打帧可不改 Part（数据以轨为准）；M3 可选「打帧后 `Part.CFrame ← kf.value`」便于下一帧待摆。 |
| **互斥** | 与 `LivePreview.start`（跟随）、`Playback`、`KeyframeAdjust`、相机轨 ⏺ / Record 互斥；冲突时先退出 authoring 或阻止进入，并 `print` 简短提示。 |
| **3D 轨迹** | 选中轨时 `CameraPath` 只画该 vcam 相关轨迹（M3/M5）；authoring 下把手拖拽写回 key（M5）。 |

## 职责边界

| 模块 | 主视口 `CurrentCamera` |
|------|------------------------|
| **CameraAuthoring**（A） | 进入时设 Custom + 初始 CFrame；**无**每帧写入 |
| **LivePreview**（B） | Scriptable + RenderStepped 按 playhead 成片求值 |
| **KeyframeAdjust** | 对单帧 Scriptable 式取景，每帧写回该 key |
| **PreviewViewport** | 仅 `ViewportFrame`，不动主视口 |

## 创建相机轨(收口)

- **唯一入口**:顶栏 **「＋ 相机」** → `VCamAuthoring.create` + `EditorState.addCameraTrack`(默认整段蓝条)。
- 右键「添加轨道」、分组 **＋**、时间轴空白 **＋** 中 **不再** 创建 `camera` / `cameraMove` 轨;仅提示使用顶栏 **＋ 相机**。
- 已有 `cameraMove` 轨仍可编辑/打帧/预览;只是不能从菜单新建。

## 关键帧双击跳转

- 在 **camera** / **cameraMove** 轨上 **双击** 菱形关键帧(两次点击间隔 < 0.35s,与轨道重命名一致):
  - `setTime(kf.t)`;选中该轨;
  - `CameraAuthoring.snapViewport(vcam, kf.value)`:主视口 **Custom + 完整 CFrame 位移/朝向**,进入透视 A,便于 **WASD 微调 + K 打帧**(**不**进 KeyframeAdjust)。
- `snapViewport` 内与跟随/播放/对帧/录制互斥(同 `enter`)。
- 右键「定位到此帧」仍 **只改播放头**,不改视口。

## 相机蓝条拖拽

- 平移与 **左右缘改长度** 均只走 `beginTimelineDrag`(holdDrag + `HOLD_SEC`),无即时拖。
- 改长度:按下点落在块左右 **8px** 内;中间区域为整段平移;左右缘条为纯展示(`Active=false`)。

## 同轨多段蓝条

- 一条 `kind == "camera"` 轨的 `segments[]` 可有多项;时间轴同轨并列多条蓝条。
- **不允许重叠**:`addSegment` / `setSegmentRange` 会 clamp 后段起点;零长度段删除。
- 轨级右键 **「＋ 添加生效段（无关键帧）」**:仅插入 `{ from, to }`,不 `captureFrame`、不加菱形 K(蓝条块上「在播放头处加一段」仍保留)。

## MVP 范围

最小可用：**M0 + M1 + M2 + M3（打帧后同步 Part）**。✅ M4 合并 camera/cameraMove 显示、✅ M5 把手 undo + authoring 共存。

## M4 / M5 已实现要点

- **M4**：选中 `camera` 或 `cameraMove`（同 `target`）→ 一条合并蓝线（camera 轨生效段内对该 vcam 求值）；把手 = 两轨所有 CFrame key（青 = camera 轨，紫 = cameraMove）。
- **M5**：authoring 下可拖把手写回已有 key；连续拖拽算 **一步** undo（松手约 0.4s 后下一拖为新一步）；**K** 仍各自一步 undo。相机轨 ⏺ 与透视编辑互斥，控制台提示优先 **WASD + K**。

## 验收（M0）

团队对本文无异议即可按 M1 起开工。
