# 23 — 垂直滚动 + 关键帧复制粘贴(T7)

**状态:V1 已实现(2026-07-23)。**

## 垂直滚动

- 方案:**自绘偏移**(共享 `vScroll` Value,不用原生 Y 滚动)——保留"滚轮=缩放"的
  既有手感,避免 ScrollingFrame XY 与 zoom 抢滚轮。
- 右时间轴:ruler 抽出为 contentArea 固定子级(不透明底+高 ZIndex 罩住滚过的行);
  行放 offsetHolder,Position.Y = -vScroll。grid/播放头不动(纵向元素天然全高)。
- 左名列:表头条(轨道名称/＋轨道)移出 Computed 固定;行同样走 offsetHolder;
  列 Frame ClipsDescendants。
- 输入:时间轴内 **Shift+滚轮** = 垂直滚动(平滚轮仍缩放);左名列 **平滚轮** = 垂直滚动。
- 钳制:maxV = rulerHeight + 行数×trackHeight − 视口高;行数/视口变化与 vScroll
  变化时都重新钳制(Observer,收敛一次)。

## 关键帧复制粘贴(菜单剪贴板;Ctrl+C/V 待关键帧选中态,后置)

- 剪贴板(App 模块级单槽):cframe(value/easing/切线)| prop(value/easing)| event(name/payload)。
- 复制:CFrame 关键帧 / 属性关键帧 / 事件标记右键 →「复制」。
- 粘贴:轨道右键(时间轴行右键带 atTime,左列行用播放头时间)→「粘贴 @ t」,
  仅在类型兼容时显示:cframe→camera/cameraMove/transform;prop→property(typeof 与
  该轨已有值不符时拒绝并 warn);event→event。同 t 已有 key 则覆盖(upsert 语义)。
- EditorState 配套:`pasteCFrameKeyframe`(带缓动/切线);`capturePropFrame` 加
  easing 可选参;`addEvent` 加 payload 可选参。
