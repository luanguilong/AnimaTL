# 08 — AnimationClip.rigType（R6 / R15 单文件双 clip）

**状态**：M0 定稿（与 `CutsceneFormat` 实现同步）

## 目标

同一过场模块内，animation 轨可在 **相同 `startAt`** 挂两条 clip（R6 / R15 各一 `animationId`），**event / camera / transform 只维护一份**。运行时与插件预览按目标 `Humanoid.RigType` 自动择一播放。

## 契约

`AnimationClip` 增加可选字段：

| 字段 | 类型 | 说明 |
|------|------|------|
| `rigType` | `"R6" \| "R15" \| nil` | `nil` = 两种 Rig 均匹配（兼容旧 cutscene） |

## 匹配规则（`CutsceneFormat.clipMatchesRig`）

| `clip.rigType` | 匹配 |
|----------------|------|
| `nil` | R6、R15 |
| `"R6"` | 仅 `HumanoidRigType.R6` |
| `"R15"` | 仅 `HumanoidRigType.R15` |

## 同轨同 `startAt` 多条

- 允许：一条 `rigType = "R6"` + 一条 `rigType = "R15"`（大招/过场双资产）。
- 若 **多条均匹配当前 Rig**（如两个 `nil` 或两个 `R6`）：warn 一次，**保留 clips 数组中第一条匹配的**（`clipsForRig`）。

## 消费方

| 模块 | 行为 |
|------|------|
| `CutscenePlayer` | 建 `_clips` 时对每条 animation 轨调用 `clipsForRig(track.clips, hum.RigType)` |
| `AnimationPreview` | `stepClipsOnModel` 同样过滤；停掉 cache 中不再匹配的 animId |
| `Serializer` | `rigType` 非 nil 时导出 |
| 插件 UI | clip 右键：R6 专用 / R15 专用 / 不限；时间轴副标题 `[R6]` / `[R15]` |

## 导出示例

```lua
{
	kind = "animation",
	target = "Player",
	clips = {
		{ animationId = "rbxassetid://R6_ID", startAt = 0, rigType = "R6" },
		{ animationId = "rbxassetid://R15_ID", startAt = 0, rigType = "R15" },
	},
},
```

## 非目标

- 不从 AnimationId 自动推断 Rig
- 不支持 Rthro / 自定义 Rig 枚举（后续可扩展 `RigTypeName`）

## 对表

- 模板仓库：`showhand-template/anima/08-animation-rig-type-spec.md`
