# 07 — 相机轨贝塞尔路径（钢笔式切线 + Studio 反向编辑）

> Milestone M0。实现前团队对表；变更先改本文再改代码。  
> 依赖：[05 — 视口 A](./05-viewport-a-spec.md)、[06 — followBinding](./06-follow-binding-spec.md)。求值仍禁止 plugin/runtime 两套公式。  
> 索引：[anima/README.md](./README.md)

## 现状（anima）

| 能力 | 实现 | 和目标的差距 |
|------|------|--------------|
| 「曲线」 | 轨级 `smooth` → Sampler 里 Catmull-Rom 只插**位置**，≥3 个 K；旋转仍是 Lerp | 控制点不可拖，形状由邻点自动决定 |
| 3D 轨迹 | CameraPath 按步长折线采样显示 | 不是真贝塞尔，也没有切线把手 |
| 反向编辑 | 机位长方体 Part 拖 → 写回 `keyframes[i].value`（含 follow 相对空间） | 只改锚点 CFrame，不改曲线切线 |
| 求值入口 | 仍应只走 Sampler → CameraDirector（+ FollowAnchor） | 新曲线类型也要一套公式 |

**结论**：不要在 Catmull 上硬加 UI；应增加显式贝塞尔切线数据 + 共享层采样 + CameraPath 切线 gizmo，与 [05](./05-viewport-a-spec.md) 视口 A、[06](./06-follow-binding-spec.md) 跟随绑定兼容。

## 思路摘要（钢笔工具模型）

一段（两个时间锚点 Kᵢ、Kᵢ₊₁）= 一条三次贝塞尔（**位置**）

- P0 = Kᵢ 的位置（锚点，对应菱形 K 的机位）
- P3 = Kᵢ₊₁ 的位置
- P1 = Kᵢ 的**出切线**控制点
- P2 = Kᵢ₊₁ 的**入切线**控制点

时间 t ∈ [tᵢ, tᵢ₊₁]：先算 `u = Easing.apply(kf[i+1].easing, (t-tᵢ)/(tᵢ₊₁-tᵢ))`，再

`position(u) = Bezier(P0, P1, P2, P3, u)`

旋转 MVP：CFrame 在 P0/P3 对应锚点的旋转之间 Slerp(u)（与现在 smooth 段一致，切线只塑形轨迹，不塑旋转）。

### 存储建议（MVP）——挂在 Keyframe 上，避免第二套点表

```lua
-- 可选；缺省 = 直线段（P1=P0, P2=P3）或自动从 Catmull 迁移
outTangent: Vector3?,  -- 相对锚点位置的偏移（与 follow 同空间：有 followBinding 则在锚点局部）
inTangent: Vector3?,
```

- 有 `followBinding`：`kf.value` 已是相对 CFrame；切线 offset 也在**同一锚点局部**（拖 HRP 时曲线一起动）。
- 无 follow：offset 用世界空间（推荐，和当前世界 K 一致）。

### Studio 交互（类似钢笔）

| 操作 | 行为 |
|------|------|
| 查看 | 选中 camera / cameraMove → CameraPath 画贝塞尔段 + 细线连控制点 |
| 选段 | 点时间轴两 K 之间 / 点 3D 曲线 → 高亮该段，显示 P1、P2 小球 |
| 拖切线 | 拖 P1/P2 → 写 `outTangent`/`inTangent` → revision++ → LivePreview 跟 playhead |
| 拖锚点 | 沿用 M5 机位把手 → 仍改 `kf.value`（+ FollowAnchor 存相对） |
| 模式切换 | 轨级 `pathMode: "linear" \| "bezier"`；◠ 按钮可改为「贝塞尔/直线」 |
| 新建段 | 钢笔式「在曲线后点一下加 K」可 Phase 2；MVP 仍 K 打帧 + 拖切线 |

### 反向编辑要覆盖的三类对象

