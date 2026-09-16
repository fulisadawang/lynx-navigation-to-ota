# 构建归档、可插拔上传与 JS 源码还原契约 v1.0

本文件描述构建工具与适配器契约。当前分支已实现 archive 模式、manifest 校验和离线 resolve；provider 模式仍由 G2 选定厂商后实现。

## 1. 基线与关键决定

正式基座 main@e9ff9ee 的 Playground 锁定 Rspeedy 0.17.0、React 插件 0.20.0、DebugMetadata 插件 0.2.3。必须用正式分支 lockfile 复现构建，不能以遗留 node_modules 判断版本。

采用官方“按 runtime release/key 索引”的路径。首版不改写 Bundle 的 debugMetadataUrl/templateDebugUrl，也不把私有源码材料部署到业务 Bundle CDN。

正式文档中：每个 entry 的 `debug-metadata.json` 包含 artifacts、source maps、bytecode debug info、UI source map、build info。生产构建最终会删除它。需要在 `Compilation.PROCESS_ASSETS_STAGE_REPORT` 阶段捕获，早于官方 REPORT+1 清理。

捕获调试文件只完成第一步：最终 Bundle 可能还在编译/写入，因此最终哈希、大小和配对清单必须在该构建的最终产物确定后生成，不在 beforeEncode 中猜最终 SHA。

## 2. 可复现构建与归档流程

```text
读取冻结 lockfile / engine 配置
    → 确认 JS source-map 与主线程 bytecode debug info 配置
    → production build 的 REPORT 阶段捕获每个 entry 的 DebugMetadata
    → 构建成功，读取本轮最终 .lynx.bundle
    → 计算 Bundle SHA 和 DebugMetadata SHA
    → 校验每个 entry、脚本、映射 key 及字节码信息
    → 原子完成私有归档目录及 manifest.json
    → archive 模式：保留 CI artifact
    → provider 模式：调用选定上传适配器并检查回执
```

执行约束：

- 显式使用当前 Rspeedy 支持的高质量 JS source-map 配置；R0 验证真实 artifact 内存在 map，不只检查开关文本。
- 每次构建使用独立临时捕获目录和 buildId，禁止上次构建残留材料混进本轮。
- 归档存放在 dist/外，例如 `.artifacts/lynx-monitor/<buildId>/`；生产 Bundle 同步/上传脚本不得递归带入它。
- 每个 entry 保留同次构建的 metadata；懒加载独立 Bundle、独立 chunk 各自纳入清单并建立映射。
- 保留原始 DebugMetadata 内容及哈希。公开清单只暴露必要身份，源码材料受控保存。
- 代码 commit 只描述源码版本，不能代替 Bundle 哈希。存在 dirty 源码的本地构建显式标识，不得声称 commit 能唯一恢复本地源码。
- buildId 是一次构建的标识，不强行写入 SDK 的 runtimeRelease，也不假冒官方 source-map key。

## 3. 归档目录与 Manifest

建议布局（研发约定）：

```text
.artifacts/lynx-monitor/<buildId>/
  manifest.json
  entries/<entry-id>/bundle.lynx.bundle
  entries/<entry-id>/debug-metadata.json
  delivery/<provider-id>.json       # 上传回执，独立于 manifest 哈希
```

不重新打包 Bundle 来植入最终 SHA，避免“内容包含自身哈希”的循环。OTA 发布关联可在构建完成后追加独立的 release-binding 文件，不能覆盖构建清单及其身份。

```ts
interface BuildManifest {
  schemaVersion: '1.0';
  buildId: string;
  createdAt: string; // ISO-8601 UTC
  source: {
    gitCommit: string | null;
    dirty: boolean;
    lockfileSha256: string;
    sourceContext: 'sources_content' | 'snapshot' | 'none';
  };
  toolchain: {
    engineTarget: string;
    rspeedy: string;
    reactLynx: string;
    reactPlugin: string;
    debugMetadataPlugin: string;
  };
  entries: BuildEntry[];
}

interface BuildEntry {
  entryId: string; // 本次构建中唯一
  bundleName: string;
  lynxAppId: string | null;
  targetPlatforms: Array<'android' | 'ios' | 'harmony'>;
  bundle: ArtifactFile;
  debugMetadata: ArtifactFile;
  scripts: ScriptBinding[];
}
interface ArtifactFile {
  path: string; // 归档内相对路径，无 ../、绝对路径或符号链接逃逸
  sha256: string; // 64 位小写 hex
  sizeBytes: number;
}
interface ScriptBinding {
  artifactName: string;
  artifactKind: string; // 保留当前 metadata 的真实 kind，不自行猜测
  sourceMapKey: string;
  runtimeRelease: string; // debugmetadata:<sourceMapKey>
  sourceMapName: string;
  hasBytecodeDebugInfo: boolean;
}
```

