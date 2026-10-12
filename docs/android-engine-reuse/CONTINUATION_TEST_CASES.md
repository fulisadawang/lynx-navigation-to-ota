# 真正 Engine 复用：继续定位的先行用例

2026-10-10；原 Engine 原型和安全解析缓存证据均保留，生产源码暂不切回 Engine cache。

## 公开 API 时序实验

固定原有 EngineReuseStateProbe 字节与 Manifest；使用 SDK 官方 Group(true)、关闭 sharedModule。
Native View 初始化完成、source/client/globalProps 绑定后，连续测试 A→B→C。

| 次序 | 调用 | 观察要求 |
| --- | --- | --- |
| 冷 A | renderTemplateUrl | 真实 Native/UI marker A，counter0/mount1、oldOnly存在；Engine wrapper非零 |
| 实验 B/C | resetData → reloadTemplate → renderTemplateUrl | 同真实Engine对象/指针、新View/Context、正确新Native/UI、counter0/mount1、旧字段消失 |
| 对照 B/C | renderTemplateUrl | 记录原有旧UI问题，不能作为成功 |

Native events须记录全部初次effect回执，不只取第一个正确payload；重复mount必须失败。
最终节点必须正确，不能用回执或frame提交代替新UI。C必须沿用A/B同Engine，排除只B对齐reloadVersion。
实验允许失败，结果不写入正式可用结论；成功还需额外事件顺序、lazy、Native owner、内存回归。

节点观测补充：公开 ID 查询可能找到已脱离 RootUI 的旧节点。并行记录 ID 查询与当前 RootUI children 递归的节点；最终文本仍须严格等于新页面完整标识，且当前树同 ID 只能存在一个节点。不能选择任意匹配预期的旧节点来放行。

## 生命周期事件诊断

另建诊断专用Bundle记录MTS updatePage/firstScreen/hydrate/patch与BTS AppLoad/effect；不能修改node_modules私有flag或改变冻结的正式验收输入。
根因只有取得实际事件/控制对照后才升级为运行态确证。

## 有界的一次 Engine 复用候选（实现前冻结）

保留上面的同 Engine A→B→C 用例与失败结果。新增能力的合同为：每个 Engine 冷加载 A 后，最多借给一个新 View B；B 结束后必须销毁 Group。C 是新的 Engine，C→D 再形成下一对。此限制不能被报告成同 Engine 任意次数复用。

| 用例 | 必须满足的真实结果 |
| --- | --- |
| 10 页 5 对 | 每个 A 的计数真正点到 1；B 的同一非零 Engine、不同 View/Context、当前根树参数 B/counter0/mount1/旧字段清除；下一对 Engine 必须不同 |
| 真实 Lazy | A 不请求独立 Bundle；A lease 关闭后 B 首次点击，由 B 的当前租约交付固定 SHA/size 的真实独立 Bundle，B Native source 与挂载节点正确 |
| 生命周期与预算 | B 关闭后 Group/Engine 释放；active 不被 pressure/OTA 失效提前销毁；idle 数量、TTL、旧 Host 及 PSS 有实际证据 |
| 首次页面业务重载 | A 在同 View 内业务 reload/二次主模板加载后禁止捐赠 Engine；之后 B 必须 fresh。B 的初始化 reload 不与该资格混淆 |
| 候选版本 | candidate_trial 使用原有新 Engine/SDK 首屏与业务健康确认链路，不接收或捐赠未确认的 Engine |
| Page/Tab | 两入口使用同 Factory；warm 的新根树在物理 attach 前完成重建；真实 draw/commit 完成转场，不能伪造 SDK onFirstScreen |
| 监控 | 本次新 View 的初始化 reload 有明确跟踪；warm first_content 记录 cached frame 来源，不能算 cold SDK FCP。后续业务 reload 仍须标为未跟踪的同 View 加载 |
| Native Element | 没有证明可安全脱绑的 Map/Video/业务 Element 禁止持有 idle Engine；保留正常新 Engine 的加载链路 |
| 已移除 Native Element | 当前根已移除的 Native Element 仍可能留在 SDK holder；资格检查必须同时覆盖全部 holder tag，不能仅扫当前根 |
| 首帧前关闭 | draw listener 与 frame commit callback 从原注册 observer 撤销；detach 后 observer 变化不能漏摘，迟到 commit 不触发新页健康 |

实验先在固定 State/Lazy 字节上进行，不能重编输入来掩盖旧问题。若真实 Lazy、宿主或内存有阻断，候选不得宣称可交付。

手动入口补充：Debug 首页真实按钮连续三次打开 Small 原生路由，A/B 必须同 Engine、C 必须新 Engine；按真实 Back 返回首页，每页当前根 READY 和容器健康 generation 均到达。手动 Runtime 固定本测试身份 epoch=0，不能因遗漏 epoch 而一直走普通新 Engine。
