# Harmony HAR：Async Bundle 与内置双语文案

代码 Release 可以声明 `asyncBundleManifest`。HAR 用 `x-ota-resource-schema: 1` 请求具备
附属资源能力的 Release；未声明 Async 的 Release 沿用纯主 Bundle 路径。中英文文案由
Bundle 自身携带，宿主只维护 locale 状态，通过 GlobalProps 与切语事件通知页面。

## 本地布局

```text
<filesDir>/lynx-ota-store/apps/<lynxAppId>/
├── state.json                         # 主代码 current/previous，唯一页面激活点
├── manifests/<mainManifestId>.json   # 完整主包及可选 Async 清单引用
├── objects/…/*.lynx.bundle           # 页面主包
└── async-bundles/
    ├── manifests/<sha>.json           # 原始 Async 清单，以声明 SHA 校验
    ├── objects/<sha前两位>/<sha>.bin  # lazy bundle、script、style、asset
    └── transactions/<id>/            # 下载与进程终止恢复索引
```

所有路径受 App ID 隔离。主包与 Async 文件在提交主 `state.json` 前完成 size/SHA 校验，
并通过 fsync 和 rename 发布。主 Store v3 的 current/previous、页面与导航 lease、未完成事务
是 GC 根；Async sidecar 根据这些根保存对应清单和对象。

## 页面消费

Async resolver 绑定页面 owner bundle 和主 Manifest 的清单引用。Provider 按
`ownerBundlePath + requestKey` 精确查找本地对象；首次 lazy 和离线读取不发起下载。
NavigationSnapshot 固定主 Manifest，后续页面在同一 session 内继续使用该版本。页面、Tab 和
Snapshot 关闭时释放主 Manifest lease。

页面准备时完成 Async 对象校验并建立固定请求索引；`requestKey` 有无单个前导 `/` 按同一键
处理。Template Fetcher 只接收 `kind=bundle`，Generic 和 Media 按资源类型分派。Lazy 文件
使用 ArkTS Promise 文件 API 读取并复核 SHA；容器销毁后屏蔽迟到回调。单请求取消按
`LynxResourceRequest` 实例屏蔽回调，实际 Lynx 4.1 取消时是否传同一实例需在 Harmony 设备上核对。
下载前合并主包与缺失 Async 对象体积进行容量预检，清单上限 1 MB、单资源上限 20 MB。

`ShellGlobalPropsFactory` 在首帧注入宿主 `locale`、`language`、`appLocale`、`__lynxShellLocale` 等状态。
`locale/effectiveLocale` 表示实际语言；`appLocale/appLocaleOverride` 仅表示可空的用户覆盖值。
`ShellMessageHub` 在语言切换后更新存活页面的 GlobalProps，并发送
`lynxShellLocaleChanged`；Bundle 内的文案由页面根据新 locale 切换。

旧 `i18nRequirement` Release 与本地 Manifest 解析时拒绝加载。当前 TEST 联调使用新的双语
Bundle 与受控重装；这里不提供旧词典页面的升级读取。

## 验证边界

- `python3 harmony/scripts/check_harmony_shell.py --quiet`
- 在 `harmony` 目录执行 `assembleHar --mode module -p module=lynx_shell_kit@default --no-daemon`

静态检查与 HAR 编译不能替代 Harmony 模拟器或真机的首屏、切语、lazy、离线及回滚验收。
Entry Demo 增加 `10020000/OtaEcommercePage.lynx.bundle` 的 OTA 页面入口；它依赖已发布并
下载的 Harmony Release，不代表 HAP 随包具备电商 Async 离线基线。`BuildProfile.ets`、
依赖版本与生产部署未改。本轮按要求只做源码实现和静态复核，未运行上述静态门禁、编译、
启动或设备验收。
