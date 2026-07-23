# 14 — 导出时间区间（帧/秒）

与 `showhand-template/anima/14-export-range-spec.md` 对表；**完整交接 Prompt 以 showhand 版为准**（含仓库路径、裁剪算法、验收）。

## 产品结论

- 导出前 **slice** 过场，`duration = to - from`，时间 rebasing；**不改编辑器**。
- **不新增** CutsceneFormat 字段；Runtime 无变更。

## 常改源码（V1 ✅）

| 模块 | 路径 |
|------|------|
| `slice` / `parseExportTimeInput` | `src/plugin/CutsceneExport.luau` |
| 导出向导第三步区间 | `src/plugin/init.server.luau` → `promptExportToPlace` |
