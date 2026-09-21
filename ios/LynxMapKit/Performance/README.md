# LynxMapKit iOS 性能与泄漏验收

`LynxMapKit` 将普通 `Marker`、Polyline 和 `MAMultiPointOverlay` 分开计量。`getPerformanceSnapshot` 只报告主线程 native apply 的快照，不把 JS 提交时间、地图网络加载时间或模拟器 FPS 当成绝对性能结论。

## 可重复场景

1. `map-performance.lynx.bundle`：普通 Marker 20/50/100/200，首次创建、No-op、全量替换、全量移动、局部 1% 和 10 次 burst。
2. `map-mass-points-demo.lynx.bundle`：`MAMultiPointOverlay` 500/1000/5000 点，反复切换点数并退出重进。
3. 每轮都记录 Bundle SHA、设备型号、iOS 版本、AMap SDK 版本、点数、操作类型和是否刚从后台恢复。

## 真机 Instruments

使用签名后的 Debug 包安装到目标真机，关闭 Xcode 的自动 UI 录制，只保留一条可复现操作路径。

```bash
xcrun xctrace record \
  --device <UDID> \
  --template 'Animation Hitches' \
  --launch -- ./build/LynxShell.app

xcrun xctrace record \
  --device <UDID> \
  --template 'Allocations' \
  --launch -- ./build/LynxShell.app

xcrun xctrace record \
  --device <UDID> \
  --template 'Leaks' \
  --launch -- ./build/LynxShell.app
```

每个模板至少完成：打开地图 → 5000 点 → 500 点 → 5000 点 → 退出页面 → 重进三次。保存 `.trace`，不要只保存截图。Animation Hitches 用于卡顿分布；Allocations 用于峰值和释放后基线；Leaks 用于系统泄漏扫描。`MAMultiPointOverlay` 的纹理渲染不受 renderer alpha 影响，不能用透明度变化代替释放验证。

## memgraph 与边界

在页面退出并等待一个 run loop 后抓取进程 memgraph，和进入页面前的基线对比。重点检查 `MAMapView`、`MAMultiPointOverlay`、`MAMultiPointItem`、`MAMultiPointOverlayRenderer`、`LynxMapUI` 和 `SDWebImage` operation 是否仍被 app-owned 对象引用。

```bash
leaks <PID> -s 0
vmmap <PID> > /tmp/lynx-map-vmmap.txt
```

当前代码的释放顺序是：取消 provider 异步任务 → 移除 delegate/listener → 移除 annotation/overlay → 取消网络图片 operation → 关闭 `renderringDisabled` → 移除 MapView。`MAMultiPointOverlay` 的点属性不可动态更新，因此数据指纹变化会整体移除旧 overlay 后再创建新 overlay；指纹不变则复用，避免每次 Lynx props 更新都堆积对象。

## 证据填写规则

- 模拟器只能作为编译、启动、地图 ready、能力快照和相对回归证据。
- 没有 `.trace`、设备型号和采样时间，`FPS`、hitch、RSS、峰值内存和泄漏结论必须保持 `NOT_MEASURED`。
- `getPerformanceSnapshot.fps` 与 `frameTimeMs` 在没有 CADisplayLink/Instruments 采样时返回 `null`，页面上的 `NOT_MEASURED` 不得改成伪造数字。
- 真机未连接时不宣称“无泄漏”；只能说明代码路径具备显式 teardown 和可执行验收步骤。
