# 原生媒体统一交付与演示报告

日期：2026-10-04。当前状态：专项源码复核完成，最终 Android/iOS 宿主与模板 Bundle 已重新构建、安装并显示 Demo；iOS 原生来源菜单已显示。实际拍摄、多图手势、M01...M15及性能仍待完整验收。

## 结果

- NativeMedia.selectImages/selectVideos/selectMedia：调用现有Cap Camera，系统原生选择器；单选默认1，多选最多16，0映射默认16，非法/超限明确拒绝。
- NativeMedia.previewVideo：Android原生VideoView/MediaController、iOS普通AVPlayerViewController，保留实际平台回执。
- NativeMedia.previewImage/previewImages：iOS Quick Look 多项、Android 宿主内 ImagePreviewActivity；支持本地列表/起始索引和左右切换，不使用 JS 自绘预览。
- Shell五个旧媒体ABI均保留；原实现替换为媒体SPI适配，默认Sample连接Cap同一View的后端/owner。两种回包协议继续独立。
- 注册与销毁支持Shell先调用、Cap后惰性创建，以及始终没有Cap Module实例的View。Android四个Activity+两个Tab View销毁出口均先过媒体hook；iOS原destroy hook释放共享runtime。
- 上传/下载/DataURL共用有界执行与资源归属；流式处理、一次终态、取消/失败清part、成功缓存路径跨页保留。

## 审查修复

iOS：大DataURL切片/解码/原子写全在同一后台IO任务；图库数量严格限制；原mixed camera保留；普通AVPlayerVC组合避免子类；Library目录/usage unsupported顺序对齐。

Android：尊重实际mic三态；新版图库URI不为未知size扫描整流/20MiB误限制；native video准备成功回执一次、后台暂停与此前播放恢复分开；旧picker required门禁与宿主接线说明已更新。

Lynx/package：background-only、固定媒体filter、异步安全整数检查、导出/声明图、原生字段原样保留；默认16与路径范围统一。

三位审查者最终在限定源码范围内均未报告剩余必修项。后续构建/显示证据另列；源码审查不是 codec、权限、性能或物理设备通过。

## 验证证据

- 双端git diff --check通过。
- 有界源结构检查：40域146方法一致；旧Shell五方法保留；Android真实6处View销毁接线；旧无界Shell网络代码已移除；新package export/相对声明引用存在。
- 仓库既有全量静态门禁含Swift parse，本轮未执行；仅修正其已失效的required源文件清单。
- 初版源码审查阶段没有编译/运行；后续已授权重新构建宿主、公共包和 Bundle，模板 typecheck 通过并安装启动。媒体 M01...M15尚未完整执行，未新增单元测试或发布 npm。
- 上轮六项软件报告及旧产物是媒体改造前证据，不能代表这次媒体源码已运行。

## 实际边界

NativeMedia 图片预览在双端 App 内受 owner 管理；旧 FileViewer 单文档入口的 Android 外部窗口仍归系统。网络媒体先下载到可访问本地位置再预览。iOS图库临时文件物化预算仍20MiB，Android新URI图库不受该选择预算；旧缓存复制/传输/DataURL/Android录像保留20MiB。麦克风字段与平台差异见README/公共包文档。

正式宿主需在首次View前安装媒体SPI；仅Shell且未安装handler的旧调用明确失败。Harmony继续延期，OTA Server主包发布门禁本次未实施。

验收场景见acceptance-cases.md；公共包文档见LynxAppPackagesAndTemplates/packages/lynx-native-bridge/docs/native-media.md。


## 2026-10-04：本地演示运行补充

用户随后授权启动双端。Android API36新Debug APK与iOS18.1 CoreE2EHost均已实际编译、安装、启动；bridge构建、模板typecheck及本地3主Bundle/3Async构建通过。首页新增原生媒体演示，双端已观察到演示页面和实际选择回包。原生UI使用系统picker/已有播放器和查看器，没有JS自绘预览。

本次是受控演示观察，不是16项用例全验收、全硬件/编码或性能结论。iOS Simulator target不链接地图，临时deployment15；Android演示用本机Direct Bundle避免旧OTA首页缓存影响，未处理额外发布链任务。未新增单元测试、未push或上传远端。详情见 .workflow/native-media-demo/run-report.md 和 run-summary.json。


## 2026-10-04：原生来源与图片列表扩展（实现与构建阶段）

本轮补齐Android/iOS原生来源参数、直接拍摄和图片列表预览。NativeMedia.selectImages/selectVideos/selectMedia接受source:PHOTOS/CAMERA/PROMPT；takePhoto/recordVideo直接固定拍摄来源，无需业务使用原生Bottom Sheet。纯类型CAMERA直接拍摄，mixed CAMERA仅选拍照/录像，PROMPT提供相册及相应拍摄选项。支持前后摄、保存相册、录像音轨（iOS显式静音不支持）和五个菜单文案。

新FileViewer图片列表参数items与initialIndex沿现有方法；NativeMedia.previewImages接受images与initialIndex。1...16张本地图片，URI/path至少一项，同时提供优先URI；顶层列表与单文件参数互斥。Android内置原生Activity左右切换/双指缩放/双击复位，后台只采样当前图，像素约4M上限，JPEG EXIF矩阵处理，代次丢弃过期解码；列表提前检查真实图片头但不分配整组像素。iOS后台ImageIO验证后Quick Look多项/currentPreviewItemIndex。GIF等动画在Android当前仅显示首帧，未加入动画解码器。

