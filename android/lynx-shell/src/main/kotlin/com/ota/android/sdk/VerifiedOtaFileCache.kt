package com.ota.android.sdk

import android.os.Build
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap

/** 只缓存已通过 SHA 校验的不可变 OTA 文件；文件身份变化时重新计算 SHA。 */
internal class VerifiedOtaFileCache {
  private data class FileIdentity(
    val device: Long,
    val inode: Long,
    val size: Long,
    val modifiedSeconds: Long,
    val modifiedNanos: Long,
    val changedSeconds: Long,
    val changedNanos: Long,
    val hasNanos: Boolean,
  ) {
    fun cacheable(): Boolean = hasNanos || changedSeconds < System.currentTimeMillis() / 1000L
  }

  private data class Verified(val sha256: String, val identity: FileIdentity)
  private val verified = ConcurrentHashMap<String, Verified>()

  fun matches(file: File, expectedSha256: String, expectedSize: Long): Boolean {
    val path = file.absolutePath
    if (!file.isFile || file.length() != expectedSize) {
      verified.remove(path)
      return false
    }
    val before = identity(file)
    if (before != null && before.size != expectedSize) {
      verified.remove(path)
      return false
    }
    val cached = verified[path]
    if (before?.cacheable() == true && cached != null && cached.identity == before &&
      cached.sha256.equals(expectedSha256, ignoreCase = true)) return true

    verified.remove(path)
    val matches = try { OtaIO.sha256(file).equals(expectedSha256, ignoreCase = true) }
    catch (_: IOException) { false }
    val after = identity(file)
    if (!matches || !file.isFile || file.length() != expectedSize ||
      (after != null && after.size != expectedSize) ||
      (before != null && after != null && before != after) ||
      ((before == null) != (after == null))) return false

    // API 24–26 只有秒级 ctime；当前秒内必须每次计算 SHA，避免改回 mtime 后命中旧缓存。
    if (after?.cacheable() == true) verified[path] = Verified(expectedSha256, after)
    return true
  }

  fun evictUnder(directory: File) {
    val prefix = directory.absolutePath.trimEnd(File.separatorChar) + File.separator
    verified.keys.forEach { if (it.startsWith(prefix)) verified.remove(it) }
  }

  fun evict(file: File) { verified.remove(file.absolutePath) }

  fun clear() { verified.clear() }

  private fun identity(file: File): FileIdentity? = try {
    val stat = Os.stat(file.absolutePath)
    if (!OsConstants.S_ISREG(stat.st_mode)) null else if (Build.VERSION.SDK_INT >= 27) {
      FileIdentity(stat.st_dev, stat.st_ino, stat.st_size,
        stat.st_mtim.tv_sec, stat.st_mtim.tv_nsec,
        stat.st_ctim.tv_sec, stat.st_ctim.tv_nsec, true)
    } else {
      FileIdentity(stat.st_dev, stat.st_ino, stat.st_size,
        stat.st_mtime, 0L, stat.st_ctime, 0L, false)
    }
  } catch (_: Exception) {
    // 本地 JVM 的 Android stub 或 stat 失败时不命中缓存，仍使用完整 SHA 校验。
    null
  } catch (_: LinkageError) {
    null
  }
}
