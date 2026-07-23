# 16 — 特效轨对齐 Forge VFX（forge-vfx）

**M0 定稿（V1 已落地）**  
对表：`showhand-template/anima/16-forge-effect-track-spec.md`

内容与 showhand 版一致；实现见 `src/runtime/EffectTrack.luau`、`CutscenePlayer.luau`、`App.luau`（特效 cue UI）、`CutsceneFormat.luau`。

要点：Forge **不是** event；`effectCues` + `emitMode=forge` → 游戏 runtime `vfx.emit`；插件 scrub/▶ 用 **Enable+Emit 近似预览**（不 require ForgeVFX）。
