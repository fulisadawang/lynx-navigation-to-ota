package com.ota.android.sdk

import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException

/**
 * 兼容旧 pointer 的轻量存储。
 *
 * Android 端只使用 java.io.File，避免把桌面文件 API 带入 APK。
 */
class OtaReleaseStore(private val baseDirectory: File) {
  @Throws(IOException::class)
  fun currentRelease(lynxAppId: String): OtaModels.InstalledRelease? {
    return readPointerIfExists(currentReleasePointer(lynxAppId))
  }

  @Throws(IOException::class)
  fun stagedRelease(lynxAppId: String): OtaModels.InstalledRelease? {
    return readPointerIfExists(stagedReleasePointer(lynxAppId))
  }

  /** 读取旧 layout 的 previous pointer；只读，不触发 rollback。 */
  @Throws(IOException::class)
  fun previousRelease(lynxAppId: String): OtaModels.InstalledRelease? {
    return readPointerIfExists(previousReleasePointer(lynxAppId))
  }

  @Throws(IOException::class)
  fun embeddedRelease(lynxAppId: String): OtaModels.InstalledRelease? {
    return readPointerIfExists(embeddedReleasePointer(lynxAppId))
  }

  @Throws(IOException::class)
  fun saveEmbeddedRelease(release: OtaModels.InstalledRelease) {
    ensureBaseDirectory()
    writePointer(release, embeddedReleasePointer(release.context.lynxAppId))
    if (currentRelease(release.context.lynxAppId) == null) {
      writePointer(release, currentReleasePointer(release.context.lynxAppId))
    }
  }

  @Throws(IOException::class)
  fun stageRelease(release: OtaModels.InstalledRelease) {
    ensureBaseDirectory()
    writePointer(release, stagedReleasePointer(release.context.lynxAppId))
  }

  @Throws(IOException::class, OtaSdkException::class)
  fun activateStagedRelease(lynxAppId: String): OtaModels.InstalledRelease {
    val staged = stagedRelease(lynxAppId) ?: throw OtaSdkException("当前没有可激活的已下载版本")
    val current = currentRelease(staged.context.lynxAppId)
    if (current != null) {
      writePointer(current, previousReleasePointer(staged.context.lynxAppId))
    }
    writePointer(staged, currentReleasePointer(staged.context.lynxAppId))
    removePointer(stagedReleasePointer(staged.context.lynxAppId))
    return staged
  }

  /**
   * 兼容事务状态迁移：只更新 legacy current pointer，不改变 previous/staged。
   * 新调用方应优先使用 [ReleaseTransaction] 的原子 state；该方法仅供旧 pageId
   * facade 在新事务提交后保持可读。
   */
  @Throws(IOException::class)
  fun writeCurrentRelease(release: OtaModels.InstalledRelease) {
    ensureBaseDirectory()
    writePointer(release, currentReleasePointer(release.context.lynxAppId))
  }

  @Throws(IOException::class)
  fun rollback(lynxAppId: String): OtaModels.InstalledRelease? {
    val previous = readPointerIfExists(previousReleasePointer(lynxAppId))
    if (previous != null) {
      writePointer(previous, currentReleasePointer(lynxAppId))
      removePointer(previousReleasePointer(lynxAppId))
      return previous
    }

    val embedded = embeddedRelease(lynxAppId)
    if (embedded != null) {
      writePointer(embedded, currentReleasePointer(lynxAppId))
      return embedded
    }
    return null
  }

  @Throws(IOException::class)
  fun localBundlePath(releaseId: String, bundlePath: String): File {
    val path = File(releaseDirectory(releaseId), bundlePath.replace('/', File.separatorChar))
    path.parentFile?.let { ensureDirectory(it) }
    return path
  }

  @Throws(IOException::class)
  private fun ensureBaseDirectory() {
    ensureDirectory(baseDirectory)
    ensureDirectory(File(baseDirectory, "releases"))
  }

  private fun releaseDirectory(releaseId: String): File = File(File(baseDirectory, "releases"), releaseId)

  private fun currentReleasePointer(lynxAppId: String): File {
    return File(baseDirectory, "current-release-${OtaModels.safeFileName(lynxAppId)}.json")
  }

  private fun stagedReleasePointer(lynxAppId: String): File {
    return File(baseDirectory, "staged-release-${OtaModels.safeFileName(lynxAppId)}.json")
  }

  private fun previousReleasePointer(lynxAppId: String): File {
    return File(baseDirectory, "previous-release-${OtaModels.safeFileName(lynxAppId)}.json")
  }

  private fun embeddedReleasePointer(lynxAppId: String): File {
    return File(baseDirectory, "embedded-release-${OtaModels.safeFileName(lynxAppId)}.json")
  }

  @Throws(IOException::class)
  private fun readPointerIfExists(path: File): OtaModels.InstalledRelease? {
    if (!path.isFile) {
      return null
    }
    val raw = FileInputStream(path).use { String(it.readBytes(), Charsets.UTF_8) }
    val map = OtaJson.asObject(OtaJson.parse(raw), path.toString())
    return OtaModels.InstalledRelease.fromJsonMap(map)
  }

  @Throws(IOException::class)
  private fun writePointer(release: OtaModels.InstalledRelease, path: File) {
    path.parentFile?.let { ensureDirectory(it) }
    FileOutputStream(path, false).use {
      it.write(OtaJson.stringify(release.toJsonMap()).toByteArray(Charsets.UTF_8))
      it.fd.sync()
    }
  }

  @Throws(IOException::class)
  private fun removePointer(path: File) {
    if (path.exists() && !path.delete()) {
      throw IOException("无法删除 OTA pointer：$path")
    }
  }

  @Throws(IOException::class)
  private fun ensureDirectory(directory: File) {
    if (directory.isDirectory) return
    if (!directory.mkdirs() && !directory.isDirectory) {
      throw IOException("无法创建 OTA 目录：$directory")
    }
  }
}
