package com.ota.android.sdk

import java.io.File
import java.io.IOException

class LynxHotUpdate {
  private var sdk: OtaSdk? = null

  @Throws(IOException::class)
  fun initialize(configuration: OtaModels.Configuration, embeddedRelease: OtaModels.InstalledRelease?) {
    val initializedSdk = OtaSdk(configuration)
    if (embeddedRelease != null) {
      initializedSdk.initializeEmbeddedRelease(embeddedRelease)
    }
    sdk = initializedSdk
  }

  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun syncLatestBundleLists(): OtaModels.HostBundleListSyncResult {
    return requireSdk().syncLatestBundleLists()
  }

  /** 页面缺包时只同步当前 lynxAppId；Application 生命周期仍使用全量入口。 */
  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun syncLatestBundleList(lynxAppId: String): OtaModels.LatestBundleListUpdateResult {
    return requireSdk().syncLatestBundleList(lynxAppId)
  }

  @Throws(IOException::class, OtaSdkException::class)
  fun currentTemplatePath(lynxAppId: String, pageId: Int): File? {
    return requireSdk().currentTemplatePath(lynxAppId, pageId)
  }

  /** 新 runtime 入口：Bundle 名称比旧 pageId 映射更稳定，按 appId 严格隔离。 */
  @Throws(IOException::class, OtaSdkException::class)
  fun current(lynxAppId: String, bundleName: String): File? {
    return requireSdk().current(lynxAppId, bundleName)
  }

  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun ensureBundleReady(lynxAppId: String, bundleName: String): File {
    return requireSdk().ensureBundleReady(lynxAppId, bundleName)
  }

  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun reportPageOpen(pageId: Int, lynxAppId: String?, bundlePath: String?) {
    requireSdk().reportPageOpen(pageId, lynxAppId, bundlePath)
  }

  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun rollback(reason: String): OtaModels.InstalledRelease? {
    return requireSdk().rollback(reason)
  }

  @Throws(IOException::class, OtaSdkException::class)
  fun rollback(lynxAppId: String, reason: String): OtaModels.InstalledRelease? {
    return requireSdk().rollback(lynxAppId, reason)
  }

  @Throws(OtaSdkException::class)
  private fun requireSdk(): OtaSdk {
    return sdk ?: throw OtaSdkException("LynxHotUpdate 尚未初始化")
  }
}
