package com.ota.android.sdk

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.UUID

/**
 * Store v2 的 embedded 逻辑描述存储。
 *
 * 这里只保存 identity 与受控来源描述，Bundle bytes 仍由 APK assets 直接提供，不复制到
 * 私有目录。current/previous/candidate 与远程 Release 全部由 [ReleaseTransaction] 管理。
 */
internal class EmbeddedReleaseStore(private val baseDirectory: File) {
  @Throws(IOException::class)
  fun embeddedRelease(lynxAppId: String): OtaModels.InstalledRelease? {
    val path = embeddedReleasePath(lynxAppId)
    if (!path.isFile) return null
    val map = OtaJson.asObject(OtaJson.parse(path.readText(Charsets.UTF_8)), path.toString())
    return OtaModels.InstalledRelease.fromJsonMap(map)
  }

  @Throws(IOException::class)
  fun saveEmbeddedRelease(release: OtaModels.InstalledRelease) {
    val target = embeddedReleasePath(release.context.lynxAppId)
    target.parentFile?.let(::ensureDirectory)
    val temporary = File(target.parentFile, ".embedded.json.tmp-${UUID.randomUUID()}")
    var backup: File? = null
    try {
      FileOutputStream(temporary, false).use {
        it.write(OtaJson.stringify(release.toJsonMap()).toByteArray(Charsets.UTF_8))
        it.fd.sync()
      }
      if (target.exists()) {
        backup = File(target.parentFile, ".embedded.json.bak-${UUID.randomUUID()}")
        if (!target.renameTo(backup)) throw IOException("无法备份 embedded 描述：$target")
      }
      if (!temporary.renameTo(target)) throw IOException("无法发布 embedded 描述：$target")
      backup?.delete()
      backup = null
    } catch (error: Throwable) {
      if (!target.exists()) backup?.renameTo(target)
      throw error
    } finally {
      if (temporary.exists()) temporary.delete()
      backup?.let { if (it.exists() && target.exists()) it.delete() }
    }
  }

  private fun embeddedReleasePath(lynxAppId: String): File {
    val appId = OtaModels.requireLynxAppId(lynxAppId)
    return File(File(File(baseDirectory, "apps"), appId), "embedded.json")
  }

  @Throws(IOException::class)
  private fun ensureDirectory(directory: File) {
    if (directory.isDirectory) return
    if (!directory.mkdirs() && !directory.isDirectory) {
      throw IOException("无法创建 OTA 目录：$directory")
    }
  }
}
