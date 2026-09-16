# LynxCapacitor 三端语义契约 v1.1

本文冻结 Android、iOS、HarmonyOS 三端自有 LynxCapacitorModule 的公共语义。
模块名称只表示页面调用协议兼容，不表示接入上游 Capacitor Runtime、Plugin Registry、
autolink 或 codegen。

## 本次范围

- 以 Android NativeCapabilityCatalog.kt 为事实源，保持 40 个能力域、146 个方法、
  能力域顺序、方法顺序和 rtype: promise 不变。
- iOS LynxNativeCapabilityCatalog.swift 与 HarmonyOS LynxCapacitorCatalog.ets
  必须逐项匹配 Android 目录。
- getPluginHeaders() 不改变返回形状。
- getCapabilityStatus() 增加机器可解析的语义字段，旧的 state、methods 和
  implementedMethods 继续保留。
- 普通 callback、错误 callback、listener 事件和长任务进度使用相同的身份字段；
  retained 事件统一使用 save: true。
- 本分支只收口 Module 源码协议，不把三个 Module 偷接进默认 Shell。

## 能力状态

state 是历史字段，semanticState 是新字段。页面和诊断工具读取新字段，旧页面仍可
读取 state。

| 字段 | 含义 |
| --- | --- |
| native | 目录中所有方法都有源码实现，公共最小语义已经明确 |
| partial | 至少有一个平台语义、宿主配置、系统服务或运行证据仍受限 |
| unsupported | 当前平台没有可以安全承诺的等价实现，调用返回结构化失败 |

一个能力目录项的状态示例：

    {
      "name": "Camera",
      "platform": "android",
      "state": "partial",
      "semanticState": "partial",
      "reasonCode": "DEVICE_FEATURE_REQUIRED",
      "reason": "需要系统权限、设备硬件或系统服务，并且还需要运行验收。",
      "methods": ["checkPermissions", "requestPermissions", "getPhoto"],
      "implementedMethods": ["checkPermissions", "requestPermissions", "getPhoto"],
      "methodStatus": [
        {"name": "checkPermissions", "state": "native", "reasonCode": "NONE"},
        {"name": "requestPermissions", "state": "native", "reasonCode": "NONE"},
        {"name": "getPhoto", "state": "native", "reasonCode": "NONE"}
      ],
      "verification": {
        "source": "verified",
        "build": "not_run",
        "host": "not_integrated",
        "device": "not_run"
      }
    }

reasonCode 是稳定枚举，reason 只用于人读，不应被页面用来分支：

| reasonCode | 使用边界 |
| --- | --- |
| NONE | 源码中的公共最小语义已经实现 |
| METHOD_GAP | 目录声明了方法，但当前平台没有实现 |
| PLATFORM_UNSUPPORTED | 当前平台没有安全等价 API |
| SEMANTIC_VARIANT | 结果、作用范围或完成时机与其他平台有差异 |
| APPROXIMATE_IMPLEMENTATION | 采用平台近似机制，不能承诺硬件或系统完全等价 |
| EXTERNAL_OWNER | 外部系统或第三方应用控制完整生命周期 |
| HOST_INTEGRATION_REQUIRED | 需要宿主注册、窗口协议或生命周期转发 |
| HOST_PROVIDER_REQUIRED | 需要宿主配置或厂商 Provider |
| RUNTIME_CONTEXT_REQUIRED | 需要有效 Activity、页面、窗口或前台上下文 |
| DEVICE_FEATURE_REQUIRED | 需要权限、硬件或系统服务，并需要设备验收 |
| SECURITY_SCOPE_RESTRICTED | 目录、URI、Cookie 等安全边界限制了公共语义 |
| RUNTIME_VERIFICATION_REQUIRED | 源码分支存在，但还没有足够运行证据 |

## 目录和调用闸门

调用进入平台 adapter 前，三端都按以下顺序处理：

1. pluginId 必须是非空字符串；未知能力返回 UNIMPLEMENTED。
2. methodName 必须是非空字符串；能力已知但方法不在目录中返回 UNIMPLEMENTED。
3. 方法在目录中但不在 implementedMethods 中返回 UNSUPPORTED。
4. 只有通过目录闸门后，才允许进入权限、UI、网络、文件、传感器或厂商 Provider。

因此“能力出现在 headers”只代表页面可以发现稳定的方法，不代表该方法已经在设备上
可用。getCapabilityStatus() 和调用错误是两个独立的判断入口。

## 输入、普通返回和错误

请求 payload 必须是 JSON 对象：

    {
      "callbackId": "c-42",
      "pluginId": "Device",
      "methodName": "getInfo",
      "options": {}
    }