| 对象 | 写回字段 | undo |
|------|----------|------|
| 机位把手 | `keyframes[i].value` | 连续拖一步（已有） |
| 切线把手 | `outTangent` / `inTangent` | 同 M5 0.4s 规则 |
| KeyframeAdjust / 视口对帧 | 只改当前 t 的锚点 `value` | 已有 |

### 难点（写进 spec）

- **时间 vs 弧长**：播放头按时间走，贝塞尔按 u；MVP 用时间归一化即可，快轨/慢轨靠 K 之间时间疏密调节。
- **段间 C¹ 连续**：钢笔「对称柄」可选；MVP 允许角点（in/out 独立）。
- **与 Catmull 迁移**：打开 bezier 时，可由邻点拟合初始 P1/P2，避免形状突变。

---

## 目标

在 camera / cameraMove 轨上，除时间锚点关键帧外，支持**三次贝塞尔路径编辑**：

- 相邻两锚点之间**两个可拖控制点**（出切线 / 入切线），类似矢量钢笔。
- Roblox Studio **3D 视口**内可视化 + **反向编辑**（拖 gizmo 写回数据）。
- 播放预览（LivePreview / PreviewViewport / CameraPath 头点 / runtime CameraDirector）与编辑使用**同一采样器**。

## 非目标（MVP）

- 时间轴 2D Graph Editor（见 roadmap P2，另 spec）。
- 旋转也走贝塞尔（MVP 旋转 = 锚点间 Slerp + 原有 easing）。
- 弧长匀速 reparameterization、自动避障、多段 NURBS。
- 段内插入锚点的完整「钢笔连续点击」工作流（可 Phase 2）。

## 数据模型（M1 — CutsceneFormat）

在 `Track` 上（或替代 `smooth`）：

- `pathMode: "linear" | "bezier"?` — 缺省 `linear`；`bezier` 启用切线采样。
- legacy：`smooth == true` 且无切线数据时，行为与现网一致（Catmull-Rom）；**不自动删 smooth**，迁移工具可选。

在 `Keyframe` 上（`kind` 为 camera / cameraMove；transform 可 Phase 2，MVP 仅 camera+cameraMove）：

- `outTangent: Vector3?` — 从**锚点位置**指向出控制点的偏移。
- `inTangent: Vector3?` — 从**锚点位置**指向入控制点的偏移（首帧 in、末帧 out 可空）。

**空间约定（与 [06](./06-follow-binding-spec.md) 一致）**

- 若轨有 `followBinding` 且该 key 存相对 CFrame：`value` 与 `outTangent`/`inTangent` 均在 **follow 锚点局部空间**（同一 resolver 下的锚点 CFrame）。
- 否则：世界空间 offset（相对 `value.Position`）。

缺省切线：直线段 `P1=P0`, `P2=P3`（等价 linear 位置插值）。

## 采样（M1 — shared/PathBezier.luau 或扩展 Sampler）

唯一 API（示意）：

```text
sampleSegment(anchor0: CFrame, anchor1: CFrame, outTan: Vector3?, inTan: Vector3?, u: number) -> CFrame
sampleCFrame(keyframes, t, track: Track, resolveBinding?) -> CFrame?  -- 内部合并 pathMode + legacy smooth + follow 世界化
```

规则：

- 段 [i,i+1]：`u` 来自后一 key 的 easing 作用于归一化时间。
- 位置：`Bezier(P0,P1,P2,P3,u)`，Pi 由 anchor 位置 + tangent 偏移构成。
- 旋转：`anchor0:Lerp(anchor1, u)` 或 Slerp。
- CameraDirector / FollowAnchor：不在 director 内分叉；follow 仍在采样得到相对 pose 后 `anchor * relative`（切线已含在相对位置路径里）。

## 编辑器 — CameraPath（M3）

