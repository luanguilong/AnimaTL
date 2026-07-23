# 10 — 编辑器内容保留（草稿 / 导入 / 另存）

**状态**：M0 定稿（P0 已实现）

## 问题

Timeline 编辑仅存于内存；关 Studio / 关面板 / 换插件后丢失。仅有 💾 导出到 `AnimaExport`,无回读。

## P0 行为

### 自动草稿（Plugin GetSetting）

- 键：`AnimaEditorDraft_v1`（Serializer 输出的完整 Luau 模块字符串）
- `revision` 变更后 **debounce 2s** 写入
- `plugin.Unloading` 时立即 flush
- **启动插件**：若有合法 draft → 优先 `deserialize` 恢复,Output 提示；否则 `boss_intro` / `untitled`

### 工具条

| 按钮 | 作用 |
|------|------|
| **📄 新建** | `untitled` 空过场,清 draft |
| **📂 导入** | 菜单:AnimaExport / Explorer 选中 ModuleScript |
| **📁 另存** | 写入 `ReplicatedStorage.Anima.Cutscenes.<name>` ModuleScript |
| **↺ 草稿** | 手动从 GetSetting 再载一次 |
| **💾 导出** | 同前 + **清除 draft**（已交 Git 的仍以导出为准） |

### 反序列化

- `Serializer.deserialize(src)`：仅接受本插件生成的 `local cutscene = { ... } return cutscene` 模块文本；临时 ModuleScript `require`,不用 `loadstring` 任意代码。

## 优先级

1. 有 draft → 恢复 draft  
2. 无 draft → `loadInitialCutscene()`（Place 内 boss_intro 或 untitled）

## 非目标（P1）

- 按 PlaceId 分 draft  
- 侧栏多过场列表  
- 导入前覆盖确认弹窗（可后续加）

## 对表

`showhand-template/anima/10-editor-persistence-spec.md`
