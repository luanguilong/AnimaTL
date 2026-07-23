# 15 — 相机路径预览段数

与 `showhand-template/anima/15-camera-path-preview-segments-spec.md` 对表；**完整 Prompt 以 showhand 版为准**。

## 要点

- 「约 4 段」= `CameraPath` **预览折线**采样（`STEP`/`span`），不是贝塞尔 K 段数。
- 右键调 **预览精细度**；偏好存插件；不改 `CutsceneFormat` / runtime。

## 常改源码（V1 ✅）

| 模块 | 路径 |
|------|------|
| 采样段数 | `PathPreviewPrefs.luau` + `CameraPath.luau` |
| 菜单 / 切线右键 | `init.server.luau`、`App.luau` `cameraPathMenuItems` |
