# Lynx 三端框架首轮交付收口 Implementation Plan

> **For agentic workers:** 执行时按工作包拆分独立任务，使用 superpowers:subagent-driven-development 或 superpowers:executing-plans 的对应流程；用户当前请求是详细方案，本轮不执行代码修改、Git交付或发布。步骤使用复选框记录未来完成状态。

**Goal:** 让团队从干净检出和标准依赖安装出发，获得同一套三端宿主、合法产物与受验证约束的测试OTA发布链。

**Architecture:** 保持现有手写LynxModule、Native Page Stack、Store v3、公共HTTP/UI/观测包和Server/Admin分工。先收口已实现源码与真实消费包，再修构建/发布语义及门禁；不新建Runtime facade，不启用Sparkling autolink。

**Tech Stack:** 当前仓锁定的Lynx/ReactLynx/Rspeedy、Kotlin/Swift/ArkTS、Node ESM、TypeScript、Fastify/Prisma、Nuxt和pnpm。具体版本以F00输出的锁文件和宿主依赖为准，不在此计划统一升级。

**Spec:** [完整建设路线与验收规格](/Users/nieyutan/Documents/hbc-git/codex/lynx-navigation-to-ota/docs/superpowers/specs/2026-09-08-lynx-framework-roadmap.md)，本计划实现其中M0的F00—F05；其余阶段是后续建设范围。

## Global Constraints

- 默认简体中文；原生Bridge调用不进入Main Thread Script。
- 保留用户dirty/untracked文件，尤其两工作树的Harmony BuildProfile；不得reset/stash/整树格式化。
- Native Page Stack、Direct与OTA身份边界、Store v3/CAS/lease和合法回滚语义保持当前合同。
- 不重新创建getCapabilityStatus，不把旁仓Sparkling fallback当当前Native实现。
- 不读取/记录凭证内容；测试网络用受控fixture和临时数据库，不指向真实业务服务。
- 代码/测试/构建/设备/registry/CI/生产证据分别记录；本计划所有测试预期均尚未执行。
- 提交、推送、合并、正式发包与部署不包含在本次方案编写的执行范围；未来实施按明确任务授权处理。
- 多仓架构/契约变化在正式编码前建立或更新对应OpenSpec并完成严格校验；本轮文档是提案，没有变更现行契约。

## 0. 第一次开工按这个顺序

1. F00：先读取两个已知工作树与正式包/模板仓，形成版本基线和拟交付差异。
2. F01 与 F02 并行：一条线验证Contracts真实包消费，一条线让本地构建没有外部写入。
3. F03 与 F04：对齐三端发行语义和服务端不可绕过的验证门禁。
4. F05：用前面的纯构建与真实tgz合成独立消费、开发verify和发布gate。
5. M0验收通过后才把真实业务接入列为下一执行阶段；不要同时扩展24项任务。

## 1. F00：确定正式源码与集成交付范围

**Files:**
- /Users/nieyutan/Documents/hbc-git/codex/lynx-navigation-to-ota/README.md、PROJECT_MAP.md、MODULE_INTEGRATION.md。
- /Users/nieyutan/Documents/hbc-git/codex/lynx-capacitor-module/android/settings.gradle.kts、android/lynx-shell/build.gradle.kts、android/lynx-shell/src/main/java/com/example/lynxshell/runtime/LynxRuntimeInitializer.kt。
- /Users/nieyutan/Documents/hbc-git/codex/lynx-capacitor-module/ios/LynxShellKit.podspec、ios/LynxShellKit/Native/LynxNativeRuntime.m。
- /Users/nieyutan/Documents/hbc-git/codex/lynx-capacitor-module/harmony/lynx_shell_kit/oh-package.json5、src/main/ets/pages/LynxContainer.ets、LynxTabContainer.ets。
- /Users/nieyutan/Documents/hbc-git/codex/LynxWorkspace/repo-manifest.json、bin/lynx-workspace、scripts/verify-lynx-workspace-shell.mjs、scripts/verify-lynx-workspace-init-plan.mjs。

**Inputs → Outputs:** 两个已知HEAD、现有依赖与角色清单 → 正式交付commit/三端模块组成/包版本/未迁内容/验证命令清单。

- [ ] 读取以下只读信息，保存脱敏版本摘要，不抓取remote凭证。