- 选中 vcam 相关轨时：轨迹改为按贝塞尔解析采样（提高段内采样密度），绘制控制臂（P0–P1、P3–P2）。
- Gizmo 层级：锚点把手（已有）+ 切线把手（小球，名称规范便于 `consumeTangentEdits`）。
- 切线拖曳 → 更新 tangent 字段；连续拖一步 undo（与 M5 机位相同 0.4s 规则）。
- rebuild 时切线显示用 `FollowAnchor.worldFrom...` 转世界（仅可视化）。

## 编辑器 — 时间轴 / 左栏（M2）

- 相机轨 ◠/— 扩展为或并列：路径：直线 | 贝塞尔（`setTrackPathMode`）。
- 右键关键帧 / 段：「转为贝塞尔（保留形状）」 — 从当前 Catmull/直线拟合初始 tangents。
- 右键：「重置切线（直线段）」。

## 反向编辑矩阵（M4 — 必须验收）

| 操作 | 行为 |
|------|------|
| 拖机位把手 | 写 `kf.value`；follow 轨用 `FollowAnchor.storeKeyframeCFrame` |
| 拖切线把手 | 写 `outTangent`/`inTangent`；不改 t |
| KeyframeAdjust | 视口取景写锚点 value（存储空间），不写切线 |
| 双击 K / snapViewport | 世界构图 = `worldFromKeyframe(anchor)`，不是曲线上其它 t 的 sample |
| LivePreview 拖 playhead | sample 含贝塞尔 + follow |
| K 打帧 | 新 key 默认 in/out=0 或复制邻段切线策略（spec 写死：**默认 0**） |

**互斥（同 [05](./05-viewport-a-spec.md)）**

- 切线编辑与 Record / 相机轨 ⏺ / KeyframeAdjust 可并存与否：MVP 允许在 authoring 下拖切线；进入 KeyframeAdjust 时隐藏切线 gizmo 仅留锚点。播放中禁止写切线。

## 实现顺序

| 阶段 | 内容 |
|------|------|
| M1 | CutsceneFormat 字段 + PathBezier 采样 + Sampler/CameraDirector 接线 |
| M2 | EditorState：`setTrackPathMode`、`setKeyframeTangents`、拟合迁移 |
| M3 | CameraPath 贝塞尔绘制 + 切线 gizmo + `consumeTangentEdits` |
| M4 | init 写回、Serializer、LivePreview 回归；runtime 无 UI 仅采样 |
| M5 | 对称切线（Alt 拖）、段中插入 K、cameraMove 同 vcam 合并切线显示 ✅ |

## 验收

- [ ] 两 K bezier 段：拖 P1/P2，LivePreview 轨迹明显变弯，runtime 一致。
- [ ] follow Player+HRP：拖 HRP，弯轨相对角色不变形。
- [ ] 无 pathMode/bezier 的旧 cutscene / boss_intro 行为不变。
- [ ] 拖切线 / 拖锚点各一步 undo。
- [ ] 导出 luau 含 tangent 字段；重新导入可编辑。

## 开放问题（M0 定稿）

- transform 轨是否同期支持 bezier？（**建议 MVP 仅 camera+cameraMove**）
- 切线 offset 世界 vs 相机局部：无 follow 时**推荐世界**。
- camera 与 cameraMove 同 vcam 两条轨的切线是否共享 — **建议各轨各 keyframes，3D 仅合并显示**。

---

## 和「只加 smooth」的对比

| 方案 | 优点 | 缺点 |
|------|------|------|
| 继续 Catmull + 调 smooth | 零数据迁移 | **没有**两控制点，做不到钢笔 |
| **显式 Bezier 切线（推荐）** | 和钢笔一致、可反向编辑、runtime 确定 | 要新字段 + gizmo |
| 仅 2D Graph Editor | 精调 easing | 不是 3D 空间弯轨，和 Studio 路径不一致 |

**定稿方案**：Keyframe 上 `inTangent`/`outTangent` + 轨级 `pathMode=bezier`。
