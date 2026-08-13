package com.example.lynxshell.ota

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import com.ota.android.sdk.OtaModels
import com.ota.android.sdk.OtaSdk
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Router 内置的 Activity-first OTA 适配器。
 *
 * 页面已有合法 current 时，prepare 只做本地 SHA 校验并立即返回，然后按当前 appId
 * 在默认 30 分钟门控后后台刷新；页面没有可用 Bundle 时，prepare 才等待当前 appId 的
 * 清单、下载、校验和原子激活。Application 启动和回前台仍然每次走全量 appId 同步。
 */
class LynxOtaRuntime(
    context: Context,
    private val config: LynxOtaConfig,
) : ActivityBundleRuntime {
    private val appContext = context.applicationContext
    private val sdk = OtaSdk(config.toSdkConfiguration(appContext))
    /** 生命周期刷新与页面后台刷新共用队列，避免同一个 SDK 实例并发提交激活事务。 */
    private val refreshExecutor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "lynx-shell-ota-refresh").apply { isDaemon = true }
    }
    /** 页面级刷新状态只在进程内保存；Application 启动/回前台本来就会做一次全量同步。 */
    private val refreshStateLock = Any()
    private val lastPageRefreshAt = LinkedHashMap<String, Long>()
    private val pageRefreshInFlight = LinkedHashSet<String>()
    /** 全量同步不做 30 分钟限流；只合并重叠生命周期回调，避免同一时间并发请求。 */
    private var fullSyncInFlight = false
    private var fullSyncPending = false

    override fun onApplicationStarted() {
        syncAllBundlesAsync()
    }

    override fun onApplicationForeground() {
        syncAllBundlesAsync()
    }

    /**
     * 供宿主在诊断页主动触发全量同步；不会阻塞主线程。
     *
     * 启动和回前台不走 30 分钟门控，每次都会触发全量 latest-bundle-list。若上一次全量
     * 请求仍在执行，只合并为一次 pending 请求；当前请求结束后仍会补发，不会永久丢掉这次
     * 生命周期事件。
     */
    fun syncAllBundlesAsync() {
        val shouldStart = synchronized(refreshStateLock) {
            if (fullSyncInFlight) {
                fullSyncPending = true
                false
            } else {
                fullSyncInFlight = true
                true
            }
        }
        if (!shouldStart) return

        refreshExecutor.execute {
            try {
                runCatching { sdk.syncLatestBundleLists() }
                    .onSuccess { result ->
                        // 全量接口已经检查了返回快照中的 appId；页面紧接着打开时无需再
                        // 为同一个 appId 额外请求一次定向接口。
                        markPageRefreshSuccess(result.results.keys)
                    }
                    .onFailure { error ->
                        // 生命周期同步失败不能阻塞已有本地 Bundle；页面打开时仍可定向修复。
                        Log.w(TAG, "全量 OTA 同步失败，保留当前本地版本", error)
                    }
            } finally {
                val shouldRunPending = synchronized(refreshStateLock) {
                    fullSyncInFlight = false
                    val pending = fullSyncPending
                    fullSyncPending = false
                    pending
                }
                if (shouldRunPending) syncAllBundlesAsync()
            }
        }
    }

    /** 按 appId 异步直接删除磁盘中的全部 OTA Bundle。 */
    fun deleteBundles(
        lynxAppId: String,
        onComplete: (success: Boolean, message: String?) -> Unit = { _, _ -> },
    ) {
        refreshExecutor.execute {
            val result = runCatching { sdk.deleteDownloadedBundles(lynxAppId) }
            // 删除成功或失败后都清掉门控：下一次页面打开必须重新确认当前 appId 的本地状态。
            clearPageRefreshGate(lynxAppId)
            Handler(Looper.getMainLooper()).post {
                onComplete(result.isSuccess, result.exceptionOrNull()?.message)
            }
        }
    }

    /** 异步直接删除所有 appId 的 OTA Bundle；APK assets/embedded 描述不会被删除。 */
    fun deleteAllBundles(onComplete: (success: Boolean, message: String?) -> Unit = { _, _ -> }) {
        refreshExecutor.execute {
            val result = runCatching { sdk.deleteAllDownloadedBundles() }
            clearAllPageRefreshGates()
            Handler(Looper.getMainLooper()).post {
                onComplete(result.isSuccess, result.exceptionOrNull()?.message)
            }
        }
    }

    /** 兼容旧诊断入口；仍然是直接删除所有下载内容。 */
    fun clearAllBundles(onComplete: (success: Boolean, message: String?) -> Unit = { _, _ -> }) {
        deleteAllBundles(onComplete)
    }

    private fun syncAppBundleAsync(lynxAppId: String) {
        if (!reservePageRefresh(lynxAppId)) return
        refreshExecutor.execute {
            try {
                // 如果页面任务排队期间启动了全量同步，让全量请求负责这个 appId，避免重复请求。
                val fullSyncRunning = synchronized(refreshStateLock) { fullSyncInFlight }
                if (!fullSyncRunning) {
                    runCatching { sdk.syncLatestBundleList(lynxAppId) }
                        .onSuccess { markPageRefreshSuccess(listOf(lynxAppId)) }
                        .onFailure { error ->
                            Log.w(TAG, "appId OTA 后台刷新失败：$lynxAppId", error)
                        }
                }
            } finally {
                synchronized(refreshStateLock) { pageRefreshInFlight.remove(lynxAppId) }
            }
        }
    }

    /** 页面已有合法 Bundle 时，只有超过 appId 级间隔才排队后台检查。 */
    private fun reservePageRefresh(lynxAppId: String): Boolean {
        val now = SystemClock.elapsedRealtime()
        synchronized(refreshStateLock) {
            if (fullSyncInFlight || !pageRefreshInFlight.add(lynxAppId)) return false
            val last = lastPageRefreshAt[lynxAppId]
            val interval = config.pageRefreshIntervalMillis
            if (last != null && interval > 0L && now - last < interval) {
                pageRefreshInFlight.remove(lynxAppId)
                return false
            }
            return true
        }
    }

    /** 只有成功收到并处理完最新快照后，才刷新页面级 30 分钟时间戳。 */
    private fun markPageRefreshSuccess(lynxAppIds: Collection<String>) {
        val now = SystemClock.elapsedRealtime()
        synchronized(refreshStateLock) {
            lynxAppIds.filter { it.isNotBlank() }.forEach { lastPageRefreshAt[it] = now }
        }
    }

    private fun clearPageRefreshGate(lynxAppId: String) {
        synchronized(refreshStateLock) {
            lastPageRefreshAt.remove(lynxAppId)
            pageRefreshInFlight.remove(lynxAppId)
        }
    }

    private fun clearAllPageRefreshGates() {
        synchronized(refreshStateLock) {
            lastPageRefreshAt.clear()
            pageRefreshInFlight.clear()
        }
    }

    override fun prepare(lynxAppId: String, bundleName: String): PreparedActivityBundle {
        // current() 已经在 Router 内置 SDK 中做本地 SHA 校验；损坏文件不会直接交给 LynxView。
        val localFile = runCatching { sdk.current(lynxAppId, bundleName) }.getOrNull()
        if (localFile != null && localFile.isFile && localFile.canRead()) {
            val current = sdk.current(lynxAppId)
            syncAppBundleAsync(lynxAppId)
            return prepared(lynxAppId, bundleName, localFile, current)
        }

        // 缺包或校验失败时只请求当前 appId；Activity 会在这段时间显示原生 Loading。
        val repairedFile = sdk.ensureBundleReady(lynxAppId, bundleName)
        if (!repairedFile.isFile || !repairedFile.canRead()) {
            throw IllegalStateException("OTA SDK 返回的 Bundle 不可读：${repairedFile.absolutePath}")
        }
        return prepared(lynxAppId, bundleName, repairedFile, sdk.current(lynxAppId))
    }

    override fun rollback(lynxAppId: String, reason: String): Boolean {
        return sdk.rollback(lynxAppId, reason) != null
    }

    /** 宿主退出时释放后台队列；Application 通常只需在进程结束时由系统回收。 */
    fun close() {
        refreshExecutor.shutdownNow()
    }

    private fun prepared(
        lynxAppId: String,
        bundleName: String,
        file: File,
        current: OtaModels.InstalledRelease?,
    ): PreparedActivityBundle = PreparedActivityBundle(
        lynxAppId = lynxAppId,
        bundleName = bundleName,
        file = file,
        releaseId = current?.context?.releaseId,
        // ReleaseTransaction 已经完成 SHA 校验；这里只把 Manifest 中同名 Bundle 的
        // 摘要传给监控快照，不把绝对路径暴露给 Router 或 Wire 事件。
        sha256 = current?.bundles
            ?.firstOrNull { it.bundlePath == bundleName }
            ?.bundleSha256,
    )

    private companion object {
        const val TAG = "LynxOtaRuntime"
    }
}
