import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'
import { execFileSync } from 'node:child_process'

interface ArchiveOptions {
  archiveRoot?: string
  targetPlatforms?: Array<'android' | 'ios' | 'harmony'>
}

interface CaptureRecord {
  assetName: string
  entryId: string
  metadataPath: string
}

interface BuildManifestFile {
  path: string
  sha256: string
  sizeBytes: number
}

interface BuildManifestScript {
  artifactName: string
  artifactKind: string
  sourceMapKey: string
  runtimeRelease: string
  sourceMapName: string
  hasBytecodeDebugInfo: boolean
}

interface BuildManifest {
  schemaVersion: '1.0'
  buildId: string
  createdAt: string
  source: {
    gitCommit: string | null
    dirty: boolean
    lockfileSha256: string
    sourceContext: 'sources_content' | 'snapshot' | 'none'
  }
  toolchain: {
    engineTarget: string
    rspeedy: string
    reactLynx: string
    reactPlugin: string
    debugMetadataPlugin: string
  }
  entries: Array<{
    entryId: string
    bundleName: string
    lynxAppId: string | null
    targetPlatforms: Array<'android' | 'ios' | 'harmony'>
    bundle: BuildManifestFile
    debugMetadata: BuildManifestFile
    scripts: BuildManifestScript[]
  }>
}

// 所有哈希都针对最终写入归档的字节计算，避免把编译阶段的中间内容当成 Bundle 身份。
function sha256File(filePath: string): string {
  return crypto.createHash('sha256').update(fs.readFileSync(filePath)).digest('hex')
}

function sha256Text(value: string): string {
  return crypto.createHash('sha256').update(value, 'utf8').digest('hex')
}

function readJson<T>(filePath: string): T {
  return JSON.parse(fs.readFileSync(filePath, 'utf8')) as T
}

function safeSegment(value: string): string {
  const normalized = value.replace(/[^a-zA-Z0-9._-]/g, '_')
  return normalized.length > 0 ? normalized : 'unknown'
}

function relativePosix(root: string, filePath: string): string {
  return path.relative(root, filePath).split(path.sep).join('/')
}

