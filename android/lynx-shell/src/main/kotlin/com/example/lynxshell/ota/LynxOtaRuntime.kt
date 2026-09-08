package com.example.lynxshell.ota

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import com.example.lynxshell.LynxRouter
import com.ota.android.sdk.OtaModels
import com.ota.android.sdk.OtaSdk
import com.ota.android.sdk.OtaStorageDiagnostics
import com.ota.android.sdk.OtaStorageSnapshot
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.CancellationException
import java.util.concurrent.RejectedExecutionException

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
    private val sdkConfiguration = config.toSdkConfiguration(appContext)
    private val sdk = OtaSdk(sdkConfiguration)
    private val storageDiagnostics = OtaStorageDiagnostics(
        sdkConfiguration.storageDirectory,
        storeVersion = sdkConfiguration.storeVersion,
    )
    private val embeddedBundleRegistry = EmbeddedBundleRegistry(appContext)
    private val otaEnabled = !config.clientToken.isNullOrBlank()
    /** 同一身份写操作串行；换用户创建新队列，不能让旧 HTTP 阻塞新身份。 */
    private var refreshExecutor: ExecutorService = newRefreshExecutor()
    @Volatile private var closed = false
    private var refreshEpoch = sdk.userIdentityEpoch
    private var reconciledEpoch: Long? = null
    override val userIdentityEpoch: Long get() = sdk.userIdentityEpoch
    /** 页面级刷新状态只在进程内保存；Application 启动/回前台本来就会做一次全量同步。 */
    private val refreshStateLock = Any()
    private val pageRefreshGate = OtaPageRefreshGate(refreshEpoch)
    /** 全量同步不做 30 分钟限流；只合并重叠生命周期回调，避免同一时间并发请求。 */
    private var fullSyncInFlight = false
    private var fullSyncPending = false
    private val fullSyncWaiters = ArrayList<(Boolean) -> Unit>()
    private val navigationSnapshotLock = Any()
    private val navigationSnapshots = LinkedHashMap<String, NavigationSnapshot>()

    private data class NavigationSnapshot(
        val lynxAppId: String,
        val releaseId: String,
        var activityCount: Int,
        val identityEpoch: Long,
        var source: String,
    )

    private fun newRefreshExecutor(): ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "lynx-shell-ota-refresh").apply { isDaemon = true }
    }

    internal fun registerUserId(userId: String?): Boolean {
        check(!closed) { "OTA Runtime 已关闭" }
        val changed = sdk.registerUserId(userId)
        if (changed) {
            val callbacks = synchronized(refreshStateLock) {
                val epoch = sdk.userIdentityEpoch
                if (refreshEpoch == epoch) emptyList() else {
                    refreshExecutor.shutdownNow()
                    refreshExecutor = newRefreshExecutor()
                    refreshEpoch = epoch
                    reconciledEpoch = null
                    fullSyncInFlight = false
                    fullSyncPending = false
                    pageRefreshGate.reset(epoch)
                    fullSyncWaiters.toList().also { fullSyncWaiters.clear() }
                }
            }
            Handler(Looper.getMainLooper()).post { callbacks.forEach { runCatching { it(false) } } }
        }
        return changed
    }

    internal fun registerInitialUserId(userId: String?) { registerUserId(userId) }

    internal fun synchronizeRegisteredUser(epoch: Long) {
        if (epoch != userIdentityEpoch || closed) return
        syncAll(coalesce = true) {
            // 即使某个 App 失败，也必须重读其他 App 已提交的版本/撤销决定。
            LynxRouter.notifyOtaUserContext(this, epoch)
        }
    }

    init {
        // Store v3 首次启动只登记 embedded 元数据；APK 内置 Bundle 仍由 AssetManager
        // 直接读取，不复制到 files/lynx-ota-store。
        runCatching {
            embeddedBundleRegistry.installedReleases(
                environment = sdkConfiguration.environment,
                hostApp = sdkConfiguration.hostApp,
                platform = sdkConfiguration.platform,
            ).forEach(sdk::initializeEmbeddedRelease)
        }.onFailure { error ->
            Log.w(TAG, "内置 Bundle Manifest 登记失败，页面仍可尝试直接读取 assets", error)
        }
    }

    override fun onApplicationStarted() {
        // Demo 使用 Store v3；启动维护只回收无引用 CAS 对象和残留事务，不迁移旧布局。
        val epoch = userIdentityEpoch
        enqueue(epoch) {
            runCatching { reconcileIdentity(epoch); withIdentity(epoch) { sdk.pruneUnreferencedBundles() } }
                .onFailure { Log.w(TAG, "Store v3 冷启动维护失败，保留现有文件", it) }
        }
        if (otaEnabled) syncAll(coalesce = true)
    }

    override fun onApplicationForeground() {
        if (otaEnabled) syncAllBundlesAsync()
    }

    /**
     * 供宿主在诊断页主动触发全量同步；不会阻塞主线程。
     *
     * 启动和回前台不走 30 分钟门控，每次都会触发全量 latest-bundle-list。若上一次全量
     * 请求仍在执行，只合并为一次 pending 请求；当前请求结束后仍会补发，不会永久丢掉这次
     * 生命周期事件。
     */
    fun syncAllBundlesAsync(onComplete: ((success: Boolean) -> Unit)? = null) {
        syncAll(coalesce = false, onComplete = onComplete)
    }

    private fun syncAll(coalesce: Boolean, onComplete: ((Boolean) -> Unit)? = null) {
        if (!otaEnabled || closed) {
            onComplete?.let { callback ->
                Handler(Looper.getMainLooper()).post { callback(false) }
            }
            return
        }
        val epoch = userIdentityEpoch
        var obsolete = false
        val shouldStart = synchronized(refreshStateLock) {
            if (epoch != refreshEpoch) { obsolete = true; return@synchronized false }
            onComplete?.let(fullSyncWaiters::add)
            if (fullSyncInFlight) {
                if (!coalesce) fullSyncPending = true
                false
            } else {
                fullSyncInFlight = true
                true
            }
        }
        if (!shouldStart) {
            if (obsolete) Handler(Looper.getMainLooper()).post { onComplete?.invoke(false) }
            return
        }

        enqueue(epoch) {
            var success = false
            try {
                runCatching { reconcileIdentity(epoch); withIdentity(epoch) { sdk.syncLatestBundleLists() } }
                    .onSuccess { result ->
                        success = true
                        // 全量接口已经检查了返回快照中的 appId；页面紧接着打开时无需再
                        // 为同一个 appId 额外请求一次定向接口。
                        markPageRefreshSuccess(result.results.keys, epoch)
                        Log.i(TAG, "全量 OTA 同步完成：收到 ${result.results.size} 个 App ID")
                    }
                    .onFailure { error ->
                        // 生命周期同步失败不能阻塞已有本地 Bundle；页面打开时仍可定向修复。
                        if (error is com.ota.android.sdk.OtaHostBundleListSyncException) {
                            markPageRefreshSuccess(error.partialResult.results.keys, epoch)
                        }
                        if (epoch == userIdentityEpoch) Log.w(TAG, "全量 OTA 同步未全部完成：${error.javaClass.simpleName}")
                    }
            } finally {
                val completion = synchronized(refreshStateLock) {
                    if (epoch != refreshEpoch || epoch != userIdentityEpoch || closed) return@synchronized null
                    fullSyncInFlight = false
                    val pending = fullSyncPending
                    fullSyncPending = false
                    if (pending) {
                        pending to emptyList()
                    } else {
                        val callbacks = fullSyncWaiters.toList()
                        fullSyncWaiters.clear()
                        false to callbacks
                    }
                }
                val (shouldRunPending, waiters) = completion ?: return@enqueue
                if (shouldRunPending) {
                    // 有新的生命周期/主动刷新请求排队时，等最后一轮同步完成后再通知调用方。
                    syncAllBundlesAsync()
                } else if (waiters.isNotEmpty()) {
                    Handler(Looper.getMainLooper()).post {
                        waiters.forEach { callback ->
                            runCatching { callback(success && epoch == userIdentityEpoch && !closed) }
                        }
                    }
                }
            }
        }
    }

    /** 用户主动刷新使用的公开入口；完成后通知 Tab Host 重新读取本地 current。 */
    override fun refreshAllBundles(onComplete: (success: Boolean) -> Unit) {
        if (!otaEnabled) onComplete(false) else syncAll(coalesce = true, onComplete = onComplete)
    }

    /** 页面命中 OTA current 后，按 appId 的 30 分钟门控后台检查；不阻塞当前页面。 */
    override fun refreshAppBundleIfNeeded(lynxAppId: String) {
        if (otaEnabled) syncAppBundleAsync(lynxAppId)
    }

    override fun otaStorageSnapshot(): OtaStorageSnapshot = storageDiagnostics.snapshot()

    /** 按 appId 异步直接删除磁盘中的全部 OTA Bundle。 */
    fun deleteBundles(
        lynxAppId: String,
        onComplete: (success: Boolean, message: String?) -> Unit = { _, _ -> },
    ) {
        val epoch = userIdentityEpoch
        if (!enqueue(epoch) {
            val result = runCatching { withIdentity(epoch) { sdk.deleteDownloadedBundles(lynxAppId) } }
            // 删除成功或失败后都清掉门控：下一次页面打开必须重新确认当前 appId 的本地状态。
            clearPageRefreshGate(lynxAppId, epoch)
            Handler(Looper.getMainLooper()).post {
                onComplete(result.isSuccess && epoch == userIdentityEpoch, result.exceptionOrNull()?.javaClass?.simpleName)
            }
        }) Handler(Looper.getMainLooper()).post { onComplete(false, "OTA 用户上下文已失效") }
    }

    /** 异步直接删除所有 appId 的 OTA Bundle；APK assets/embedded 描述不会被删除。 */
    fun deleteAllBundles(onComplete: (success: Boolean, message: String?) -> Unit = { _, _ -> }) {
        val epoch = userIdentityEpoch
        if (!enqueue(epoch) {
            val result = runCatching { withIdentity(epoch) { sdk.deleteAllDownloadedBundles() } }
            clearAllPageRefreshGates(epoch)
            Handler(Looper.getMainLooper()).post {
                onComplete(result.isSuccess && epoch == userIdentityEpoch, result.exceptionOrNull()?.javaClass?.simpleName)
            }
        }) Handler(Looper.getMainLooper()).post { onComplete(false, "OTA 用户上下文已失效") }
    }

    /** 兼容旧诊断入口；仍然是直接删除所有下载内容。 */
    fun clearAllBundles(onComplete: (success: Boolean, message: String?) -> Unit = { _, _ -> }) {
        deleteAllBundles(onComplete)
    }

    private fun syncAppBundleAsync(lynxAppId: String) {
        val epoch = userIdentityEpoch
        if (!reservePageRefresh(lynxAppId, epoch)) return
        if (!enqueue(epoch) {
            try {
                // 如果页面任务排队期间启动了全量同步，让全量请求负责这个 appId，避免重复请求。
                val fullSyncRunning = synchronized(refreshStateLock) { fullSyncInFlight }
                if (!fullSyncRunning) {
                    runCatching { withIdentity(epoch) { sdk.syncLatestBundleList(lynxAppId) } }
                        .onSuccess { markPageRefreshSuccess(listOf(lynxAppId), epoch) }
                        .onFailure { error ->
                            Log.w(TAG, "appId OTA 后台刷新失败：$lynxAppId / ${error.javaClass.simpleName}")
                        }
                }
            } finally {
                pageRefreshGate.complete(lynxAppId, epoch)
            }
        }) pageRefreshGate.complete(lynxAppId, epoch)
    }

    /** 页面已有合法 Bundle 时，只有超过 appId 级间隔才排队后台检查。 */
    private fun reservePageRefresh(lynxAppId: String, epoch: Long): Boolean {
        val now = SystemClock.elapsedRealtime()
        synchronized(refreshStateLock) {
            if (closed || epoch != refreshEpoch || epoch != userIdentityEpoch || fullSyncInFlight) return false
            return pageRefreshGate.reserve(lynxAppId, epoch, now, config.pageRefreshIntervalMillis)
        }
    }

    /** 只有成功收到并处理完最新快照后，才刷新页面级 30 分钟时间戳。 */
    private fun markPageRefreshSuccess(lynxAppIds: Collection<String>, epoch: Long) {
        val now = SystemClock.elapsedRealtime()
        synchronized(refreshStateLock) {
            if (epoch != refreshEpoch || epoch != userIdentityEpoch) return
            pageRefreshGate.markSuccess(lynxAppIds.filter { it.isNotBlank() }, epoch, now)
        }
    }

    private fun clearPageRefreshGate(lynxAppId: String, epoch: Long) {
        synchronized(refreshStateLock) {
            if (epoch != refreshEpoch || epoch != userIdentityEpoch) return
            pageRefreshGate.clearApp(lynxAppId)
        }
    }

    private fun clearAllPageRefreshGates(epoch: Long) {
        synchronized(refreshStateLock) {
            if (epoch != refreshEpoch || epoch != userIdentityEpoch) return
            pageRefreshGate.clearAll()
        }
    }

    override fun prepare(lynxAppId: String, bundleName: String): PreparedActivityBundle = withIdentity {
        // 解析与 lease 登记在同一个 Store 临界区内，后台更新不能在两者之间删掉旧 Release。
        val currentLease = runCatching { sdk.acquireCurrentBundleLease(lynxAppId, bundleName) }.getOrNull()
        if (currentLease != null && currentLease.file.isFile && currentLease.file.canRead()) {
            syncAppBundleAsync(lynxAppId)
            return@withIdentity prepared(lynxAppId, bundleName, currentLease)
        }

        // APK 内置 Bundle 是无网络的 baseline；若启动全量同步尚未完成，先交付内置版本。
        resolveEmbedded(lynxAppId, bundleName)?.let { return@withIdentity it }

        if (!otaEnabled) {
            throw IllegalStateException("OTA 未配置 clientToken，且没有可用的 embedded Bundle：$lynxAppId/$bundleName")
        }

        // 缺包或校验失败时只请求当前 appId；Activity 会在这段时间显示原生 Loading。
        sdk.ensureBundleReady(lynxAppId, bundleName)
        val repairedLease = sdk.acquireCurrentBundleLease(lynxAppId, bundleName)
            ?: throw IllegalStateException("OTA SDK 激活后无法租用 Bundle：$lynxAppId/$bundleName")
        prepared(lynxAppId, bundleName, repairedLease)
    }

    /** 带 session 的缺包准备：优先从已固定 release 恢复，避免路由中途漂移。 */
    override fun prepare(
        lynxAppId: String,
        bundleName: String,
        navigationSnapshotID: String?,
    ): PreparedActivityBundle = withIdentity {
        val pinnedReleaseId = navigationSnapshotRelease(navigationSnapshotID, lynxAppId)
        if (pinnedReleaseId != null) {
            val pinnedLease = runCatching {
                sdk.acquireBundleLeaseForRelease(lynxAppId, pinnedReleaseId, bundleName)
            }.getOrNull()
            if (pinnedLease != null && pinnedLease.file.isFile && pinnedLease.file.canRead()) {
                return@withIdentity prepared(
                    lynxAppId,
                    bundleName,
                    pinnedLease,
                    source = navigationSnapshotSource(navigationSnapshotID),
                    navigationSnapshotID = navigationSnapshotID,
                )
            }
        }
        val value = prepare(lynxAppId, bundleName)
        pinNavigationSnapshot(navigationSnapshotID, value)
        value.copy(navigationSnapshotID = navigationSnapshotID)
    }

    /** 普通 Activity 页面可消费 candidate；Native Tab 仍只调用 resolveCurrent。 */
    override fun resolvePage(
        lynxAppId: String,
        bundleName: String,
    ): PreparedActivityBundle? = withIdentity { resolvePageUnpinned(lynxAppId, bundleName) }

    /** 路由页按 session 固定 release；current 后续变化不会让子路由换 Bundle。 */
    override fun resolvePage(
        lynxAppId: String,
        bundleName: String,
        navigationSnapshotID: String?,
    ): PreparedActivityBundle? = withIdentity {
        if (navigationSnapshotID.isNullOrBlank()) return@withIdentity resolvePageUnpinned(lynxAppId, bundleName)
        val pinnedReleaseId = navigationSnapshotRelease(navigationSnapshotID, lynxAppId)
        if (pinnedReleaseId != null) {
            val pinnedLease = runCatching {
                sdk.acquireBundleLeaseForRelease(lynxAppId, pinnedReleaseId, bundleName)
            }.getOrNull()
            if (pinnedLease != null && pinnedLease.file.isFile && pinnedLease.file.canRead()) {
                return@withIdentity prepared(
                    lynxAppId,
                    bundleName,
                    pinnedLease,
                    source = navigationSnapshotSource(navigationSnapshotID),
                    navigationSnapshotID = navigationSnapshotID,
                )
            }
        }
        val prepared = resolvePageUnpinned(lynxAppId, bundleName) ?: return@withIdentity null
        pinNavigationSnapshot(navigationSnapshotID, prepared)
        prepared.copy(navigationSnapshotID = navigationSnapshotID)
    }

    private fun resolvePageUnpinned(
        lynxAppId: String,
        bundleName: String,
    ): PreparedActivityBundle? {
        if (config.candidateActivationEnabled) {
            val lease = sdk.acquireCandidateTrialBundleLease(lynxAppId, bundleName)
            if (lease != null) {
                return prepared(lynxAppId, bundleName, lease, source = "candidate_trial")
            }
        }
        return resolveCurrent(lynxAppId, bundleName)
    }

    override fun retainNavigationSnapshot(navigationSnapshotID: String?) {
        if (navigationSnapshotID.isNullOrBlank()) return
        synchronized(navigationSnapshotLock) {
            navigationSnapshots[navigationSnapshotID]?.let { it.activityCount += 1 }
        }
    }

    override fun releaseNavigationSnapshot(navigationSnapshotID: String?) {
        if (navigationSnapshotID.isNullOrBlank()) return
        synchronized(navigationSnapshotLock) {
            val snapshot = navigationSnapshots[navigationSnapshotID] ?: return
            snapshot.activityCount -= 1
            if (snapshot.activityCount <= 0) navigationSnapshots.remove(navigationSnapshotID)
        }
    }

    override fun confirmCandidateHealthy(lynxAppId: String): Boolean =
        confirmCandidateHealthy(lynxAppId, null, userIdentityEpoch)

    override fun confirmCandidateHealthy(lynxAppId: String, expectedReleaseId: String?, expectedIdentityEpoch: Long?): Boolean {
        if (!config.candidateActivationEnabled) return false
        val epoch = expectedIdentityEpoch ?: userIdentityEpoch
        return runCatching {
            withIdentity(epoch) { sdk.confirmCandidateHealthy(lynxAppId, expectedReleaseId, epoch) }
            synchronized(navigationSnapshotLock) {
                navigationSnapshots.values.filter { it.lynxAppId == lynxAppId && it.identityEpoch == epoch && it.releaseId == expectedReleaseId }
                    .forEach { it.source = "ota_snapshot" }
            }
            clearPageRefreshGate(lynxAppId, epoch)
            true
        }.getOrDefault(false)
    }

    override fun resolveCurrent(
        lynxAppId: String,
        bundleName: String,
    ): PreparedActivityBundle? = withIdentity {
        val lease = runCatching { sdk.acquireCurrentBundleLease(lynxAppId, bundleName) }.getOrNull()
        if (lease != null && lease.file.isFile && lease.file.canRead()) {
            return@withIdentity prepared(lynxAppId, bundleName, lease)
        }
        resolveEmbedded(lynxAppId, bundleName)
    }

    override fun rollback(lynxAppId: String, reason: String): Boolean = rollback(lynxAppId, reason, null, userIdentityEpoch)

    override fun rollback(lynxAppId: String, reason: String, expectedReleaseId: String?, expectedIdentityEpoch: Long?): Boolean {
        val epoch = expectedIdentityEpoch ?: userIdentityEpoch
        return withIdentity(epoch) {
        if (config.candidateActivationEnabled && runCatching { sdk.candidate(lynxAppId) }.getOrNull() != null) {
            return@withIdentity runCatching {
                // candidate/trial 失败时只丢弃候选，不回滚掉仍然稳定的 current。
                sdk.discardCandidate(lynxAppId, expectedReleaseId, epoch)
                clearPageRefreshGate(lynxAppId, epoch)
                true
            }.getOrDefault(false)
        }
        if (expectedReleaseId != null && sdk.current(lynxAppId)?.context?.releaseId != expectedReleaseId) {
            throw CancellationException("失败回调不属于当前 OTA Release")
        }
        val restoredRemote = sdk.rollback(lynxAppId, reason, expectedReleaseId, epoch)
        if (restoredRemote != null) return@withIdentity true
        // Store 在一次事务内完成 previous/embedded 回退，不在探测后再次删除新提交的 current。
        embeddedBundleRegistry.containsApp(lynxAppId)
        }
    }

    private fun resolveEmbedded(lynxAppId: String, bundleName: String): PreparedActivityBundle? {
        return embeddedBundleRegistry.resolve(lynxAppId, bundleName)?.let { embedded ->
            PreparedActivityBundle(
                lynxAppId = embedded.lynxAppId,
                bundleName = embedded.bundleName,
                bytes = embedded.bytes,
                releaseId = embedded.releaseId,
                sha256 = embedded.sha256,
                source = "embedded_baseline",
                userIdentityEpoch = userIdentityEpoch,
            )
        }
    }

    /** 宿主退出时释放后台队列；Application 通常只需在进程结束时由系统回收。 */
    fun close() {
        closed = true
        sdk.invalidatePendingOperations()
        val callbacks = synchronized(refreshStateLock) {
            refreshExecutor.shutdownNow()
            fullSyncWaiters.toList().also { fullSyncWaiters.clear() }
        }
        Handler(Looper.getMainLooper()).post { callbacks.forEach { runCatching { it(false) } } }
    }

    /** 注册/关闭可与任务提交并发，拒绝旧队列任务应返回失败，不把异常抛到 UI 线程。 */
    private fun enqueue(epoch: Long, operation: () -> Unit): Boolean {
        val executor = synchronized(refreshStateLock) {
            refreshExecutor.takeIf { !closed && epoch == refreshEpoch && epoch == userIdentityEpoch }
        } ?: return false
        return try { executor.execute(operation); true } catch (_: RejectedExecutionException) { false }
    }

    private fun reconcileIdentity(epoch: Long) {
        if (synchronized(refreshStateLock) { reconciledEpoch == epoch }) return
        withIdentity(epoch) { sdk.reconcileUserContext() }
        synchronized(refreshStateLock) { if (epoch == userIdentityEpoch && epoch == refreshEpoch) reconciledEpoch = epoch }
    }

    /** 不持有网络大锁；SDK 把同一不可变身份传播到 Store 最终提交。 */
    private fun <T> withIdentity(epoch: Long = userIdentityEpoch, operation: () -> T): T {
        if (closed || epoch != userIdentityEpoch) throw CancellationException("OTA 用户上下文已失效")
        var produced: Any? = null
        try {
            val value = sdk.withUserIdentity(epoch) { operation().also { produced = it } }
            if (closed || epoch != userIdentityEpoch) throw CancellationException("OTA 用户上下文已失效")
            return value
        } catch (error: Throwable) {
            when (val value = produced) {
                is PreparedActivityBundle -> runCatching { value.releaseLease?.close() }
                is AutoCloseable -> runCatching { value.close() }
            }
            throw error
        }
    }

    private fun prepared(
        lynxAppId: String,
        bundleName: String,
        lease: com.ota.android.sdk.ReleaseTransaction.BundleLease,
        source: String = "ota_current",
        navigationSnapshotID: String? = null,
    ): PreparedActivityBundle = PreparedActivityBundle(
        lynxAppId = lynxAppId,
        bundleName = bundleName,
        file = lease.file,
        releaseId = lease.release.context.releaseId,
        sha256 = lease.bundle.bundleSha256,
        source = source,
        releaseLease = lease,
        navigationSnapshotID = navigationSnapshotID,
        userIdentityEpoch = lease.release.identityEpoch ?: userIdentityEpoch,
        selectionKind = lease.release.selection?.kind?.wireValue,
        releaseSequence = lease.release.selection?.releaseSequence,
    )

    private fun navigationSnapshotRelease(snapshotID: String?, lynxAppId: String): String? {
        if (snapshotID.isNullOrBlank()) return null
        synchronized(navigationSnapshotLock) {
            val snapshot = navigationSnapshots[snapshotID]?.takeIf { it.lynxAppId == lynxAppId } ?: return null
            if (snapshot.identityEpoch != userIdentityEpoch) throw CancellationException("旧用户导航会话不能打开新页面")
            return snapshot.releaseId
        }
    }

    private fun navigationSnapshotSource(snapshotID: String?): String = synchronized(navigationSnapshotLock) {
        navigationSnapshots[snapshotID]?.source ?: "ota_snapshot"
    }

    private fun pinNavigationSnapshot(snapshotID: String?, prepared: PreparedActivityBundle) {
        if (snapshotID.isNullOrBlank() || prepared.source == "embedded_baseline") return
        val releaseId = prepared.releaseId?.takeIf { it.isNotBlank() } ?: return
        val epoch = prepared.userIdentityEpoch ?: userIdentityEpoch
        if (epoch != userIdentityEpoch) {
            runCatching { prepared.releaseLease?.close() }
            throw CancellationException("旧用户 Bundle 不能固定到新导航会话")
        }
        synchronized(navigationSnapshotLock) {
            val existing = navigationSnapshots[snapshotID]
            if (existing == null) {
                navigationSnapshots[snapshotID] = NavigationSnapshot(prepared.lynxAppId, releaseId, 1, epoch,
                    if (prepared.source == "candidate_trial") "candidate_trial" else "ota_snapshot")
            } else if (existing.lynxAppId == prepared.lynxAppId && (existing.releaseId != releaseId || existing.identityEpoch != epoch)) {
                runCatching { prepared.releaseLease?.close() }
                throw CancellationException("导航会话已固定其他 Release 或身份")
            }
        }
    }

    private companion object {
        const val TAG = "LynxOtaRuntime"
    }
}
