# 12 — 过场总时长(duration)自定义

**M0 定稿** | 对表：`showhand-template/anima/12-timeline-duration-spec.md`

## 契约

- `Cutscene.duration`（秒）= 时间轴与 `CutscenePlayer` 播放终点。
- `Cutscene.fps` 仅编辑期显示/吸附；改时长量化到 `1/fps`。

## 插件

| 入口 | 行为 |
|------|------|
| 工具条 `帧 cur/total · xs` 点击 | 菜单：改总帧数 / 改总秒 / 适应全部 / 适应选中轨 |
| `setDuration(sec)` | 量化到帧；**缩短**时 clamp 全轨(含 clip.endAt、segment、关键帧等)，删零长度 clip/段 |
| `fitDurationToContent` | `max(内容终点) + 0.5s` 尾缓冲 |

## 与 11 spec

自动写 clip.endAt **不**拉长过场；需更长时用「适应内容」或手动改总帧数。

## Runtime

无变更（已用 `cutscene.duration`）。
