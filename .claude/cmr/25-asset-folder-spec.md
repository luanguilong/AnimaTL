# 25 — 美术资源引用规则 + 编辑器资源/挂点选择器规格

**状态:V1 已落地(2026-07-24;当天按用户反馈修订)。**

> **修订(2026-07-24 当天)**:①资源根从固定 `AnimaAssets` 文件夹放宽为
> **ReplicatedStorage 下任意位置**(递归扫描,跳过 Anima 运行时树;workspace 视为
> 旧位置提示迁移);②forge cue 新增可选 **`attachBone`**——加特效第二步弹窗列出
> 绑定目标下全部 BasePart 名,可选挂点(空 = 不挂),emit 前把包 Pivot 到该骨骼并挂
> 其下;运行时/编辑预览/自动挂包三条路径同源生效。以下原文按修订理解。

## 目标 / 价值

特效包(Forge VFX Model)的存放与引用从"三处松散兜底 + 手输名字"收敛为
**一个约定文件夹 + 插件列表点选**:

- 美术知道东西该放哪;创作者不再拼错包名;
- 编辑器预览第一次能可靠找到包(自动临时挂到预览 rig),编辑期 forge 预览与运行时对齐;
- 复制(打包 place)时资源随 ReplicatedStorage 走,不散落 workspace。

## 约定(数据契约零改动)

- 唯一美术资源根:**`ReplicatedStorage.AnimaAssets`**(Folder),子文件夹随意分类
  (如 `AnimaAssets/VFX/驴踢`)。VFX 包 = 其中的 **Model**。
- cue 数据不变:`forgeRoot` 仍存包名字符串,已导出过场全兼容。
- 查找顺序(shared/AnimaAssets.findPack):**AnimaAssets 递归 → 旧位置**
  (`ReplicatedStorage.Assets` 子级 → ReplicatedStorage 顶层 → workspace 递归);
  旧位置命中时 warn 一次提示迁移。
- **重名策略**:选择器显示相对路径区分;运行时取第一个命中并 warn;
  导出校验对 AnimaAssets 内重名 Model 提醒(不阻断)。

## 实现

- **`shared/AnimaAssets.luau`**(插件与运行时共用):
  `FOLDER_NAME` / `root(create?)` / `listPacks() -> {name, path, model}` /
  `findPack(name) -> (Model?, isLegacy)`。
- **运行时**:AnimaBootstrap 的 `findVfxTemplate` 改走 `AnimaAssets.findPack`。
- **编辑器**:
  - 特效轨「＋ Forge 特效…」与 cue 右键「改 forgeRoot…」改为**资源列表菜单**
    (递归列 AnimaAssets 下 Model,显示相对路径;保留「手输…」兜底;
    文件夹不存在时给「＋ 创建 AnimaAssets 文件夹」)。
  - **预览自动挂包**:`EffectTrack.runForgeEditorPreview` 找不到 emit 根时,
    用 `AnimaAssets.findPack(forgeRoot)` 找到包 → 临时 clone 到绑定目标下,
    记入 `_editorTempClones`,`stop()` 统一销毁(不污染场景)。
  - **导出校验**:forge cue 的包在任何位置都找不到 → 提醒;仅旧位置找到 → 提示迁移;
    AnimaAssets 内重名 → 提醒。

## 非目标

- 不管理动画 id / 音效 id / 贴图(V2 看需求,选择器结构可复用)。
- 不做资源缩略图预览。
- 不自动迁移旧位置资源(提示人工挪,避免动用户的场景)。
