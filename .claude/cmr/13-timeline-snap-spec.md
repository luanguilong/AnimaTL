# 13 — 时间轴磁吸（Snap）增强



与 `showhand-template/anima/13-timeline-snap-spec.md` 对表；**完整交接 Prompt 以 showhand 版为准**（含仓库路径、源码、build 输出、验收）。



## 常改源码（V1 ✅ 已落地）

| 模块 | 路径 |
|------|------|
| `snapCandidateTimes` / `draggedTime` / 缘拖 priority | `src/plugin/App.luau` |
| `snapTime`（priority 同距离胜整秒） | `src/plugin/DragController.luau` |
| 插件包 | `build/anima.rbxm` |

## 实现要点（V1）

- `snapCandidateTimes`：本轨 `markTimesForTrack(skip)` + `currentTime`；**Shift** → `markTimesOtherTracks`。
- 缘拖 `edgeMode`：`from` 优先邻居 `endAt`/`to`，`to` 优先邻居 `startAt`/`from`。
- **Alt**（左右）：跳过磁吸与帧量化；**RightAlt** 与 LeftAlt 一致。

## 产品结论



- **V1**：同轨头尾接龙 + 吸播放头 + 整秒/整帧 + Alt 自由拖  

- **V2**：Shift 跨轨吸附（后做）

