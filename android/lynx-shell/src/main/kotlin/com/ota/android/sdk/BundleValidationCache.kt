package com.ota.android.sdk

import java.util.LinkedHashMap

/**
 * 进程内 Bundle 完整性校验结果缓存。
 *
 * 这里只缓存“某个文件指纹已经按期望 SHA 校验通过”的事实，不缓存 Bundle bytes，也不落盘。
 * App 进程结束后缓存自然消失；release、SHA、size 或 mtime 变化会生成新的 Key。
 */
internal class BundleValidationCache(
  private val maxEntries: Int = DEFAULT_MAX_ENTRIES,
) {
  init {
    require(maxEntries > 0) { "Bundle 校验缓存容量必须大于 0" }
  }

  data class Key(
    val scope: String,
    val releaseId: String,
    val bundlePath: String,
    val expectedSha256: String,
    val fileSize: Long,
    val lastModifiedMillis: Long,
  )

  private val entries = object : LinkedHashMap<Key, Unit>(maxEntries, 0.75f, true) {
    override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Key, Unit>?): Boolean =
      size > maxEntries
  }

  @Synchronized
  fun contains(key: Key): Boolean {
    val present = entries.containsKey(key)
    if (present) {
      // LinkedHashMap accessOrder=true；读取后把热 Key 提升到队尾。
      entries[key] = Unit
    }
    return present
  }

  @Synchronized
  fun put(key: Key) {
    entries[key] = Unit
  }

  @Synchronized
  fun remove(key: Key) {
    entries.remove(key)
  }

  @Synchronized
  fun clear() {
    entries.clear()
  }

  @Synchronized
  fun size(): Int = entries.size

  private companion object {
    const val DEFAULT_MAX_ENTRIES = 128
  }
}
