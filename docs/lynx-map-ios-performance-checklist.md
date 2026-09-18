# LynxMapKit iOS 性能验收清单

## 采样矩阵

| 场景 | 数据规模 | 操作 | 需要的证据 |
| --- | ---: | --- | --- |
| 普通 Marker | 20/50/100/200 | 创建、No-op、全量替换、局部 1%、burst | `getPerformanceSnapshot` + Animation Hitches |
| 海量点 | 500/1000/5000 | 点数切换、地图缩放、退出重进 | Allocations + RSS/memgraph |
| 网络图标 Marker | 20/50/100 | 首次加载、缓存命中、页面退出 | Allocations + Leaks，确认 operation 取消 |
| 生命周期 | 任意 | 前后台、销毁重建 3 次 | Leaks + 页面重进后的对象基线 |

当前仓库只提供可执行 Demo 和 teardown 代码路径；真机绝对指标必须由连接设备的 Instruments 采样产生。