function gitOutput(cwd: string, args: string[]): string | null {
  try {
    return execFileSync('git', args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim() || null
  } catch {
    return null
  }
}

function readPackageVersion(projectRoot: string, packageName: string): string {
  const packageJson = readJson<Record<string, unknown>>(path.join(projectRoot, 'package.json'))
  const dependencies = {
    ...(packageJson.dependencies as Record<string, unknown> | undefined),
    ...(packageJson.devDependencies as Record<string, unknown> | undefined),
  }
  const version = dependencies[packageName]
  if (typeof version === 'string') return version
  const lockfilePath = path.join(projectRoot, 'pnpm-lock.yaml')
  if (fs.existsSync(lockfilePath)) {
    const lockfile = fs.readFileSync(lockfilePath, 'utf8')
    const prefix = packageName + '@'
    const line = lockfile.split('\n').find((value) =>
      value.startsWith("  '" + prefix) || value.startsWith('  ' + prefix))
    if (line) {
      const start = line.indexOf(prefix) + prefix.length
      const version = line.slice(start).replace(/^['"]/u, '').split(':')[0].split('(')[0].replace(/['"]$/u, '')
      if (version.length > 0) return version
    }
  }
  return 'unknown'
}

function entryIdFromMetadata(assetName: string, metadata: Record<string, unknown>): string {
  const rspeedy = (metadata.buildInfo as { rspeedy?: { bundlePath?: string } } | undefined)?.rspeedy
  const bundlePath = rspeedy?.bundlePath
  if (typeof bundlePath === 'string' && bundlePath.length > 0) {
    const firstPart = bundlePath.split(/[\\/]/u)[0]
    if (firstPart.length > 0) return safeSegment(firstPart.replace(/\.lynx\.bundle$/u, ''))
  }
  const parent = path.posix.basename(path.posix.dirname(assetName))
  return safeSegment(parent === '.' ? path.posix.basename(assetName, '.json') : parent)
}

function createBuildId(): string {
  const timestamp = new Date().toISOString().replace(/[-:.TZ]/gu, '')
  return 'lynx-' + timestamp + '-' + crypto.randomBytes(4).toString('hex')
}

function writeJson(filePath: string, value: unknown): void {
  fs.writeFileSync(filePath, JSON.stringify(value, null, 2) + '\n', 'utf8')
}

function copyFileWithRecord(root: string, source: string, destination: string): BuildManifestFile {
  const relativePath = relativePosix(root, destination)
  fs.mkdirSync(path.dirname(destination), { recursive: true })
  fs.copyFileSync(source, destination)
  return {
    path: relativePath,
    sha256: sha256File(destination),
    sizeBytes: fs.statSync(destination).size,
  }
}

function sourceContextOf(metadata: Record<string, unknown>): 'sources_content' | 'snapshot' | 'none' {
  const artifacts = Array.isArray(metadata.artifacts) ? metadata.artifacts : []
  const maps = artifacts.flatMap((artifact) => {
    const sources = (artifact as { debugSources?: unknown[] }).debugSources
    return Array.isArray(sources) ? sources : []
  }).filter((source) => (source as { kind?: string }).kind === 'source-map') as Array<{ map?: { sourcesContent?: unknown[] } }>
  if (maps.length === 0) return 'none'
  return maps.every((source) => Array.isArray(source.map?.sourcesContent)
    && source.map.sourcesContent.length > 0
    && source.map.sourcesContent.every((content) => typeof content === 'string'))
    ? 'sources_content'
    : 'none'
}

function scriptsOf(metadata: Record<string, unknown>): BuildManifestScript[] {
  const artifacts = Array.isArray(metadata.artifacts) ? metadata.artifacts : []
  const scripts: BuildManifestScript[] = []
  for (const artifact of artifacts as Array<{ kind?: string; filename?: string; debugSources?: unknown[] }>) {
    const debugSources = Array.isArray(artifact.debugSources) ? artifact.debugSources : []
    const sourceMap = debugSources.find((source) => (source as { kind?: string }).kind === 'source-map') as {
      filename?: string
      key?: string
    } | undefined
    if (!sourceMap?.key || !sourceMap.filename || !artifact.filename || !artifact.kind) continue
    scripts.push({
      artifactName: artifact.filename,
      artifactKind: artifact.kind,
      sourceMapKey: sourceMap.key,
      runtimeRelease: 'debugmetadata:' + sourceMap.key,
      sourceMapName: sourceMap.filename,
      hasBytecodeDebugInfo: debugSources.some((source) => (source as { kind?: string }).kind === 'bytecode-debug-info'),
    })
  }
  return scripts
}

function archiveAfterBuild(
  projectRoot: string,
  distRoot: string,
  captureRoot: string,
  buildId: string,
  options: Required<ArchiveOptions>,
): void {
  // 先写临时目录，再一次性 rename；归档读取方不会看到半成品清单。
  const archiveRoot = path.resolve(projectRoot, options.archiveRoot, buildId)
  const temporaryRoot = archiveRoot + '.tmp'
  fs.rmSync(temporaryRoot, { recursive: true, force: true })
  fs.mkdirSync(temporaryRoot, { recursive: true })

  const captures = fs.existsSync(captureRoot)
    ? fs.readdirSync(captureRoot, { withFileTypes: true })
      .filter((entry) => entry.isFile() && entry.name.endsWith('.capture.json'))
      .map((entry) => readJson<CaptureRecord>(path.join(captureRoot, entry.name)))
    : []
  const manifestEntries: BuildManifest['entries'] = []
  const lockfilePath = path.join(projectRoot, 'pnpm-lock.yaml')
  const gitCommit = gitOutput(projectRoot, ['rev-parse', 'HEAD'])
  const gitStatus = gitOutput(projectRoot, ['status', '--porcelain'])

  for (const capture of captures) {
    const metadata = readJson<Record<string, unknown>>(capture.metadataPath)
    const entryId = safeSegment(capture.entryId)
    const bundleName = entryId + '.lynx.bundle'
    const sourceBundle = path.join(distRoot, bundleName)
    if (!fs.existsSync(sourceBundle)) {
      console.warn('监控归档未找到 entry 对应 Bundle：' + sourceBundle)
      continue
    }
    const entryRoot = path.join(temporaryRoot, 'entries', entryId)
    const bundle = copyFileWithRecord(temporaryRoot, sourceBundle, path.join(entryRoot, 'bundle.lynx.bundle'))
    const debugMetadata = copyFileWithRecord(temporaryRoot, capture.metadataPath, path.join(entryRoot, 'debug-metadata.json'))
    manifestEntries.push({
      entryId,
      bundleName,
      lynxAppId: null,
      targetPlatforms: options.targetPlatforms,
      bundle,
      debugMetadata,
      scripts: scriptsOf(metadata),
    })
  }

  const manifest: BuildManifest = {
    schemaVersion: '1.0',
    buildId,
    createdAt: new Date().toISOString(),
    source: {
      gitCommit,
      dirty: Boolean(gitStatus),
      lockfileSha256: fs.existsSync(lockfilePath) ? sha256File(lockfilePath) : sha256Text('missing-lockfile'),
      sourceContext: captures.length > 0
        ? captures.every((capture) => sourceContextOf(readJson<Record<string, unknown>>(capture.metadataPath)) === 'sources_content')
          ? 'sources_content'
          : 'none'
        : 'none',
    },
    toolchain: {
      engineTarget: '4.1.0',
      rspeedy: readPackageVersion(projectRoot, '@lynx-js/rspeedy'),
      reactLynx: readPackageVersion(projectRoot, '@lynx-js/react'),
      reactPlugin: readPackageVersion(projectRoot, '@lynx-js/react-rsbuild-plugin'),
      debugMetadataPlugin: readPackageVersion(projectRoot, '@lynx-js/debug-metadata-rsbuild-plugin'),
    },
    entries: manifestEntries,
  }
  writeJson(path.join(temporaryRoot, 'manifest.json'), manifest)
  fs.mkdirSync(path.dirname(archiveRoot), { recursive: true })
  fs.rmSync(archiveRoot, { recursive: true, force: true })
  fs.renameSync(temporaryRoot, archiveRoot)
  fs.rmSync(captureRoot, { recursive: true, force: true })

  if (manifestEntries.length === 0) {
    console.warn('监控归档没有有效 entry：' + archiveRoot + '；请使用 lynx-monitor-artifacts check 获取明确失败原因')
  } else {
    console.log('LynxView 监控归档已生成：' + archiveRoot)
  }
}

class LynxMonitoringCapturePlugin {
  private readonly captureRoot: string

  constructor(captureRoot: string) {
    this.captureRoot = captureRoot
  }

  apply(compiler: {
    webpack: { Compilation: { PROCESS_ASSETS_STAGE_REPORT: number } }
    hooks: { thisCompilation: { tap: (name: string, callback: (compilation: {
      hooks: { processAssets: { tap: (options: { name: string; stage: number }, callback: () => void) => void } }
      getAssets: () => Array<{ name: string; source: { source: () => string | Buffer } }>
    }) => void) => void } }
    compilers?: Array<{
      webpack: { Compilation: { PROCESS_ASSETS_STAGE_REPORT: number } }
      hooks: { thisCompilation: { tap: (name: string, callback: (compilation: {
        hooks: { processAssets: { tap: (options: { name: string; stage: number }, callback: () => void) => void } }
        getAssets: () => Array<{ name: string; source: { source: () => string | Buffer } }>
      }) => void) => void } }
    }>
  }): void {
    // MultiCompiler 的 metadata 在子 compiler 中生成；必须逐个挂钩，不能只观察外层汇总。
    const targets = compiler.compilers ?? [compiler]
    for (const target of targets) {
      target.hooks.thisCompilation.tap('lynx:monitoring-capture', (compilation) => {
        compilation.hooks.processAssets.tap({
          name: 'lynx:monitoring-capture',
          // 官方插件在 REPORT+1 删除 metadata；同一 REPORT 阶段读取完整内容，确保生产输出仍可清理。
          stage: target.webpack.Compilation.PROCESS_ASSETS_STAGE_REPORT,
        }, () => {
          for (const asset of compilation.getAssets()) {
            if (path.posix.basename(asset.name) !== 'debug-metadata.json') continue
            const metadataText = asset.source.source().toString()
            const metadata = JSON.parse(metadataText) as Record<string, unknown>
            const entryId = entryIdFromMetadata(asset.name, metadata)
            const metadataPath = path.join(this.captureRoot, safeSegment(entryId) + '.debug-metadata.json')
            fs.mkdirSync(this.captureRoot, { recursive: true })
            fs.writeFileSync(metadataPath, JSON.stringify(metadata, null, 2) + '\n', 'utf8')
            writeJson(path.join(this.captureRoot, safeSegment(entryId) + '.capture.json'), {
              assetName: asset.name,
              entryId,
              metadataPath,
            } as CaptureRecord)
          }
        })
      })
    }
  }
}

export function pluginLynxMonitoringArtifacts(options: ArchiveOptions = {}) {
  const targetPlatforms = options.targetPlatforms ?? ['android', 'ios', 'harmony']
  const buildId = createBuildId()
  return {
    name: 'lynx:monitoring-artifacts',
    setup(api: {
      modifyBundlerChain: (callback: (chain: { plugin: (name: string) => { use: (plugin: typeof LynxMonitoringCapturePlugin, args: string[]) => void } }) => void) => void
      onAfterBuild: (callback: () => void) => void
    }) {
      const projectRoot = process.cwd()
      const captureRoot = path.join(projectRoot, '.artifacts', 'lynx-monitor', '.capture-' + buildId)
      api.modifyBundlerChain((chain) => {
        chain.plugin('lynx-monitoring-capture').use(LynxMonitoringCapturePlugin, [captureRoot])
      })
      api.onAfterBuild(() => {
        archiveAfterBuild(
          projectRoot,
          path.join(projectRoot, 'dist'),
          captureRoot,
          buildId,
          {
            archiveRoot: options.archiveRoot ?? '.artifacts/lynx-monitor',
            targetPlatforms,
          },
        )
      })
    },
  }
}
