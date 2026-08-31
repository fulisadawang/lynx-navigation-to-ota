package com.ota.android.sdk

import java.io.File
import java.time.Instant

enum class OtaStorageReleaseRole {
  CURRENT,
  PREVIOUS,
  CANDIDATE,
  LEASED,
  ORPHAN,
}

data class OtaStorageFileSnapshot(
  @JvmField val relativePath: String,
  @JvmField val byteCount: Long,
  @JvmField val modifiedAt: Instant,
)

data class OtaStorageStateSnapshot(
  @JvmField val generation: Long,
  @JvmField val currentReleaseId: String,
  @JvmField val currentKind: String,
  @JvmField val previousReleaseId: String?,
  @JvmField val previousKind: String?,
  @JvmField val currentManifestId: String? = null,
  @JvmField val previousManifestId: String? = null,
)

data class OtaStorageCandidateSnapshot(
  @JvmField val releaseId: String,
  @JvmField val status: String,
  @JvmField val failureCount: Int,
)

data class OtaStorageReleaseSnapshot(
  @JvmField val releaseId: String,
  @JvmField val roles: Set<OtaStorageReleaseRole>,
  @JvmField val totalBytes: Long,
  @JvmField val fileCount: Int,
  @JvmField val manifestValid: Boolean,
  @JvmField val files: List<OtaStorageFileSnapshot>,
  @JvmField val truncated: Boolean,
  @JvmField val manifestId: String? = null,
  @JvmField val bundleCount: Int = 0,
  @JvmField val objectIds: Set<String> = emptySet(),
)

data class OtaStorageStagingSnapshot(
  @JvmField val transactionName: String,
  @JvmField val totalBytes: Long,
  @JvmField val fileCount: Int,
  @JvmField val files: List<OtaStorageFileSnapshot>,
  @JvmField val truncated: Boolean,
)

data class OtaStorageAppSnapshot(
  @JvmField val appId: String,
  @JvmField val state: OtaStorageStateSnapshot?,
  @JvmField val candidate: OtaStorageCandidateSnapshot?,
  @JvmField val releases: List<OtaStorageReleaseSnapshot>,
  @JvmField val staging: List<OtaStorageStagingSnapshot>,
  @JvmField val totalBytes: Long,
  @JvmField val fileCount: Int,
  @JvmField val objectCount: Int = 0,
  @JvmField val objectBytes: Long = 0,
  @JvmField val manifestBytes: Long = 0,
  @JvmField val lastOperation: String? = null,
)

data class OtaStorageSnapshot(
  @JvmField val rootPath: String,
  @JvmField val totalBytes: Long,
  @JvmField val fileCount: Int,
  @JvmField val generatedAt: Instant,
  @JvmField val apps: List<OtaStorageAppSnapshot>,
)

/**
 * 只读 OTA Store 浏览器入口。
 *
 * 调用方不能传任意扫描路径；构造时只绑定 Runtime 的 storageRoot。snapshot 与事务使用
 * 同一进程锁，不触发网络、修复、prune、SHA 重算或任何文件写入。
 */
class OtaStorageDiagnostics(
  storageRoot: File,
  private val maxFilesPerTree: Int = DEFAULT_MAX_FILES_PER_TREE,
  storeVersion: OtaModels.StoreVersion = OtaModels.StoreVersion.V2,
) {
  private val transaction: OtaReleaseStore = when (storeVersion) {
    OtaModels.StoreVersion.V2 -> LegacyOtaReleaseStore(storageRoot)
    OtaModels.StoreVersion.V3 -> ContentAddressedOtaStore(storageRoot)
  }

  init {
    require(maxFilesPerTree > 0) { "maxFilesPerTree 必须大于 0" }
  }

  fun snapshot(): OtaStorageSnapshot = transaction.storageSnapshot(maxFilesPerTree)

  private companion object {
    const val DEFAULT_MAX_FILES_PER_TREE = 2_000
  }
}