```bash
git -C /Users/nieyutan/Documents/hbc-git/codex/lynx-navigation-to-ota status --short --branch
git -C /Users/nieyutan/Documents/hbc-git/codex/lynx-capacitor-module status --short --branch
git -C /Users/nieyutan/Documents/hbc-git/codex/lynx-navigation-to-ota worktree list
git -C /Users/nieyutan/Documents/hbc-git/codex/lynx-navigation-to-ota diff --stat 2552b623 171e9801
git -C /Users/nieyutan/Documents/hbc-git/codex/lynx-navigation-to-ota diff --name-status 2552b623 171e9801
```

- [ ] 将差异逐一标成能力实现、依赖注册、销毁、Sample、测试、文档、本机适配；只选择本次正式集成需要的部分，不直接整体合并所有差异。
- [ ] 对普通页与Tab分别列出Module注册/销毁证据；确认正式构建入口都包含能力库。
- [ ] 记录旧LynxSdk/LynxAppTemplate中尚需保留内容和当前合并仓的维护归属；未确认remote不修改下载目标。
- [ ] 更新CLI清单快照的clone/install/sync一致性，并更新对应现有验证。
- [ ] 在选定交付commit干净检出后执行对应三端已有构建与运行smoke；证明Module注册并完成一个真实Native调用。

**失败判据：** 某平台只存在源码但构建不包含Module；普通页有Module而Tab没有；下载与安装仓库集合不同；验证依赖手工修改生成物。
**完成判据：** 正式基线可被其他人干净获取并复现；git交付是否已执行另行记录。

## 2. F01：修复正式Contracts消费组合

**Files:** /Users/nieyutan/Documents/hbc-git/codex/LynxWorkspace/repos/LynxContracts/packages/shared/package.json、.changeset/ota-user-gray-versioncode.md；/Users/nieyutan/Documents/hbc-git/codex/LynxWorkspace/repos/LynxOtaServer/package.json、pnpm-lock.yaml、scripts/verify-persistence-readiness.mjs；/Users/nieyutan/Documents/hbc-git/codex/LynxWorkspace/repos/LynxOtaAdmin/package.json、pnpm-lock.yaml。

**Inputs → Outputs:** revision2源码与现有minor changeset → 新版本tgz和匹配Server/Admin消费lock；正式registry版本在发包后单独验证。

- [ ] 复现当前实际安装包能力，命令不加载环境配置、不开网络。

```python
import json
from pathlib import Path
base = Path('/Users/nieyutan/Documents/hbc-git/codex/LynxWorkspace/repos')
for repo in ('LynxOtaServer', 'LynxOtaAdmin'):
    app = base / repo
    package = app / 'node_modules/@cclx/lynx-ota-contracts'
    declared = json.loads((app / 'package.json').read_text())['dependencies']['@cclx/lynx-ota-contracts']
    installed = json.loads((package / 'package.json').read_text())['version']
    print(repo, declared, installed)
    for filename, symbol in [('dist/index.js', 'matchesVersionCode'), ('dist/index.d.ts', 'LatestQueryContext')]:
        file = package / filename
        print(filename, file.exists(), file.exists() and symbol in file.read_text())
```

- [ ] 在隔离实现环境执行现有版本流程并保留产生的具体新版本；不能覆盖同名0.1.1。
- [ ] 在Contracts根执行已有命令；确认test消费的是新build产物。

```bash
pnpm typecheck
pnpm build
pnpm test
```

- [ ] 在packages/shared对实际产物执行npm pack --ignore-scripts到临时目录；调用现有Server verify-local-contracts脚本前先读其参数约定，复用现有sandbox，不造第二套。
- [ ] 在Server/Admin隔离consumer中用tgz安装；Server执行typecheck/build/test，Admin执行typecheck/build。
- [ ] 正式包可获取后再更新消费版本与锁文件，做frozen lock安装，记录实际解析位置和版本；同时修复readiness中硬编码^0.1.1。

**重要现状：** Admin当前test命令仅打印“No tests yet”，不能将其退出码当作真实测试证据。
**失败判据：** 仍依赖源目录overlay；包有d.ts但缺JS出口；修改manifest但lock解析旧包；只降低包版本却保留调用新API的代码。
**完成判据：** 匹配的新Contracts与consumer组合可标准安装和构建，旧新组合有明确回退记录。

## 3. F02：先校验的纯本地构建与显式发布

