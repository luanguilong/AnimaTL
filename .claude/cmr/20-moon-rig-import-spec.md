# 20 — Moon rig 关节动画导入(T4)

**状态:V1 已实现(2026-07-23;spike 已在 'axe cam' 存档上验证数学)。**

## Spike 结论(2026-07-23,'axe cam' 实测)

- Rig 项文件夹 → `Rig` 子文件夹 → 多个 `_joint`:`_hier`(StringValue,关节路径如
  `Torso.Head`,段名 = Motor6D.Part1 的名字)、`default`(CFrameValue,静止位姿)、
  `_keyframes`(帧号文件夹;**一个包可跨多帧**:Values.0..N = 从该帧起的连续 N+1 帧)。
- **Motor6D.Transform = 帧值:Inverse() × default**(与 Moonlite 一致);烘焙数据常见
  逐帧一值(54 帧),缓动可忽略(linear)。

## 契约

```lua
export type JointTrack = { path: string, keyframes: { Keyframe } } -- value=Motor6D.Transform
Track: kind = "rigAnim" + jointTracks: { JointTrack }?  -- target = 角色绑定
```

关节解析:目标 Model 内找 `Motor6D.Part1.Name == path 尾段`(R6 内唯一);找不到 warn 跳过。

## 运行时 runtime/RigAnimTrack.luau

- update(t):每关节 `Sampler.sampleCFrame` → `motor.Transform = cf`。
- stop:Transform 归 identity。Transform 是运行时瞬态属性,不落盘、无脏场景风险。
- 注意:与 animation 轨同角色同播时互踩(Animator 每帧也写 Transform),文档声明:
  同一角色 rigAnim 与 animation 轨二选一。

## 插件

- **导入**:Moon 导入菜单在相机轨之外同时导 Rig 项 → 每 rig 一条 rigAnim 轨,
  target=存档 rig 名(可右键换绑到 Player);逐 `_joint` 展开多帧包,t=帧/fps,linear。
- **时间轴**:V1 只渲染整块(首帧..末帧色块 + 关节数标签),不做逐 key 编辑
  (烘焙数据几十帧,菱形不可用);删除/换绑/隐藏走既有轨道菜单。
- **scrub 预览**:plugin/RigAnimPreview.luau,workspace 实时驱动 Motor6D.Transform,
  restore 归 identity;小窗克隆 V1 不做(留 V2)。
- 时长收敛 / contentEnd / 导出 slice 覆盖 jointTracks。

## V2 留口

小窗克隆驱动;转存 KeyframeSequence(需上传才能当 AnimationId 用);逐关节可视化/裁剪。
