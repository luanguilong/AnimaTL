# 21 — 缓动扩展(T5 第一阶段)

**状态:V1 已实现(2026-07-23)。逐 key 贝塞尔 / graph editor 后置(不在本批)。**

- `Easing.luau` 新增:expoIn/Out/InOut、backIn/Out/InOut、elasticOut、bounceOut
  (标准 Penner 公式);`Easing.names` = 全量名单,UI 菜单顺序即此。
- `CutsceneFormat.EasingName` union 同步扩展(纯新增,旧数据不受影响)。
- App 两处缓动菜单(CFrame 关键帧 / 属性关键帧)改读 `Easing.names`,不再硬编码。
- `MoonImport.mapEase`:Expo/Back(带方向)、Elastic→elasticOut、Bounce→bounceOut
  精确映射;Cubic/Quart/Quint 仍归 cubicInOut。
- 运行时零改动(Easing.apply 按名查表,未知名回退 linear——旧运行时遇新名也不炸)。