- callbackId 缺失或为 null 时统一使用字符串 "-1"；显式传入空字符串或非字符串
  返回 INVALID_ARGUMENT。
- pluginId、methodName 必须是去除首尾空白后仍非空的字符串。
- options 缺失或为 null 时统一视为空对象；显式传入数组、字符串、数字或布尔值
  返回 INVALID_ARGUMENT。
- 普通成功响应包含 callbackId、pluginId、methodName、success: true、data 和
  save: false。
- 普通失败响应包含相同身份字段、success: false、save: false 和
  error.code、error.reasonCode、error.message。

现有业务错误码不删除，只为错误增加稳定的 reasonCode：

| error.code | error.reasonCode |
| --- | --- |
| INVALID_PAYLOAD | INVALID_PAYLOAD |
| INVALID_ARGUMENT | INVALID_ARGUMENT |
| UNIMPLEMENTED | METHOD_GAP |
| UNSUPPORTED | PLATFORM_UNSUPPORTED |
| PERMISSION_NOT_DECLARED | HOST_PERMISSION_CONFIGURATION_REQUIRED |
| PERMISSION_DENIED | RUNTIME_PERMISSION_DENIED |
| MODULE_UNAVAILABLE、SCENE_UNAVAILABLE、HOST_UNAVAILABLE | RUNTIME_CONTEXT_REQUIRED |
| CANCELLED | CANCELLED |
| ACTIVITY_DESTROYED、HOST_DESTROYED | HOST_DESTROYED |
| 其他原生错误 | NATIVE_ERROR |

## 事件、监听和长任务

事件不改变普通调用的身份字段。事件至少包含：

    {
      "callbackId": "listener-1",
      "pluginId": "Motion",
      "methodName": "addListener",
      "eventName": "accel",
      "success": true,
      "data": {},
      "save": true,
      "sequence": 1
    }

- listener 事件使用 listenerId 标识订阅；长任务进度使用 operationId 标识任务。
- callbackId、listenerId、operationId 不互相替代；存在的身份字段必须保持稳定。
- save: true 只用于需要由 Lynx 侧保留的 listener、通知、网络状态或进度事件。
- sequence 是 Module 实例内单调递增的诊断字段，不作为业务排序依据。
- Module、Activity、UIViewController、UIAbility 或 LynxView 销毁后，不能继续向旧
  context 发送事件；取消和销毁要返回明确错误或最终状态。

当前公共目录只声明 Motion 的 addListener、removeListener、removeAllListeners；
Network、通知、App URL、Push 等由宿主事件入口发送的 retained 事件仍使用相同 envelope，
但不会擅自扩展 146 方法的 headers。

## 三端差异的显式表达

以下差异必须通过 reasonCode、methodStatus 或错误字段表达，不能返回假成功：

- Android、iOS、HarmonyOS 的文件目录、URI scheme、Cookie scope 和外部分享回执不同，
  归为 SEMANTIC_VARIANT 或 SECURITY_SCOPE_RESTRICTED。
- Browser.close 由外部浏览器拥有，三端都保留方法但返回 EXTERNAL_OWNER 对应的
  UNSUPPORTED。
- Keyboard.setStyle 不承诺跨端改变系统 IME 样式，返回 PLATFORM_UNSUPPORTED。
- 生物识别、相机、音频、定位、传感器、通知、日历、扫码和无障碍依赖权限、硬件或
  系统账户，状态不能仅凭源码标记为“运行通过”。
- Push register 保留协议入口，但需要宿主注入厂商 Provider、权限和 token；
  BackgroundRunner.dispatchEvent 需要宿主后台能力。
- HarmonyOS 不增加共享元素转场；该能力不属于本契约。

## 验证层级

verification 将证据拆成四层：

| 字段 | 当前分支值 | 说明 |
| --- | --- | --- |
| source | verified | 三端源码、字段和目录已静态核对 |
| build | not_run | 本分支没有未经授权执行 Gradle、Xcode 或 Hvigor 构建 |
| host | not_integrated | 默认 Shell 尚未加入 Module 依赖和注册 |
| device | not_run | 未把源码对齐误报成模拟器或真机能力通过 |

构建图和宿主注册属于后续接入任务，必须在 settings.gradle.kts、Pod/Target、
Harmony build profile、modules Map、权限和生命周期完成后单独验收。

## 维护规则

修改能力域或方法时，必须同时更新：

1. Android catalog（事实源）。
2. iOS/Harmony catalog。
3. semantic-catalog.json 和 verify_lynx_capacitor_semantics.py。
4. 三端状态、错误、事件实现及对应测试。
5. BRIDGE_CONTRACT.md 中的版本说明。

使用仓库脚本执行静态对齐检查：

    python3 scripts/verify_lynx_capacitor_semantics.py
