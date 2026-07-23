# 11 — AnimationClip 时间轴时长(endAt)与自动匹配

**M0 定稿** | 对表：`showhand-template/anima/11-animation-clip-duration-spec.md`

## 契约

`CutsceneFormat.AnimationClip` 增加可选字段：

| 字段 | 含义 |
|------|------|
| `endAt: number?` | 过场时间轴上的结束时刻(秒)。**nil** = 预览/运行时用 `AnimationTrack.Length ÷ speed` 推断右端。 |

共享 API：`CutsceneFormat.clipTimelineEnd`、`CutsceneFormat.clipTimePositionAt`。

## 插件

- 录入/修改 `animationId` → `AnimationAsset.resolveSourceLength` → 写 `endAt = startAt + round(Length/speed, fps)`，**不**自动拉长过场 `duration`。
- 时间块 UI：左/右缘 ~10px 改 `startAt`/`endAt`；中间长按平移；最小时长 1 帧。
- 同轨 `resolveClipOverlaps`：不重叠、不零长度。
- 右键：改结束帧、按动画时长重算条长。

## 运行时

- 预览：`AnimationPreview` 用 `clipTimePositionAt` 定帧；`endAt` 外保持窗口末帧。
- 播放：`CutscenePlayer` 在 `t > endAt` 且非 loop 时 `stopClip`。

## 兼容

旧数据无 `endAt`：行为与改前一致(推断全长度)。
