#!/usr/bin/env node

import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'
import { fileURLToPath } from 'node:url'

const HEX_64 = /^[0-9a-f]{64}$/u
const RUNTIME_RELEASE = /^debugmetadata:(.+)$/u

// 清单校验和源码还原只读取显式传入的归档，不扫描其他工作区或旧分支。
function sha256File(filePath) {
  return crypto.createHash('sha256').update(fs.readFileSync(filePath)).digest('hex')
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'))
}

function writeJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true })
  fs.writeFileSync(filePath, JSON.stringify(value, null, 2) + '\n', 'utf8')
}

function safeArchivePath(archiveRoot, relativePath) {
  if (typeof relativePath !== 'string' || relativePath.length === 0 || path.isAbsolute(relativePath)) return null
  const normalized = relativePath.split(path.sep).join('/')
  if (normalized.split('/').includes('..')) return null
  const resolved = path.resolve(archiveRoot, normalized)
  const rootWithSeparator = path.resolve(archiveRoot) + path.sep
  if (resolved !== path.resolve(archiveRoot) && !resolved.startsWith(rootWithSeparator)) return null
  return resolved
}

function addError(errors, message) {
  errors.push(message)
}

function validateFile(archiveRoot, descriptor, label, errors) {
  if (!descriptor || typeof descriptor !== 'object') {
    addError(errors, label + ' 缺少文件描述')
    return null
  }
  if (!HEX_64.test(descriptor.sha256 ?? '')) addError(errors, label + ' sha256 不是 64 位小写十六进制')
  if (!Number.isInteger(descriptor.sizeBytes) || descriptor.sizeBytes < 0) addError(errors, label + ' sizeBytes 不合法')
  const absolutePath = safeArchivePath(archiveRoot, descriptor.path)
  if (!absolutePath) {
    addError(errors, label + ' path 越界或为空')
    return null
  }
  if (!fs.existsSync(absolutePath) || !fs.statSync(absolutePath).isFile()) {
    addError(errors, label + ' 文件不存在：' + descriptor.path)
    return null
  }
  const stat = fs.statSync(absolutePath)
  if (stat.size !== descriptor.sizeBytes) addError(errors, label + ' sizeBytes 与实际文件不一致')
  if (sha256File(absolutePath) !== descriptor.sha256) addError(errors, label + ' sha256 与实际文件不一致')
  return absolutePath
}

function sourceMapsOf(metadata) {
  const result = []
  for (const artifact of Array.isArray(metadata?.artifacts) ? metadata.artifacts : []) {
    for (const source of Array.isArray(artifact.debugSources) ? artifact.debugSources : []) {
      if (source?.kind === 'source-map') result.push({ artifact, source })
    }
  }
  return result
}

function bytecodeSourcesOf(metadata, artifactName) {
  const artifact = (metadata?.artifacts ?? []).find((item) => item?.filename === artifactName)
  return (artifact?.debugSources ?? []).filter((source) => source?.kind === 'bytecode-debug-info')
}

function canonicalJson(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value)
  if (Array.isArray(value)) return '[' + value.map(canonicalJson).join(',') + ']'
  return '{' + Object.keys(value).sort().map((key) => JSON.stringify(key) + ':' + canonicalJson(value[key])).join(',') + '}'
}

