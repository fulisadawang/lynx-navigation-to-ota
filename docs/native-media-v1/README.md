# Android / iOS 原生媒体统一

状态：双端与公共包源码及专项复审完成；用户随后授权本地演示，Android API36 / iOS18.1已编译安装启动，模板入口与实际媒体回包已观察。完整用例、硬件/编码与性能不因演示通过而全部验收。

## 用户确定的行为

- 图片、视频选择使用系统/原生选择器，通过 NativeModule Bridge 调用。
- 视频预览使用原生播放器；不增加 Lynx 自绘播放器页面。
- 图片列表使用 iOS Quick Look 多项或 Android 宿主内 ImagePreviewActivity，支持起始索引和左右切换；不使用 JS 图片预览。
- Shell 的五个旧媒体接口保留名称和返回 ABI，与 Cap 的重叠能力共用媒体后端。
- Harmony 暂缓；不升级 SDK 或引入第三方媒体依赖。

## 分层

Shell 只拥有公开的媒体接线入口，业务 App 将它连到独立能力模块；Shell 不反向依赖 Cap。两套公开协议保留：Shell code/msg/data，Cap callbackId/pluginId/methodName/success/save。共用的是实际选择、文件/网络操作和页面 owner，不让两套 envelope 嵌套。

以真实 LynxContext 为页面身份。Shell 先调用、Cap Module 后惰性创建时，复用同一 owner；View 销毁时，即使 Cap Module 没被构造，也能取消该 owner 的媒体任务。Activity 不是多个 Tab 的共同 owner。

## 已接线的原生能力

| 行为 | Android | iOS |
| --- | --- | --- |
| 选图片/视频/混合 | 系统 Photo Picker；低版本系统文档选择器 | PHPickerViewController |
| 拍摄 | 既有原生 CameraX/录像 Activity | 系统 UIImagePickerController |
| 本地视频预览 | 既有 VideoView + MediaController 原生 Activity | AVPlayerViewController 原生控件 |
| 本地图片列表预览 | 宿主内 ImagePreviewActivity，慢拖/快划切换与缩放 | Quick Look 多项及 currentPreviewItemIndex |

单次选择最多 16 项：direct Camera 的 limit 允许 0...16，其中 0 使用默认多选上限 16；Shell 旧 count/maxCount 允许 1...16。非法和超限数量明确失败，低版本系统选择器回包也再次校验，不裁切返回列表。

系统选择器只访问用户明确选择的项目，不为打开选择器强制请求全库照片权限。拍照/录制仍按实际 Camera/Microphone 权限与宿主用途文案处理。

预览仅接受系统选择或 App 允许目录内的本地 URI/文件；网络资源先通过下载能力获取受控本地资源。NativeMedia 单图/多图均由原生 owner 管理，销毁时关闭；旧 FileViewer 单文档参数仍在 Android 使用外部 ACTION_VIEW，由系统管理其他应用的窗口。返回预览回执表示界面展示或发起播放，不表示文件已经完整播放或所有编码都支持。

## 旧接口的兼容约束

保留 chooseMedia、uploadFile、uploadImage、downloadFile、saveDataURL。方法名/selector和原 code=0,msg=ok,data 成功、code=-1,msg 错误保持；旧 tempFiles 等字段按真实媒体结果转换，不制造不存在的绝对路径。

默认 Sample 同时安装 Cap 和 Shell 媒体接线。单独安装 Shell 的正式宿主也必须安装公开媒体 handler；缺接线返回真实失败，不再回退到无 owner 的旧媒体实现。

旧 Shell 选择结果仍将实际内容以有界流式方式落到缓存，保留真实 tempFileAbsolutePath；成功交付文件不因源 View 销毁而删除，可通过页面返回结果交给其他页。新版 Cap 相册选择在 Android 直接返回选定 URI，不为兼容旧字段默认复制视频。

上传、下载按页面绑定任务、流式处理文件并限制并发、输入/响应/结果预算；销毁、取消、队列拒绝和自然完成共用一次终态。Data URL 与文件 URI 是不同负载路径，大 Data URL 需独立输入和在途内存预算。

## 宿主接线

Android 在安装 Cap Runtime 与 NativeModule 的组合根调用 `LynxShell.installNativeMediaHost`。媒体 host 的 `call` 转交 `LynxCapacitorRuntime.handleLegacyMedia`，`onViewDestroy` 转交 `destroyForContext`；Shell 容器的全部 View 销毁出口先执行这个中性 hook，再进入 SDK destroy。

iOS 在 bootstrap 前调用 `LynxRouter.installMediaHandler`，闭包转交 `LynxCapacitorModule.handleLegacyMedia(for:method:optionsJSON:callback:)`；继续注册 `onViewDestroy: LynxCapacitorModule.destroy(for:)`。无 Cap Module 实例的 legacy runtime 同样在此 hook 中释放。

两个默认 Sample 已写入这套源码接线，Core 不反向 import/depend 能力模块。公共包调用见 `LynxAppPackagesAndTemplates/packages/lynx-native-bridge/docs/native-media.md`，模板直接导入同一公共包，没有复制另一套 native helper。

相册与预览不需要麦克风。Android 自有录像支持显式 includeMicrophone=false 静音、true 要求录音授权，缺省沿历史授权行为；iOS 系统录像不支持关闭音轨，显式 false 会返回 UNSUPPORTED。

## 大小预算与平台差异

iOS系统picker提供的临时文件需要在有效窗口复制到App缓存，当前沿用20MiB的媒体物化上限；较大选择会明确MEDIA_TOO_LARGE。Android新版Cap图库只返回授权URI，已知大小可提供、未知省略，不为大小扫描全流，也不应用20MiB选择门禁。旧Shell缓存副本、上传/下载、DataURL及Android录像仍保留20MiB预算。

## 验证

验收场景见 acceptance-cases.md。本轮只读源码/协议和最终 diff 审查不能替代编译、模块注册、权限、真实选择器、编码播放或性能验收。六项旧报告是此改动前的历史软件证据，不把它扩大为新媒体实现已运行通过。

最新来源参数、拍摄入口与图片列表预览已重新构建并安装；Android/iOS 新 Demo 可见，iOS 原生来源菜单已实际显示。实际拍摄、左右滑动、权限失败及性能未完整验收；M01...M15待执行用例见 implementation-report.md。
