# 18 — 动画 clip 真实时长回填(T2)

**状态:V1 已实现(2026-07-23)。**

## 问题

11 号 spec 只在"录入 id 时"回填 endAt;旧数据/导入/手写的 clip(endAt=nil)
时间轴宽度仍是估计值(+1.5s 或到下一 clip)。且 `AnimationTrack.Length` 在资源
未加载完成时为 0,`resolveSourceLength` 经常首次失败不再重试。

## 方案

- `AnimationAsset.resolveSourceLength`:LoadAnimation 后**有界等待** Length>0
  (0.1s 轮询,上限 3s),显著提高首次解析成功率。
- 新 `AnimationAsset.cachedLength(animationId, clip?)`:只查缓存不解析(UI 每帧安全)。
- 新 `AnimationAsset.prefetchCutscene(cutscene, onResolved)`:后台 task.spawn 逐 clip
  解析(缓存命中/空 id 跳过);有新解析成功时回调一次(调用方 commitTracks(false) 重绘)。
- init.server:revision Observer 里触发 prefetch(缓存使重复触发近零成本)。
- App `clipBlock` 宽度:`clipTimelineEnd(clip, nextT, AnimationAsset.cachedLength(...))`
  ——endAt=nil 时用真实源时长(÷speed),数据语义不变(不回写 endAt)。
