# 09 — 音效轨 & 特效轨

**状态**：M0 定稿（与 `CutsceneFormat` / runtime / 插件 UI 同步）

## 目标

「＋轨道」菜单增加 **音效轨道**、**特效轨道**（均需 **选择绑定**）。时间轴菱形 cue 编辑 SoundId / 粒子模板；导出 `.luau`；`CutscenePlayer` 到点播放；scrub 可预览。

## 与 event（标记）轨分工

| 轨 | 用途 |
|----|------|
| `event` | 玩法信号名 → `onEvent`（无结构化资源 UI） |
| `sound` | `soundCues[]`，runtime 默认 `Sound:Play()` |
| `effect` | `effectCues[]`，runtime 默认 `templateName:Emit` 或 `particleAssetId` LoadAsset；**forge** 见 16 |

## 契约

`TrackKind` += `"sound" | "effect"`

```lua
export type SoundCue = {
	t: number,
	soundId: string,
	volume: number?,
	playbackSpeed: number?,
	looped: boolean?,
	maxDistance: number?,
}

export type EffectCue = {
	t: number,
	particleAssetId: string?,
	templateName: string?,
	emitCount: number?,
	duration: number?,
}
```

Track 字段：`soundCues` / `effectCues`；`target` = Binding（发声/挂点）。

## 运行时

- `SoundTrack` / `EffectTrack`：与 `EventTrack` 相同「到点一次、seek 补发、`stop` 清理」。
- `CutscenePlayer` Config：`onSoundCue?` / `onEffectCue?`；缺省走内置 Roblox API。
- 不 require B2；游戏侧可注入 handler 接 Shared Sound/Particle。

## 插件

- `showAddTrackMenu`：音效/特效 → 选择绑定
- 轨道右键：＋音效 / ＋特效（支持 `atTime`）
- cue 菱形：拖动改 `t`；右键改字段
- `MediaPreview`：scrub 预览（大跳跃重置防爆音）

## 验收

- [ ] ＋轨道 两项可见；绑定芯片可换绑
- [ ] 导出 round-trip
- [ ] Play 过场到点发声/出特效
- [ ] 旧 cutscene 无 sound/effect 轨不受影响

## 对表

`showhand-template/anima/09-sound-effect-tracks-spec.md`
