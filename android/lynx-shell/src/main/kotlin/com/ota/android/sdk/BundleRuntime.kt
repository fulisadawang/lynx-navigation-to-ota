package com.ota.android.sdk

import java.io.File
import java.io.IOException

/**
 * Bundle 运行时门面：路由按 `lynxAppId + bundleName` 取已提交 current，绝不读取
 * `.staging`。pageId 解析只保留在 [OtaSdk.currentTemplatePath] 兼容入口中。
 */
class BundleRuntime(private val transaction: ReleaseTransaction) {
  constructor(storageRoot: File) : this(ReleaseTransaction(storageRoot))

  @Throws(IOException::class, OtaSdkException::class)
  fun current(scope: ReleaseTransaction.ReleaseScope, bundleName: String): File? {
    return transaction.currentBundle(scope, bundleName)
  }

  @Throws(IOException::class, OtaSdkException::class)
  fun ensureBundleReady(scope: ReleaseTransaction.ReleaseScope, bundleName: String): File {
    return transaction.ensureBundleReady(scope, bundleName)
  }

  @Throws(IOException::class, OtaSdkException::class)
  fun current(lynxAppId: String, bundleName: String): File? {
    return transaction.currentBundle(lynxAppId, bundleName)
  }

  @Throws(IOException::class, OtaSdkException::class)
  fun ensureBundleReady(lynxAppId: String, bundleName: String): File {
    return transaction.ensureBundleReady(lynxAppId, bundleName)
  }

  @Throws(IOException::class, OtaSdkException::class)
  fun current(scope: ReleaseTransaction.ReleaseScope): OtaModels.InstalledRelease? {
    return transaction.current(scope)
  }

  @Throws(IOException::class, OtaSdkException::class)
  fun currentTemplatePath(scope: ReleaseTransaction.ReleaseScope, pageId: Int): File? {
    val release = transaction.current(scope) ?: return null
    return release.bundles.firstOrNull { it.pageId == pageId }?.let { bundle ->
      transaction.currentBundle(scope, bundle.bundlePath)
    }
  }

  @Throws(IOException::class, OtaSdkException::class)
  fun currentTemplatePath(lynxAppId: String, pageId: Int): File? {
    return transaction.currentTemplatePath(lynxAppId, pageId)
  }
}