**Files:** /Users/nieyutan/Documents/hbc-git/codex/LynxWorkspace/repos/LynxAppPackagesAndTemplates/templates/lynx-template/scripts/build.mjs、write-bundle-list.mjs、verify-build.mjs、publish-release.mjs、package.json。
**新增建议测试文件：** templates/lynx-template/scripts/test/build-release-flow.test.mjs，使用现有Node测试风格或node:test；不得引入新的测试框架。

**Inputs → Outputs:** 当前build编排与环境 → 默认零外部写入的本地构建、显式发布入口、可判定的各阶段结果。

- [ ] 先用子进程fixture模拟各阶段，不真实调用OSS/OTA；记录执行顺序、请求次数和退出码。
- [ ] 覆盖下面矩阵，再改编排；默认构建只能编译/生成本地清单/校验。

| 场景 | 预期 |
|---|---|
| 本地build，环境无凭证 | 编译与本地验证；外部写入0 |
| 本地build，环境已有凭证/本机测试Server | 外部写入仍0 |
| 显式发布，bundle超预算/非法平台 | upload/create/publish全部0，非零退出 |
| upload失败 | 无create/validate/publish，非零退出 |
| validate HTTP成功但validation.valid=false | 无publish，失败原因可见，非零退出 |
| 只完成create/validate | 记录该阶段，不输出已发布 |

- [ ] 调整顺序为build→本地validate→upload→create→服务端validate→显式publish。
- [ ] 保留现有参数含义；将失败是否可忽略与是否执行外部动作分别表达，避免凭证存在改变默认build行为。
- [ ] 输出阶段状态时不打印凭证、完整签名URL和header。
- [ ] 运行新增Node行为测试与原有verify-build/模板测试；只在明确测试发布任务中做外部联合验收。

**完成判据：** fixture矩阵全部满足；本地构建在任意本机配置下可安全重复，外部发布需显式动作。

## 4. F03：Harmony平台与元数据变化回归

**Files:** /Users/nieyutan/Documents/hbc-git/codex/LynxWorkspace/repos/LynxAppPackagesAndTemplates/templates/lynx-template/scripts/write-bundle-list.mjs、publish-release.mjs、verify-build.mjs、README.md，以及相应环境示例。
**新增建议测试文件：** templates/lynx-template/scripts/test/release-payload.test.mjs。

**Inputs → Outputs:** F01正式发行契约、前一个release fixture和新构建 → 对象复用决定 + 发行记录变化决定。两类决定不可再共用hasBundleChanges。

- [ ] 固定下表作为回归；测试通过真实脚本子进程与fixture HTTP服务驱动，读取生成清单与请求次数。

| 旧→新 | 上传对象 | release动作 |
|---|---|---|
| Android/iOS→三端，SHA相同 | 复用，0重复上传 | 必须创建必要的新发行记录 |
| 三端→三端，包/元数据相同 | 复用 | 跳过 |
| 平台相同，一个Bundle SHA变化 | 只上传变化对象 | 新发行记录 |
| 平台相同，required/prefetch改变 | 对象复用 | 按正式契约创建或明确拒绝该改变，不能静默吞掉 |
| harmony-only | 按对象差异决定 | 合法 |
| 空平台/未知平台 | 0上传 | 上传前拒绝 |

- [ ] 在清单/校验/示例/文档统一正式platform值；不复制另一套不一致enum。
- [ ] 将“需要上传字节”和“需要新release”分别计算；清单生成器和发布脚本消费同一判断。
- [ ] 检查latest查询与平台变更含义，避免取到某一平台版本后错误覆盖其他平台要求。
- [ ] 本地fixture通过后，在隔离真实Server执行create/validate流程；结合F04证明发布约束。

**完成判据：** 同SHA新增Harmony的历史回归场景成立；不增加重复下载和上传；原无变化跳过优化保留。

## 5. F04：服务端真实validate和publish强制约束

**Files:** /Users/nieyutan/Documents/hbc-git/codex/LynxWorkspace/repos/LynxOtaServer/src/storage/prisma.ts、src/modules/release/repository.ts、src/modules/release/service.ts、src/app.test.ts；模板publish-release.mjs消费业务校验结果。

**Inputs → Outputs:** release中真实受控对象和发行元数据 → 针对manifest digest的验证记录 → 只有同一digest验证成功才可发布。

