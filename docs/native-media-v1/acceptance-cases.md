# 原生媒体行为验收用例

这些是人工/后续自动化的验收规格，本轮没有新增或运行单元测试。Android按当前minSdk26及新系统验证；iOS按项目声明下限与实际可用设备分开记录。

| ID | 场景/输入 | 应观察的结果 |
| --- | --- | --- |
| MEDIA-01 | NativeMedia单选图片；Cap Camera.chooseFromGallery图片；Shell chooseMedia相册图片 | 三入口调原生选择器，实际后端一致；只返回所选项目；各自结果协议不混用 |
| MEDIA-02 | 仅视频选择，含大小/编码不同的两段视频 | 过滤为video；视频不走Bitmap/图片解码；返回可读URI和真实类型；元信息不虚造 |
| MEDIA-03 | 图片+视频混合多选、limit1/2...16/0默认16；非法mediaType/超限 | 正确MIME筛选和选择数量；非法/超限明确失败，禁止静默删选项 |
| MEDIA-04 | Photos拒绝全库权限后调用系统selected-item picker | 用户仍可选择已授权的单项；不把全库拒权当原生picker不可用 |
| MEDIA-05 | Shell首次调用先于Cap NativeModule惰性构造 | 后续创建Cap Module不替换当前owner，不取消正在选择/上传的任务 |
| MEDIA-06 | 只调用Shell媒体，从未访问Cap Module，随后销毁View | 所有picker/任务按真实Context取消，一次终态；不会因为Module未创建而遗漏清理 |
| MEDIA-07 | 同Activity两个Tab；一个关闭/重载/回滚 | 只取消该View任务，另一个View选择/下载与回调仍正常 |
| MEDIA-08 | 关闭系统选择器、拒绝Camera/Microphone、没相机 | 取消、拒绝、硬件不可用分别返回真实错误，不返回空列表假成功 |
| MEDIA-09 | 选中本地视频打开原生预览，正常关闭/退后台/销毁owner | 原生视频控件和返回可用；暂停/释放正确；回执不冒充完整播放成功 |
| MEDIA-10 | 本地图片预览，iOS不支持格式/Android无handler | 支持时使用原生预览；Android外部查看器窗口归系统；不支持时明确NO_HANDLER等错误，不自动转JS预览 |
| MEDIA-11 | 不可读contentURI、沙盒外路径、符号链接越界、http预览URL | 预览/文件边界拒绝真实非法输入；已选择合法URI可用 |
| MEDIA-12 | Shell旧上传/下载/保存与Cap相关能力同页调用 | 都进入共同有界管线；Shell旧字段兼容；数据回包最多一次 |
| MEDIA-13 | 下载大小未知/超限/取消、目标已有文件 | 流式累计限制；失败删除part并保留原文件，不提交半文件 |
| MEDIA-14 | 并发突发、上传大响应、大Data URL及owner退出 | 固定队列/预算/大内联负载限制生效；拒绝有明确错误；任务/临时文件无残留 |
| MEDIA-15 | 未安装Shell媒体handler的宿主 | 原旧Shell ABI真实失败，不绕回另一套无界backend |
| MEDIA-16 | 当前40域146方法、四transport、旧五媒体方法检查 | 目录和方法名维持；新增JS facade只是既有原生能力消费，不伪造原生注册 |

每项记录平台、系统、App构建、调用入口、真实URI来源、正常/取消终态、截图或录屏及资源释放证据。不得记录真实用户媒体、凭据或签名URL。源码审查、编译、模拟器和物理设备结果分别记录。
