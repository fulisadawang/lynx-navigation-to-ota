# Harmony 软件对齐验收用例

日期：2026-10-04—2026-10-05。分支：`codex/harmony-native-parity`；基线：`b5d649e`。地图按用户决定延期，高级转场本次包含。最低Harmony API13，目标API24；Lynx4.1.0。

目前共61项。**这是手工验收设计，不是已执行的测试报告，也没有新增自动单元测试。所有用例当前为未执行。** 用户本轮要求先完成源码、暂不编译；未运行类型检查、HAR/App构建、既有测试或设备操作。既有iOS/Android软件报告不能替代本轮Harmony证据。

## 夹具与执行前提

使用模板已有原生诊断、NativeMedia、导航转场页面及其实际Bundle；服务端/下载可复用本地受控fixture，通过宿主现有TEST URL配置接入。手工构造合法清单与坏包仅在临时fixture目录，不覆盖仓库embedded或真实发布包；不在报告写token/Key/用户数据。不同用例记录具体系统/硬件/账户条件，缺硬件只跳对应物理行为，协议/权限/owner/文件/OTA分支不能据此全部跳过。

每项至少记录输入、实际回执、State/current/candidate/manifest变化、Context/lease释放、必要截图或日志。FPS/内存/长稳等性能验收须独立trace，不能由source/count代替。