索引要求：

- 一个构建清单至少有一个 entry；每个 entry 至少包含实际产生的脚本映射。
- `sourceMapKey` 来自 metadata，不由 git commit、文件名或 Bundle SHA 构造。
- 同一个 key 可以对应多个完全相同的脚本调试材料；必须校验一致性。若同 key 对应不同映射或 bytecode 信息，视为冲突，不能最后写入覆盖。
- runtimeRelease → script binding → metadata；bundle SHA → entry → 脚本清单。整个 Bundle 的 SHA 与脚本 key 不是同一个索引。
- 多个 entry/Bundle 的共享脚本可复用同一个 key；不能因为重复 key 就错误拒绝合法共享。
- 生成 manifest 的同时校验 metadata 中 source-map/debug-info 与脚本的对应关系；主线程字节码产物缺少必要映射为构建归档失败。
- `sourcesContent` 缺失且没有同构建源码快照时，仍可报告映射位置，但 sourceContext=none，不能承诺源码片段。受控 CI 要求 sourceContext 不为 none。

## 4. 可替换构建适配器

```ts
interface BuildArtifactProvider {
  readonly id: string;
  readonly capabilities: {
    ordinarySourceMap: boolean;
    lynxBytecodeMapping: boolean;
    perArtifactKeyIndex: boolean;
    privateArtifacts: boolean;
  };
  publish(input: {
    archiveRoot: string;
    manifest: BuildManifest;
    manifestSha256: string;
  }): Promise<ArtifactReceipt>;
}

interface ArtifactReceipt {
  schemaVersion: '1.0';
  providerId: string;
  buildId: string;
  manifestSha256: string;
  state: 'uploaded' | 'indexed';
  bindings: Array<{
    entryId: string;
    bundleSha256: string;
    sourceMapKey: string;
    providerReference: string; // 不含凭据的回执标识，不是公开源码链接
  }>;
  acceptedAt: string;
}
```

- 异常抛出即失败，不返回空 bindings 伪装成功。
- uploaded 仅表示存储成功；indexed 还需证明每个必需脚本 key 已可被平台定位。二者都不自动等于符号化成功。
- 独立测试输入必须与 runtime provider 保留的 release/key/文件名约定一致。
- 运行时 Provider 与构建 Provider 可以有不同代码包，但必须通过同一份厂商集成清单配对。清单记录 providerId、SDK 版本、构建适配版本、每端能力和已验证的定位类型。
- 凭据只由构建环境/选定工具读取，不出现在 manifest、SDK 事件或回执文档。
- 上传失败由 CI/适配器进行有限重试，不重建不同字节的 Bundle 后复用旧回执。

### 4.1 两种工作模式

| 模式 | 用途 | 成功含义 |
|---|---|---|
| archive | 厂商未选定、G1、离线验证 | 私有归档完整并通过校验，状态为 archived_local，明确未上传 |
| provider | G2 与正式监控发布 | 适配器返回完整回执；要求在线源码还原的发布还需通过平台索引/符号化关口 |

公共工具不依赖某个 Server。archive 模式保留标准 CI artifact 即可继续研发；不能把本地文件存在作为第三方平台已可查询。

### 4.2 调试材料保留

不能以“新版本发布”作为删除旧 DebugMetadata 的条件。受控发布至少保留仍支持运行/回滚的所有 Bundle 构建所需材料，再覆盖所选平台的异常查询保留期。

厂商选定前不在公共工具里自动删除历史归档。G2 集成必须明确厂商保留期、旧版本材料回收策略；没有历史材料的旧 Bundle 只能报告 unresolved，不拿最新材料兜底。

## 5. 源码还原规则

### 5.1 查找顺序

1. frame 自带 `runtimeRelease=debugmetadata:<key>`：按 key 找对应脚本材料，同时核对事件中的 Bundle SHA 与清单关联。
2. frame 没有 release，但有经过验证的实际 Bundle SHA 和唯一脚本名：只允许清单中唯一匹配；共享/同名冲突为 ambiguous_artifact。
3. 无可靠哈希/无唯一脚本：unresolved_identity。不能只凭 bundleName、URL 或“最新版本”选择材料。
4. frame key 与已知实际 Bundle 身份冲突：identity_mismatch，保留原始事件，不自动选其中一个。