相册选择不会预先申请相机/麦克风权限；现代chooseFromGallery相册选择不重复保存。旧getPhoto/pickImages显式saveToGallery语义仍保留，旧Shell五个ABI与各自envelope保留。所有新增原生界面使用原调用Lynx owner；页面销毁时关闭界面/取消IO/结束调用，不让旧页面继续接收结果。

公共包声明、具名facade、根导出、模板演示按钮及文档已同步。不升级依赖，不增加40域/146方法目录或四transport。Harmony仍不补齐。Lynx有界静态审查已通过；iOS专项发现并修复异步呈现误借其他前台Scene的问题，复核已闭合；Android专项发现并修复API26...28保存相册写权限和原始Camera方向参数校验问题，定向复核已闭合；随后Lynx专项再次核对契约/线程通过。后续已重新编译最终源码、生成本地 Bundle/安装包并安装，Demo 新入口与 iOS 来源菜单已显示；这不能作为实际拍摄、多图手势或完整媒体验收的证明。

### 新增能力验收用例（待执行）

| 用例 | 操作 | 预期 | 当前证据 |
|---|---|---|---|
| M01 | PHOTOS图片/视频/mixed | 对应系统picker；不弹相机/麦克风权限 | 源码复核 |
| M02 | CAMERA图片/视频，FRONT/BACK | 直接原生拍摄；结果平台列表单项，类型/位置正确 | 源码复核，iOS需真机 |
| M03 | PROMPT三类、CAMERA mixed | 正确来源项；文案参数生效；菜单结束后再进picker | 源码复核，界面待验证 |
| M04 | 原生菜单取消/外部关闭 | CANCELLED一次，无BUSY残留，再次调用可用 | 源码复核 |
| M05 | 拍摄拒绝权限/无相机 | PERMISSION_DENIED/HARDWARE_UNAVAILABLE；不返回相册或假成功 | 源码复核，硬件待验证 |
| M06 | iOS includeMicrophone:false，PROMPT后选相册/录像 | 相册正常；只有选录像才UNSUPPORTED | 源码复核 |
| M07 | CAMERA saveToGallery:true/false；PHOTOS modern；旧getPhoto显式保存 | 拍摄按选项保存；modern相册不重复保存；旧语义保留 | 源码复核 |
| M08 | 3图initialIndex:1，慢拖/快划切换，URI/path双字段 | 首屏第二张，顺序一致，URI优先；Android缩放可复位 | 源码复核，实际手势待验证 |
| M09 | 空/17图/非法索引/视频/PDF/伪图片/远端URL | 明确错误，无opened假回执 | 源码复核 |
| M10 | 快速切图/旋转/关闭源Lynx页 | 旧解码不覆盖当前图，owner关闭，资源释放，无旧页回包 | 源码复核，运行态待验证 |
| M11 | 旧Shell相册/拍照/录像 | 继续原code/msg/data和真实文件位置；Cap对照同后端 | 源码复核，新增拍摄待验证 |
| M12 | 高像素/JPEG方向/GIF/多个预览并发 | 采样与EXIF正确，GIF首帧，BUSY明确；内存峰值/泄漏需实测 | 源码复核，性能待测 |
| M13 | 权限申请/图片校验期间切换Tab/替换原容器/原Scene退出前台 | 重新验证原presenter自身窗口；SCENE_UNAVAILABLE或owner销毁错误，不借其他窗口、不回opened假成功 | iOS专项源码复核通过，运行态待验证 |
| M14 | Android API26/28保存相册true/false、允许/拒绝写权限，API29+对照 | 仅旧系统拍摄且需保存时申请WRITE；拒绝不启动拍摄；保存成功一项且无空残留 | Android专项源码复核通过，实际MediaStore待验证 |
| M15 | 两端原始Camera与NativeMedia传合法/非法cameraDirection | FRONT/BACK执行；字符串非法值、数字、null在权限/UI前INVALID_ARGUMENT | 双端源码和专项复核通过，硬件方向待验证 |


## 最终新增 Demo 构建与显示证据

Android API36：`:app:assembleDebug`成功，覆盖安装到emulator-5554；APK SHA-256为`0d21e956f069d63f0fd59a664ad8e5a132e9a4b054b2cf93a5465805851fdcfd`。iOS18.1：LynxShellE2EHost编译安装成功，临时deployment15、未链接地图。公共bridge构建、模板typecheck与3主Bundle/3Async本地构建通过；NativeMediaPage大小145198B，SHA-256为`f0442bc98ccb0c532fa4f6fc4a5e87c34d11c5557d457d6dbd6b9ba5f4f7b07b`。

两端已实际显示新增按钮；iOS已打开原生来源菜单（从相册选择/立即拍照/取消）。Android采用本地Direct最新Bundle，iOS从模板首页进入。当前证据不包含实际拍摄成功、多图滑动、完整M01...M15、API26写权限、物理设备或FPS/内存验收；日志与产物保留本地`.workflow/native-media-completion/demo/`，不提交设备/构建产物。