| ID | 范围 | 场景 | 操作 | 通过条件 | 本轮状态 |
| --- | --- | --- | --- | --- | --- |
| OTA-01 | OTA | 缓存优先 | 给同步接口设置很长延迟，同时已有完整current/embedded，打开Page和NativeTab。 | 直接消费本地已校验内容，不排在整批网络下载之后；有临时校验lease。 | 未执行 |
| OTA-02 | OTA | 候选默认关闭 | 使用未配置candidateActivationEnabled的宿主同步更新。 | 保持原current/previous流程，不改变默认激活模式。 | 未执行 |
| OTA-03 | OTA | PENDING安装 | 启用candidate模式，从稳定A下载完整B主包和Async。 | B为PENDING；current仍A；State可仅有合法候选且旧JSON可读。 | 未执行 |
| OTA-04 | OTA | TRIAL真实消费 | 实际打开B中的bundle。 | main/Async真实校验并取页面lease后才TRIAL；候选坏/缺目标时继续稳定current。 | 未执行 |
| OTA-05 | OTA | 双信号健康 | 分别只发onLoadSuccess、只发JS healthy、只发SDK firstscreen，再补另一信号。 | 前三种不确认；真实首屏与业务信号齐全且来源/epoch/decision/精确版本有效才提交current。 | 未执行 |
| OTA-06 | OTA | 终态与重复 | 重复healthy、确认在途重复、页面关闭/重载后晚到回执。 | 非候选confirmed=false；在途1006，失效来源1002，真实提交失败1003；终态只一次。 | 未执行 |
| OTA-07 | OTA | 启动维护 | 在PENDING和TRIAL分别结束进程，再重新启动；同进程多次prepare。 | 只清旧TRIAL、保留PENDING；同进程合法TRIAL不被多次维护清除。 | 未执行 |
| OTA-08 | OTA | 失败回退 | 候选fatal、稳定首屏fatal、资源warning各触发一次。 | 候选淘汰回稳定；稳定previous/embedded最多一次；warning不整页回滚。 | 未执行 |
| OTA-09 | OTA | 跨会话失败退休 | 同app+release+epoch建立两个导航session；一个稳定包失败。 | 两条失败来源Snapshot均退休，禁止继续新开；活体Page lease与固定Async仍保留。 | 未执行 |
| OTA-10 | OTA | 隐藏恢复 | Page或Tab被覆盖期间失败并恢复，再返回/显示。 | 隐藏不重建；再次可见消费明确pending恢复，不停在空Loading。 | 未执行 |
| OTA-11 | OTA | 身份与修订竞争 | repair/校验/健康提交在途切换身份或最新decision，含跨app来源退休。 | 末端重查epoch/decision/source；关闭晚到lease；十进制修订不丢精度。 | 未执行 |
| OTA-12 | OTA | GC与删除 | candidate/current/previous/snapshot/page/transaction各持引用时prune或delete。 | GC roots保留main和Async；snapshot/page独立；最后消费者释放后才回收。 | 未执行 |
| OTA-13 | OTA | 流式预算 | 本地fixture分别返回20MiB边界、超限与磁盘慢写。 | 接收总量20MiB；实际待写512KiB超限明确失败；等真实writes后关闭fd，失败不激活State。 | 未执行 |
| OTA-14 | OTA | 损坏和撤销 | 缺/坏main或Async、manifest不含bundle、selection撤销与重启。 | 不把目录存在当完整；候选失败继续稳定；撤销与唯一State一致，损坏包不健康确认。 | 未执行 |
| OWNER-01 | 宿主与资源 | 真实Context | 普通Page、NativeTab、旧Shell先调用后惰性Cap创建。 | 同exact Context只有一个Runtime/owner，真实Ability/UIContext/Window，Shell无Cap反向依赖。 | 未执行 |
| OWNER-02 | 宿主与资源 | 晚到Context | 旧generation被销毁后SDK才回onCreate/onPageStarted。 | 拒绝并形成exactContext墓碑；晚到facade不能新建孤儿owner，不误注销新entry。 | 未执行 |
| OWNER-03 | 宿主与资源 | 一次回执 | HTTP/Picker/权限/SQLite进行时关Page并重复destroy。 | 普通pending立即一次ACTIVITY_DESTROYED；queued任务不再开始，真实native工作结束后再释放槽。 | 未执行 |
| OWNER-04 | 宿主与资源 | 前后台UI | 覆盖Page、切Tab、Ability后台与系统Picker往返；隐藏Page旧timer调用close/back/popTo/closeAll/reLaunch。 | 前台getter同时检查Ability和页面；隐藏来源1002、busy优先1006，不关另一前台Page；自有菜单/预览关闭，系统选择器结果不能发布到失效owner。 | 未执行 |
| OWNER-05 | 宿主与资源 | Window多owner | A/B同Window分别保持屏幕常亮/隐私，先关闭或撤销其中一页。 | 不撤销另一页需求，最后owner释放恢复原window baseline。 | 未执行 |
| OWNER-06 | 宿主与资源 | Audio隔离 | A录音/播放，B尝试stop，再关闭A。 | B不能停止A；A销毁只释放所属会话，generation及fd清理保留。 | 未执行 |
| IO-01 | 存储与网络 | 执行池 | 独立IO并发与同store/DB排队混用并超过队列。 | 全局2并发/16等待，同store等待不占IO槽；超限BUSY，无无限排队。 | 未执行 |
| IO-02 | 存储与网络 | FS默认参数 | 省略directory/encoding写读中文文件；mkdir嵌套，显式非法encoding。 | CACHE/UTF8、递归默认true；非法encoding明确失败；字段含created/name/type/size/uri。 | 未执行 |
| IO-03 | 存储与网络 | Base64边界 | 用原始512KiB的N-1/N/N+1文件、HTTP binary及SQLite BLOB。 | 按原始字节预算，Base64膨胀不再收紧到约384KiB；最终2MiB聚合独立拒绝。 | 未执行 |
| IO-04 | 存储与网络 | 原子与URI | 取消文件写/下载并检查旧目标；用含空格的Application Support文件。 | part不覆盖坏原目标，失败清理；标准file URI可回读，沙盒/symlink边界保留。 | 未执行 |
| IO-05 | 存储与网络 | HTTP错误 | 非法JSON、响应超限、超时/网络错误与owner关闭。 | 真实INVALID_RESPONSE/RESPONSE_TOO_LARGE等，不拼接假JSON或吞为成功。 | 未执行 |
| IO-06 | 存储与网络 | Preferences提交 | 未开始前取消和provider put/delete已开始后取消各一次。 | 未开始不变更；已进入提交段完成flush，Bridge仍一次取消；下一owner读值一致；saved/removed准确。 | 未执行 |
| DB-01 | 数据库 | 连接协议 | 先open/query未create，再create/open/close/reopen。 | 未建返回CONNECTION_NOT_FOUND；create真实open后created；close移除connection；公共结果字段一致。 | 未执行 |
| DB-02 | 数据库 | SQL参数与分句 | statement/statements两别名、单句values、多句values、含分号字符串/注释/trigger。 | 别名一致，单句绑定，多句绑定拒绝；不能用简单split破坏合法SQL。 | 未执行 |
| DB-03 | 数据库 | 结果和只读 | BLOB/NULL/Unicode查询，真实INSERT/UPDATE/DDL，readonly写。 | columns与rows分开；BLOB为Base64；真实changes/lastId；native readonly拒绝写。 | 未执行 |
| DB-04 | 数据库 | 并发和销毁 | query/transaction在途close owner，另owner等待同DB。 | ResultSet finally close；真实事务/rollback结束再close与解锁；不抢关句柄。 | 未执行 |
| MEDIA-01 | 媒体与系统UI | 来源与数量 | PHOTOS/CAMERA/PROMPT、0/1/16/非法limit、混合sourceCAMERA。 | 原生选择与菜单；0为16；不静默夹断；取消不是空数组成功。 | 未执行 |
| MEDIA-02 | 媒体与系统UI | 拍摄私有输出 | 前/后摄拍摄，分别saveToGallery false/true/取消保存面板。 | 明确private可写saveUri，核result位置；true实际copy/fsync后saved，不只返回授权URI。 | 未执行 |
| MEDIA-03 | 媒体与系统UI | 音轨与元数据 | 相册视频/录像true/录像false，无扩展名Provider媒体。 | 相册不申请mic；系统录像false明确UNSUPPORTED；真实MIME/metadata，不按文件名假造。 | 未执行 |
| MEDIA-04 | 媒体与系统UI | 原生预览 | 1/16图片、initialIndex、左右滑动/缩放、视频关闭/后台/owner销毁。 | 原生Video/Swiper/Image；只当前邻图采样，像素和本地文件预算；返回表示打开，不声称首帧成功。 | 未执行 |
| MEDIA-05 | 媒体与系统UI | 新旧入口 | 同页依次调用Shell旧choose/upload/download/DataURL与Cap/NativeMedia。 | 同Runtime/backend，旧code/msg/data与新envelope都保持，回执缓存URI可跨owner使用。 | 未执行 |
| UI-01 | 媒体与系统UI | ActionSheet | disabled/destructive/message/cancelLabel，多项、遮罩取消、覆盖/关闭Page。 | 原生可关闭菜单；disabled不可点；选择index/cancelled，取消-1/true；owner清理。 | 未执行 |
| UI-02 | 媒体与系统UI | 真实权限和Provider | 联系人/日历明确不存在ID、定位精确度/timeout、Share多附件、生物认证取消。 | 日历不退首本；参数不丢；附件实际分享；可用性/未登记/权限/取消区分。 | 未执行 |
| LAYOUT-01 | 布局 | 容器相对坐标 | Page/Tab横竖屏、浮窗/分屏、折叠、密度变化、带原生栏的容器。 | Area是window-vp，不二次扣screen原点；真实density；relativeInsets与当前viewport一致。 | 未执行 |
| LAYOUT-02 | 布局 | 键盘与系统导航 | 键盘显示隐藏、导航横条与系统栏变化。 | IME不计安全区重复叠加；初始避让值已读取，动态revision合帧发布。 | 未执行 |
| LAYOUT-03 | 布局 | 返回开关 | 当前Page打开/关闭backGesture、coveredPage/hiddenTab设置。 | 系统返回按当前策略消费；隐藏/非栈顶来源1002；程序关闭仍按原Bridge契约。 | 未执行 |
| TRANS-01 | 高级转场 | push与真实就绪 | Shared/OpenContainer目标Bundle延迟加载，target selector晚出现或缺失。 | 真实首屏/ready/selector门禁；有界timeout与明确fallback；不凭duration timer宣称完成。 | 未执行 |
| TRANS-02 | 高级转场 | native几何和快照 | 多元素、圆角/曲线/交叉淡入、元素不可截图或尺寸超预算。 | 实际id/rect/PixelMap、共同原生progress；像素/数量/字节预算，不能假用缩放替代Open morph。 | 未执行 |
| TRANS-03 | 高级转场 | pop提交与取消 | 手势半途取消、完成、反向/打断、转场时系统返回。 | 唯一nativeproxy；取消恢复栈、source opacity/Context/lease，提交才销毁对应entry。 | 未执行 |
| TRANS-04 | 高级转场 | 迟到与销毁 | 捕获/首屏/Animator在途关页或换身份，连续push/pop。 | 旧transaction拒绝，late PixelMap release，一次终态，无重复动画owner/错误页面释放。 | 未执行 |
| TRANS-05 | 高级转场 | 状态回包 | 各种进行中/取消/完成/fallback时读取getTransitionState并调markTransitionReady。 | 真实transaction/style/progress/reason和当前source门禁，不固定degraded或空ID假完成。 | 未执行 |