export function checkManifest(manifestPath) {
  const errors = []
  const absoluteManifest = path.resolve(manifestPath)
  const archiveRoot = path.dirname(absoluteManifest)
  let manifest
  try {
    manifest = readJson(absoluteManifest)
  } catch (error) {
    return { ok: false, errors: ['无法读取 manifest：' + error.message], manifest: null }
  }
  if (manifest?.schemaVersion !== '1.0') addError(errors, 'schemaVersion 必须为 1.0')
  if (typeof manifest?.buildId !== 'string' || manifest.buildId.length === 0) addError(errors, 'buildId 缺失')
  if (!Array.isArray(manifest?.entries) || manifest.entries.length === 0) addError(errors, 'entries 不能为空')

  const keyToMap = new Map()
  for (const [index, entry] of (manifest.entries ?? []).entries()) {
    const prefix = 'entries[' + index + ']'
    if (typeof entry?.entryId !== 'string' || entry.entryId.length === 0) addError(errors, prefix + '.entryId 缺失')
    const bundlePath = validateFile(archiveRoot, entry?.bundle, prefix + '.bundle', errors)
    const metadataPath = validateFile(archiveRoot, entry?.debugMetadata, prefix + '.debugMetadata', errors)
    if (!metadataPath) continue
    let metadata
    try {
      metadata = readJson(metadataPath)
    } catch (error) {
      addError(errors, prefix + '.debugMetadata JSON 无法解析：' + error.message)
      continue
    }
    if (!Array.isArray(metadata.artifacts)) addError(errors, prefix + '.debugMetadata.artifacts 不是数组')
    const maps = sourceMapsOf(metadata)
    if (maps.length === 0) addError(errors, prefix + ' 没有 source-map 调试材料')
    for (const { artifact, source } of maps) {
      if (typeof source.key !== 'string' || source.key.length === 0) {
        addError(errors, prefix + ' 存在空 source-map key')
        continue
      }
      const previous = keyToMap.get(source.key)
      const current = canonicalJson(source.map)
      if (previous && previous !== current) addError(errors, 'sourceMapKey 冲突：' + source.key)
      keyToMap.set(source.key, current)
    }
    const scripts = Array.isArray(entry?.scripts) ? entry.scripts : []
    if (scripts.length === 0) addError(errors, prefix + '.scripts 不能为空')
    for (const [scriptIndex, script] of scripts.entries()) {
      const scriptPrefix = prefix + '.scripts[' + scriptIndex + ']'
      if (typeof script?.sourceMapKey !== 'string' || script.sourceMapKey.length === 0) addError(errors, scriptPrefix + '.sourceMapKey 缺失')
      if (script?.runtimeRelease !== 'debugmetadata:' + script?.sourceMapKey) addError(errors, scriptPrefix + '.runtimeRelease 与 sourceMapKey 不一致')
      const match = maps.find(({ artifact, source }) => artifact.filename === script.artifactName && source.key === script.sourceMapKey)
      if (!match) addError(errors, scriptPrefix + ' 无法在 metadata 中找到对应 artifact/source-map')
      if (script.artifactKind === 'main-thread' && script.hasBytecodeDebugInfo !== true) addError(errors, scriptPrefix + ' 主线程脚本缺少 bytecode debug info')
    }
    if (!bundlePath) continue
  }
  return { ok: errors.length === 0, errors, manifest }
}

function decodeVlq(segment, state) {
  const values = []
  let value = 0
  let shift = 0
  for (const char of segment) {
    const digit = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'.indexOf(char)
    if (digit < 0) throw new Error('Source Map 含非法 VLQ 字符')
    const continuation = (digit & 32) !== 0
    value += (digit & 31) << shift
    if (continuation) {
      shift += 5
      continue
    }
    const negative = (value & 1) === 1
    values.push(negative ? -(value >> 1) : value >> 1)
    value = 0
    shift = 0
  }
  if (shift !== 0) throw new Error('Source Map VLQ 未闭合')
  state.values = values
  return values
}

function sourceMapPosition(map, generatedLine, targetColumn) {
  // Source Map v3 的行号从 1 开始、列号从 0 开始；这里按同一口径输出源码位置。
  if (!map || map.version !== 3 || typeof map.mappings !== 'string' || !Array.isArray(map.sources)) return null
  const lines = map.mappings.split(';')
  if (generatedLine < 1 || generatedLine > lines.length) return null
  let sourceIndex = 0
  let originalLine = 0
  let originalColumn = 0
  let nameIndex = 0
  let best = null
  for (let lineIndex = 0; lineIndex < lines.length; lineIndex += 1) {
    let generatedColumn = 0
    const segments = lines[lineIndex].split(',')
    for (const segment of segments) {
      if (segment.length === 0) continue
      const values = []
      decodeVlq(segment, { set values(value) { values.push(...value) } })
      generatedColumn += values[0] ?? 0
      if (values.length >= 4) {
        sourceIndex += values[1]
        originalLine += values[2]
        originalColumn += values[3]
        if (values.length >= 5) nameIndex += values[4]
        if (lineIndex + 1 === generatedLine && generatedColumn <= targetColumn) {
          best = {
            source: map.sources[sourceIndex] ?? null,
            line: originalLine + 1,
            column: originalColumn,
            name: map.names?.[nameIndex] ?? null,
            sourceContent: map.sourcesContent?.[sourceIndex] ?? null,
          }
        }
      }
    }
    if (lineIndex + 1 === generatedLine) break
  }
  return best
}