- [ ] 复用src/app.test.ts当前validate/publish测试上下文，先增加以下失败测试；已有测试helper保持原函数签名，不根据本计划杜撰API。

| 场景 | 不允许的状态变化 |
|---|---|
| 未validate直接publish | 不能ACTIVE，不能写成功历史 |
| hash有sha256前缀但实际字节不匹配 | validate失败，不能发布 |
| size错误/对象不存在/对象读取超时 | validate失败，保留具体原因 |
| validate成功后替换manifest内容 | 旧结果无效，不能发布 |
| 两个并发请求修改/发布 | 发布必须绑定被验证的准确digest |
| 模板忽略validation.valid强行publish | 服务端仍拒绝 |

- [ ] 在服务层执行受控取流与真实size/hash校验，设置必要的来源、超时和体积约束；不要在长数据库事务中下载。
- [ ] 明确验证记录绑定的digest和失效规则，内存repository与Prisma实现一致。
- [ ] publish最终事务内重新检查验证状态与digest，原子更改ACTIVE/history/revision。
- [ ] 本地内存测试通过后，用临时数据库验证事务与并发；使用专用fixture配置，不读取线上迁移配置。
- [ ] Admin显示真实失败原因与需要重新验证状态；为修改到的UI流程补当前Codex内置浏览器验证。

**已有命令：** Server pnpm typecheck、pnpm build、pnpm test；这些命令的具体数据源和测试runner必须在实际执行前按源码确认。Admin pnpm typecheck、pnpm build；其现有test不是测试套件。
**完成判据：** 所有失败场景不进入ACTIVE；合法发布仍正常；历史稳定发布不受新失败影响。

## 6. F05：合成真实独立消费与发布gate

**Files:** /Users/nieyutan/Documents/hbc-git/codex/LynxWorkspace/repos/LynxAppPackagesAndTemplates/package.json、scripts/verify-package-tarballs.mjs、scripts/verify-release-readiness.mjs、templates/lynx-template/package.json、tsconfig.json。
**新增建议文件：** scripts/verify-standalone-template.mjs，职责仅限临时目录真实tgz消费验收。

**Inputs → Outputs:** 三个公共包实际tgz、F02纯构建 → 独立模板+当前版本检查+统一开发/发布验证。

- [ ] 默认verify串入现有verify:packages；各包test可能已执行build，保留一个有效build位置。
- [ ] 先构建并串行pack三个包到唯一临时目录；复制模板到仓库外，不复制node_modules/真实环境凭据。
- [ ] 在临时副本中把workspace依赖替换为本次tgz，并移除指向源码仓的tsconfig/构建解析路径。
- [ ] 独立安装后执行模板verify和F02的纯test/prod构建；observability以独立fixture检查公共导入。
- [ ] 检查包入口、CSS、d.ts、ReactLynx Use单实例与产物清单；确认没有symlink回源仓。
- [ ] release:check提示改成当前确实存在的release:version；将release检查、测试、pack与消费验证串入正式发布gate。

**已有可复用命令（合并仓根）：**

```bash
pnpm verify:packages
pnpm template:verify
pnpm verify:pack
pnpm release:check
```

**注意：** 当前release:check可能因未消费changeset失败，这应按正式版本流程解决；不删除changeset伪造ready。F02完成前，不把template:build:test/prod当纯本地命令执行。

**完成判据：** 干净目录使用真实tgz可安装/类型检查/构建；坏测试、丢导出/样式、源码链接泄漏均使统一入口失败。

## 7. M0验收记录与后续开工边界

- [ ] 一个正式source commit对应三端宿主依赖/注册/销毁。
- [ ] Contracts正式包与consumer lock匹配，不能依赖overlay。
- [ ] 默认build零外部写入；非法产物零上传。
- [ ] 同SHA新增Harmony不被跳过；完整三端payload通过正式契约。
- [ ] publish无法绕过真实validate或复用过期验证结果。
- [ ] 公共包测试+真实tgz+独立模板构建可复现。
- [ ] 静态、测试、构建、设备、发包、部署记录分层，不将尚未执行层标绿。

完成上述后，下一执行范围优先选择总规格中的A01/A02/A06/A07/A03/A04/A05，形成“现有能力→真实业务”的闭环。监控源码映射可提前做技术验证，但不应抢先建设全量平台。