| OTA-15 | OTA | 旧新页面Async不漂移 | A旧Page持snapshot/page lease；B候选确认后，A和新B分别lazy同名requestKey。 | 按ownerBundlePath/requestKey/manifest/sourceSnapshot观察：A只读A，B只读B；A main/Async直到其最后lease释放才GC。 | 未执行 |
| OTA-16 | OTA | 同release跨epoch/app隔离 | 健康/Async/repair在途切身份、改decision；同releaseId/SHA用于不同app，再放旧请求。 | 旧source与旧callback不改新State/snapshot；旧lease可幂等close；不同app物理对象与身份选择不串线。 | 未执行 |
| OTA-17 | OTA | Async清单与对象下载 | 分别测Async manifest既有1MiB引用边界、main/Async对象20MiB边界，以及512KiB实际待写队列N-1/N/N+1。 | manifest接收不超过ref.size；main和Async对象都流式；超限/取消清part，等真实writes再close；仅主包成功不足以判整包完整。 | 未执行 |
| OTA-18 | OTA | 原子暂停点恢复 | 对象/Async清单/main清单发布与State提交前后分别受控force-stop，覆盖PENDING与TRIAL健康提交。 | 重启只得完整旧/新组合，State不指向缺main/Async；事务root不提前GC；受控进程恢复与真实断电分开记录。 | 未执行 |
| OWNER-07 | 宿主与资源 | 同标识跨owner/generation | A和TabB用相同callback/listener标识，销毁A、建A2，再放A1旧HTTP/Picker/事件。 | 回包只到所属exact owner/generation；A1一次取消，B/A2不串线；旧cleanup不注销新绑定。 | 未执行 |
| IO-07 | 存储与网络 | UI心跳与真实槽终态 | 真实Module同时大读写/编码/HTTP/DB，采集心跳；占满2+16后第17个任务，并分别取消queued与inflight。 | BUSY明确；queued未开始，inflight真实finally前不释放槽；回执一次且交付线程正确；心跳/trace独立观测，不用Promise存在证明后台。 | 未执行 |
| DB-05 | 数据库 | 绑定数量与只读全边界 | readonly与读写连接各测SELECT/DML/DDL/transaction，参数数量不匹配、NULL/Unicode/BLOB与别名。 | readonly SELECT可读，任何写无变化；非法绑定明确失败；正常alias一致，不吞错误。 | 未执行 |
| DB-06 | 数据库 | 超限/取消后可再访问 | BLOB512KiB与聚合2MiB边界、首行/第64行/超限处close owner，再用第二owner query/transaction。 | ResultSet/rollback/DB serial真实结束，资源可重用；原始预算与编码膨胀分开；不因回执取消提前关句柄。 | 未执行 |
| TRANS-06 | 高级转场 | canonical参数与原生终态 | 发送durationMs/readyTimeoutMs/fallbackStyle等现有wire；ready早/晚到，低进度cancel、高进度/速度commit。 | 参数确实被消费，proxy真commit/cancel唯一修改逻辑栈；取消保Context/lease，onTransitionEnd真实终态，不timer假完成；不叠默认动画。 | 未执行 |
| TRANS-07 | 高级转场 | 重叠共享洞union | 2/3/8元素矩形重叠、相邻、包含、分离，分别push/pop与shuttleOnPush/Pop。 | 独立body layer删除矩形并集，重叠不异或漏源；每元素一次、层级正确；遮罩配对后生成，不缓存无洞中间态。 | 未执行 |
| TRANS-08 | 高级转场 | 8项与64MiB精确预算 | 8/9元素，body+双方element+pending预留累计64MiB N-1/N/N+1，超大/受保护/不可截图内容。 | 只有预算内进入overlay，超限明确fallback/错误；实际字节核账，取消/失败晚到PixelMap恰好release，不绘已释放body。 | 未执行 |
| TRANS-09 | 高级转场 | Tab/窗口变化与多层返回 | 非零window origin/density、Page与Tab混用；转场中旋转/折叠/切Tab/换身份；A-B-C-D执行delta/popTo/clearTop/closeAll。 | vp与pixel只换算一次；几何变化取消/restore；晚到旧事务不关新画布；Tab owner保活；多层只一个真实最终转场，commit才销毁对应entries。 | 未执行 |