function bytecodePosition(debugInfo, functionId, pc) {
  // 官方 Debug Info Remapping 使用 pc_index - 1 访问 line_col，不把 pc 当 Source Map 行号。
  const units = debugInfo?.lepusNG_debug_info?.function_info
  if (!Array.isArray(units)) return { position: null, reason: 'invalid_mapping' }
  const functionInfo = units.find((item) => item?.function_id === functionId)
  if (!functionInfo) return { position: null, reason: 'no_mapping_for_position' }
  const lineColumns = Array.isArray(functionInfo.line_col) ? functionInfo.line_col : []
  if (lineColumns.length === 0) return { position: null, reason: 'missing_bytecode_info' }
  if (!Number.isInteger(pc) || pc < 1) return { position: null, reason: 'invalid_mapping' }
  // Lynx Debug Info Remapping 约定 pc_index 从 1 开始，line_col 直接按 pc_index - 1 查找。
  const lineColumn = lineColumns[pc - 1]
  if (!lineColumn || !Number.isInteger(lineColumn.line) || !Number.isInteger(lineColumn.column)) {
    return { position: null, reason: 'no_mapping_for_position' }
  }
  return { position: { line: lineColumn.line, column: lineColumn.column }, reason: null }
}

function frameFileName(file) {
  if (typeof file !== 'string' || file.length === 0) return null
  try {
    return path.posix.basename(new URL(file).pathname)
  } catch {
    return path.posix.basename(file.split('?')[0].split('#')[0])
  }
}

function sourceContextSnippet(content, line) {
  if (typeof content !== 'string' || content.length === 0) return null
  const lines = content.split('\n')
  const start = Math.max(0, line - 2)
  const end = Math.min(lines.length, line + 1)
  const snippet = lines.slice(start, end).join('\n')
  return snippet.length > 4096 ? snippet.slice(0, 4096) : snippet
}

function unresolvedFrame(frame, reason) {
  return {
    frameIndex: 0,
    status: 'unresolved',
    reason,
    source: null,
    sourceContext: null,
    sourceMapKey: null,
    input: frame,
  }
}

function selectedEntries(manifest, event) {
  const bundleSha = event?.bundle?.sha256
  if (bundleSha) return manifest.entries.filter((entry) => entry.bundle?.sha256 === bundleSha)
  return manifest.entries
}

