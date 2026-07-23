# 19 — 事件 payload 编辑 UI 与序列化(T3)

**状态:V1 已实现(2026-07-23)。**

## 问题

契约里 `CutsceneEvent.payload: {[string]: any}?` 一直存在、运行时也整包传给
onEvent handler,但:①无编辑 UI;②**Serializer.event() 落盘时直接丢弃 payload**
(导出即丢数据);③cloneTrack 对 payload 是引用拷贝(undo 快照别名污染)。

## 方案

- **文本格式**:`k=v; k2=v2`。值转型:数字→number,true/false→boolean,其余→string。
  键名 `[%w_]+`。空输入 = 清除 payload。
- UI:事件菱形右键加「编辑 payload…」(InputPrompt,default=现有 payload 反序列化);
  菜单 header 显示 payload 摘要。`EditorState.setEventPayload(track, ev, payload?)`
  整表替换(不原地改,配合 undo)。
- Serializer:event() 输出 payload(仅 string/number/boolean 值;键排序保证稳定 diff;
  其它类型 warn 跳过)。
- cloneTrack:payload 浅拷贝(值全是标量,浅拷贝即隔离)。
- 运行时零改动(EventTrack 已透传)。