| NAV-01 | 高级导航 | preset/透明/多档Sheet | 用wx://upwards、bottomSheet、heroSheet、cupertinoModal各开页，设置56vh、round、hero[28,56,100]和透明底、barrier与垂直拖拽。 | bottomSheet由原生实际控制高度/detents；hero透明全屏由Lynx业务拥有动画且取得配置；不默认横slide/fullPage/white却假接受，导航保持自绘。 | 未执行 |
| NAV-02 | 高级导航 | routeConfig逐项与状态 | 分别关闭canTransition/allowSnapshotting、maintainState=false，设置barrierColor/dismissible/label、fullscreenDrag/popGestureDirection及正反duration。 | 实际Native承载/动画/手势/语义跟参数；不支持明确错误或有理由fallback；恢复/Context/lease按真实终态，不静默丢字段。 | 未执行 |
| NAV-03 | 高级导航 | 真实prepare token | prepareRoute生成有效token和实际bytes/固定版本，再open消费；cancel/过期/身份变更/来源退休/参数不匹配后尝试open。 | 真正准备Bundle与Async或Direct内容，token与source/epoch/route固定，单次消费和有界释放；不得空token/size0假成功或无条件忽略preparedRouteToken。 | 未执行 |
| NAV-04 | 高级导航 | 零动画/命中当前与返回结果 | animated=false、clearTop/singleTask/popTo命中当前；deduplicate开关及0/350/5000/非法窗口；replace首Page回原Tab；busy/cancel时closeWithResult；reLaunch后再消费结果。 | 零时长不做多余截图/错误native默认动画；same-current明确no-op；选项经公开SDK和Module实际消费，非法输入不占去重窗；原返回锚点正确；结果只真commit后一次发布，reLaunch等clear终态，取消无假返回。 | 未执行 |

## 可接受差异

- 真实缺相机/麦克风/传感器/未登记生物识别：记录实际unavailable，不能伪造硬件成功。
- 系统CameraPicker无关闭音轨参数：录像指定false明确UNSUPPORTED，相册/预览不受影响。
- 外部Browser关闭、外部文档无handler、Push厂商/后台JS runner/SQLCipher未配置：保持两端相同边界，不能假接入。
- 系统分享/权限面板由系统管理；owner只保证回执取消和不重新发布UI，实际退出要设备观察。
- SQLite最低系统cursor有界UI读取/64行让出、最终原子rename同步小段需性能trace；不作无卡顿保证。
