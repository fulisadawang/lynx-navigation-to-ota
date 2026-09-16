# Android G1 快照摘要

来源：`46-full-snapshot-logcat.txt`，由 Debug Sample 验收页“把当前快照写入 logcat”生成；事件 JSON 只来自本地 `DiagnosticProvider`。

- 事件总数：45
- Provider：`local_diagnostic`
- Monitor 状态：`ready`
- 队列：`0` 条 / `0` bytes（快照时已排空）
- 本地淘汰：`0`

## 事件数量

| 类型 | 容器 | 数量 |
| --- | --- | ---: |
| `lynx.performance` | `page` | 2 |
| `lynx.performance` | `tab` | 2 |
| `view.lifecycle` | `page` | 8 |
| `view.lifecycle` | `tab` | 10 |
| `view.load` | `page` | 8 |
| `view.load` | `tab` | 15 |

## Bundle 身份

| 容器 | viewId 前缀 | loadId 前缀 | Bundle | release | sequence | SHA 前缀 | 状态 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `page` | `b87f1011` | `17bec687` | `main.lynx.bundle` | `r20260901_0f1ter` | `11` | `a40e5141a39f` | `verified` |
| `page` | `b70023b8` | `447dcaff` | `video-demo.lynx.bundle` | `none` | `none` | `f92ea0ce3b6d` | `computed` |
| `tab` | `fc702669` | `f168ab1c` | `main.lynx.bundle` | `none` | `none` | `62c8b731f160` | `computed` |
| `tab` | `95b8d96e` | `0a8fd429` | `main.lynx.bundle` | `none` | `none` | `62c8b731f160` | `computed` |
| `tab` | `bb4e4c81` | `c2624976` | `main.lynx.bundle` | `none` | `none` | `62c8b731f160` | `computed` |
| `tab` | `420f0529` | `43c87216` | `main.lynx.bundle` | `none` | `none` | `62c8b731f160` | `computed` |

## Load 与生命周期序列

- `page`：`started → visible → resolved → created → loaded_unconfirmed → first_content → hidden → destroyed → started → created → resolved → visible → loaded_unconfirmed → first_content → hidden → destroyed`
- `tab`：`started → started → visible → created → resolved → created → resolved → loaded_unconfirmed → first_content → loaded_unconfirmed → first_content → destroyed → started → destroyed → started → created → resolved → created → resolved → first_content → loaded_unconfirmed → first_content → hidden → destroyed → destroyed`

## 性能指标

- `page` / `loadBundle`：
  - `mts_render_ms` = `97.943115234375` ms
  - `style_resolve_ms` = `202.904052734375` ms
  - `layout_ms` = `284.0009765625` ms
  - `paint_ui_ops_ms` = `92.4638671875` ms
  - `pipeline_ms` = `789.43505859375` ms
  - `lynx_fcp_ms` = `789.435` ms
  - `prepare_to_fcp_ms` = `804.858` ms
  - `parse_ms` = `4.3818359375` ms
  - `bts_load_ms` = `104.1171875` ms
- `page` / `loadBundle`：
  - `mts_render_ms` = `2.93505859375` ms
  - `style_resolve_ms` = `3.759033203125` ms
  - `layout_ms` = `5.641845703125` ms
  - `paint_ui_ops_ms` = `95.375` ms
  - `pipeline_ms` = `127.357177734375` ms
  - `lynx_fcp_ms` = `127.357` ms
  - `prepare_to_fcp_ms` = `164.638` ms
  - `parse_ms` = `1.739013671875` ms
  - `bts_load_ms` = `14.22607421875` ms
- `tab` / `loadBundle`：
  - `mts_render_ms` = `11.1748046875` ms
  - `style_resolve_ms` = `18.02099609375` ms
  - `layout_ms` = `14.348876953125` ms
  - `paint_ui_ops_ms` = `4.848876953125` ms
  - `pipeline_ms` = `58.080078125` ms
  - `lynx_fcp_ms` = `58.08` ms
  - `prepare_to_fcp_ms` = `76.218` ms
  - `parse_ms` = `1.69580078125` ms
  - `bts_load_ms` = `10.491943359375` ms
- `tab` / `loadBundle`：
  - `mts_render_ms` = `5.257080078125` ms
  - `style_resolve_ms` = `23.416015625` ms
  - `layout_ms` = `10.0478515625` ms
  - `paint_ui_ops_ms` = `3.5859375` ms
  - `pipeline_ms` = `64.921875` ms
  - `lynx_fcp_ms` = `64.922` ms
  - `prepare_to_fcp_ms` = `92.698` ms
  - `parse_ms` = `2.7919921875` ms
  - `bts_load_ms` = `18.661865234375` ms

## 未在本轮真实回调中观察到

- `lynx.resource`：`video-demo` 本地页面完成首屏，当前 Lynx 4.1 Android SDK 回调链没有产生可观察的 `onResourceLoaded` 事件；资源契约由 JVM 测试覆盖。
- `lynx.js_error`：现有官方/Playground Bundle 没有稳定可复现的 JS 异常入口；错误 JSON、脱敏、调试 key 和大 JSON 不截断由 JVM 契约测试覆盖。