function resolveFrame(frame, entries, archiveRoot) {
  const fileName = frameFileName(frame?.file)
  const releaseMatch = typeof frame?.runtimeRelease === 'string' ? RUNTIME_RELEASE.exec(frame.runtimeRelease) : null
  const debugKey = frame?.debugKey ?? releaseMatch?.[1] ?? null
  const candidates = []
  for (const entry of entries) {
    const metadataPath = safeArchivePath(archiveRoot, entry.debugMetadata.path)
    if (!metadataPath) continue
    let metadata
    try {
      metadata = readJson(metadataPath)
    } catch {
      continue
    }
    for (const artifact of metadata.artifacts ?? []) {
      if (fileName && artifact.filename !== fileName) continue
      for (const source of artifact.debugSources ?? []) {
        if (source.kind !== 'source-map') continue
        if (debugKey && source.key !== debugKey) continue
        candidates.push({ entry, metadata, artifact, source })
      }
    }
  }
  if (candidates.length === 0) return unresolvedFrame(frame, debugKey ? 'unresolved_identity' : 'ambiguous_artifact')
  if (candidates.length > 1) {
    const uniqueKeys = new Set(candidates.map((candidate) => candidate.source.key))
    if (uniqueKeys.size !== 1) return unresolvedFrame(frame, 'ambiguous_artifact')
  }
  const candidate = candidates[0]
  let generatedPosition = null
  if (frame.positionKind === 'line_column') {
    generatedPosition = { line: frame.line, column: frame.column }
  } else if (frame.positionKind === 'function_pc') {
    const bytecode = bytecodeSourcesOf(candidate.metadata, candidate.artifact.filename)[0]
    if (!bytecode) return unresolvedFrame(frame, 'missing_bytecode_info')
    const decoded = bytecodePosition(bytecode.debugInfo, frame.functionId, frame.pc)
    if (!decoded.position) return unresolvedFrame(frame, decoded.reason)
    generatedPosition = decoded.position
  } else {
    return unresolvedFrame(frame, 'unknown_position_kind')
  }
  const mapped = sourceMapPosition(candidate.source.map, generatedPosition.line, generatedPosition.column)
  if (!mapped || !mapped.source) return unresolvedFrame(frame, 'no_mapping_for_position')
  return {
    frameIndex: 0,
    status: 'mapped',
    reason: null,
    source: { file: mapped.source, line: mapped.line, column: mapped.column },
    sourceContext: sourceContextSnippet(mapped.sourceContent, mapped.line),
    sourceMapKey: candidate.source.key,
    input: frame,
  }
}

export function resolveEvent(eventPath, manifestPath) {
  const event = readJson(path.resolve(eventPath))
  const manifest = readJson(path.resolve(manifestPath))
  const archiveRoot = path.dirname(path.resolve(manifestPath))
  const entries = selectedEntries(manifest, event)
  const eventBundleSha = event?.bundle?.sha256 ?? null
  const matchingBundle = eventBundleSha ? manifest.entries.some((entry) => entry.bundle?.sha256 === eventBundleSha) : true
  const frames = Array.isArray(event?.payload?.frames) ? event.payload.frames : []
  const resolvedFrames = frames.map((frame, index) => {
    const result = matchingBundle ? resolveFrame(frame, entries, archiveRoot) : unresolvedFrame(frame, 'identity_mismatch')
    return { ...result, frameIndex: index }
  })
  return {
    schemaVersion: '1.0',
    eventId: event?.eventId ?? null,
    buildId: manifest.buildId ?? null,
    bundleSha256: eventBundleSha,
    frames: resolvedFrames,
    event,
  }
}

function parseArgs(argv) {
  const values = {}
  let current = null
  for (const value of argv) {
    if (value.startsWith('--')) {
      current = value.slice(2)
      values[current] = true
    } else if (current) {
      values[current] = value
      current = null
    }
  }
  return values
}

function usage() {
  console.log('用法：lynx-monitor-artifacts <check|resolve|publish> --manifest <路径> [--event <路径>] [--output <路径>]')
}

async function main(argv) {
  const [command, ...rest] = argv
  const args = parseArgs(rest)
  if (!command || !['check', 'resolve', 'publish'].includes(command)) {
    usage()
    return 2
  }
  if (!args.manifest) {
    console.error('缺少 --manifest')
    return 2
  }
  if (command === 'check') {
    const result = checkManifest(args.manifest)
    console.log(JSON.stringify(result, null, 2))
    return result.ok ? 0 : 1
  }
  if (command === 'publish') {
    console.error('NOT_CONFIGURED：G2 Provider 尚未接入，本命令不会把本地归档伪装成已上传')
    return 3
  }
  if (!args.event) {
    console.error('resolve 命令缺少 --event')
    return 2
  }
  const result = resolveEvent(args.event, args.manifest)
  if (args.output) writeJson(path.resolve(args.output), result)
  else console.log(JSON.stringify(result, null, 2))
  return result.frames.every((frame) => frame.status === 'mapped') ? 0 : 1
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
if (isMain) process.exitCode = await main(process.argv.slice(2))