### 5.2 两条解析路径

```text
后台文本 JS 的 line:column
  → 该脚本 source-map
  → source file:line:column

主线程 bytecode 的 function_id:pc
  → 对应 bytecode-debug-info
  → 编码后 JS line:column
  → 该脚本 source-map
  → source file:line:column
```

JS `.map` 不包含从字节码程序计数器回到生成代码位置的全部信息。不得直接把 functionId 作为 Source Map 的 line。后台若也使用 bytecode，依实际帧与调试格式选择解析器，不能按 thread 名猜定位格式。

### 5.3 反解结果

```ts
interface SymbolicatedError {
  schemaVersion: '1.0';
  eventId: string;
  buildId: string | null;
  bundleSha256: string | null;
  frames: Array<{
    frameIndex: number;
    status: 'mapped' | 'unresolved';
    reason: null | 'missing_metadata' | 'missing_source_map'
      | 'missing_bytecode_info' | 'unknown_position_kind'
      | 'identity_mismatch' | 'ambiguous_artifact' | 'unresolved_identity'
      | 'invalid_mapping' | 'no_mapping_for_position';
    source: {file: string; line: number; column: number} | null;
    sourceContext: string | null;
    sourceMapKey: string | null;
  }>;
}
```

原始 MonitorEvent 不被改写；映射结果通过 eventId 关联。一个异常允许部分帧成功，不因依赖库缺图丢掉已映射的业务帧。映射通常到语句/函数片段，不能承诺优化后的代码总能精确指向原始 throw 字符；验收应核对已知源码位置及合理映射区间。

## 6. 第三方不支持 Lynx 主线程时的处理

厂商适配必须明确以下三种结果，不制造第四种“已上传所以算支持”：

- 支持普通 Source Map 与 Lynx bytecode/debug metadata：执行 G2 双路径验收。
- 只支持普通 JS Source Map：后台错误能力可记录为已支持；主线程标记 unsupported，G2 的完整源码还原验收不通过。
- 提供可验证的预处理/转换扩展：另做该厂商转换器任务，必须用生产构建的主线程错误证明正确再声明支持。

公共层不在手机端下载完整源码材料，不偷偷增加用户自建 Server。厂商能力不足时，离线工具可以供排查，但不能冒充第三方大盘已经具备自动还原。

## 7. 计划实现的命令行行为

以下命令由当前分支实现：

```text
lynx-monitor-artifacts check --manifest <manifest.json>
lynx-monitor-artifacts publish --manifest <manifest.json> --provider <provider-id>
lynx-monitor-artifacts resolve --event <js-error.json> --manifest <manifest.json> --output <result.json>
```

- check：核对文件内容哈希/大小、entry、source-map key、必要 bytecode 信息；失败返回非零退出码。
- publish：当前明确返回 NOT_CONFIGURED；G2 选定厂商后才允许接入适配器，不自动退回 archive 后返回成功。
- resolve：完整保留 input event，按 frame 输出映射状态。无法映射可写出 unresolved 结果，但用于 CI 的“必需双路径验收”仍判失败。
- 命令仅处理显式参数目录；不扫描开发者其他项目或旧 worktree。

## 8. 构建交付关口

G1 必须有一份最小生产构建：后台 throw 与主线程 handler throw 都带已知源码位置，拿到原始 SDK 错误后可离线解出。至少再构建第二个版本改变源码位置，用旧错误验证仍匹配旧产物。

G2 增加同样的真实错误经选定 SDK 到平台显示原始/还原堆栈；校验两个同时存活的不同 Bundle 不互相覆盖版本标签。上传 receipt、索引可用、平台源码定位三个证据分别保存。

## 9. 官方依据

- [线上错误反解](https://lynxjs.org/zh/rspeedy/map-errors-to-source.md)：默认 DebugMetadata、生产清理 stage、release key、双路径、映射精度。
- [Rspeedy 变更记录](https://github.com/lynx-family/lynx-stack/blob/main/packages/rspeedy/core/CHANGELOG.md)：构建功能的版本边界。
- [Lynx 错误处理](https://lynxjs.org/zh/guide/devtool/handle-errors.md)：错误回调和调试日志定位；调试全量日志不作为生产采集方案。

本协议没有指定 ARMS/Bugly 等厂商的能力，适配依赖以厂商选择时的官方文档、锁定 SDK 和真实事件验收为准。
