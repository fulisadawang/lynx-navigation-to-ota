# AGENTS.md — iOS `LynxMapKit`

`LynxMapKit` 是独立的地图能力 CocoaPods Module。它拥有 `lynx-map` Native Element、AMap
Provider、Search、Location、地图生命周期和性能边界；不依赖 `LynxShellKit`，不反向 import
Shell Runtime。

Shell 只通过 `LynxMapModuleRuntime` 完成：

- AMap Key 和隐私同意状态注入；
- Search/Location NativeModule 注册；
- `lynx-map` UI 注册。

地图页面不能通过 props 注入 Key。NativeModule 回调只能返回 JSON 可序列化值；高德活体对象、
UIKit View 和 MapView 不得越过 Module 边界。

修改后至少验证：

```bash
cd ios
pod install
xcodebuild -workspace LynxShell.xcworkspace -scheme LynxShell \
  -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
```

运行地图页面时还需要用宿主构建变量注入 `LYNX_AMAP_API_KEY`；不要把 KMP `AMAP_APPKEY`
复制到仓库文件或 Bundle。真机/模拟器的地图 ready 与 Key/隐私配置是两条独立验收证据。
