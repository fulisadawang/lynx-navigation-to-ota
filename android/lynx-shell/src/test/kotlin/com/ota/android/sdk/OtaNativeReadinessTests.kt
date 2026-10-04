package com.ota.android.sdk

import java.io.File
import java.io.Closeable
import java.net.InetAddress
import java.net.URI
import java.net.ServerSocket
import java.time.Instant
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * 原生基座 OTA 启动恢复与确认提交边界。
 *
 * 这些测试只组合真实 OtaSdk/Store 和 Bundle fixture，不复制 Store 的状态转移。
 */
class OtaNativeReadinessTests {
  @get:Rule
  val temporaryFolder = TemporaryFolder()

  @Test
  fun `startup reconciliation discards stale trial and preserves pending for v2 and v3`() {
    verifyLegacyStartupRecovery()
    verifySelectedV3StartupRecovery()
  }

  @Test
  fun `direct sdk begin trial performs startup maintenance once and later reconciliation keeps live trial`() {
    verifyLegacyDirectBeginStartupMaintenance()
    verifySelectedV3DirectBeginStartupMaintenance()
  }

  @Test
  fun `interrupt before candidate state commit keeps old current and trial for v2 and v3`() {
    for (version in listOf(OtaModels.StoreVersion.V2, OtaModels.StoreVersion.V3)) {
      val gate = InterruptPreservingFaultGate()
      val fixture = CandidateStore(
        temporaryFolder.newFolder("cancel-before-${version.name.lowercase()}"),
        version,
        gate,
      )
      val candidate = fixture.stageCandidate(APP_PRIMARY)
      fixture.beginTrial(candidate.scope)
      gate.arm("BEFORE_STATE_COMMIT")

      val completed = CountDownLatch(1)
      val success = AtomicBoolean(false)
      val worker = Executors.newSingleThreadExecutor()
      try {
        val task = worker.submit {
          try {
            fixture.confirm(candidate.scope)
            success.set(true)
          } catch (_: Throwable) {
            // Root Store 在线性化点观察到中断后应停止本次确认。
          } finally {
            completed.countDown()
          }
        }
        assertTrue("${version.name}: confirmation did not reach before-commit gate", gate.awaitReached())
        assertTrue("${version.name}: worker cancel was not accepted", task.cancel(true))
        gate.release()
        assertTrue("${version.name}: confirmation did not finish", completed.await(5, TimeUnit.SECONDS))

        assertFalse("${version.name}: cancelled confirmation reported success", success.get())
        assertEquals("${version.name}: old current changed before commit", candidate.embedded.context.releaseId, fixture.current(candidate.scope)?.context?.releaseId)
        assertEquals("${version.name}: candidate release changed", candidate.candidateReleaseId, fixture.candidate(candidate.scope)?.release?.context?.releaseId)
        assertEquals("${version.name}: cancelled candidate must stay trial", OtaModels.CandidateStatus.TRIAL, fixture.candidate(candidate.scope)?.status)
      } finally {
        gate.release()
        worker.shutdownNow()
        fixture.close()
      }
    }
  }

  @Test
  fun `interrupt after candidate state commit never rolls back committed current for v2 and v3`() {
    for (version in listOf(OtaModels.StoreVersion.V2, OtaModels.StoreVersion.V3)) {
      val gate = InterruptPreservingFaultGate()
      val fixture = CandidateStore(
        temporaryFolder.newFolder("cancel-after-${version.name.lowercase()}"),
        version,
        gate,
      )
      val candidate = fixture.stageCandidate(APP_PRIMARY)
      fixture.beginTrial(candidate.scope)
      gate.arm("AFTER_STATE_COMMIT")

      val completed = CountDownLatch(1)
      val worker = Executors.newSingleThreadExecutor()
      try {
        val task = worker.submit {
          try {
            fixture.confirm(candidate.scope)
          } catch (_: Throwable) {
            // 提交已经完成后允许调用方观察取消；不允许把 durable current 回滚。
          } finally {
            completed.countDown()
          }
        }
        assertTrue("${version.name}: confirmation did not reach after-commit gate", gate.awaitReached())
        assertTrue("${version.name}: worker cancel was not accepted", task.cancel(true))
        gate.release()
        assertTrue("${version.name}: confirmation did not finish", completed.await(5, TimeUnit.SECONDS))

        assertEquals("${version.name}: committed candidate was rolled back", candidate.candidateReleaseId, fixture.current(candidate.scope)?.context?.releaseId)
      } finally {
        gate.release()
        worker.shutdownNow()
        fixture.close()
      }
    }
  }

  /** v2 没有 versioncode selection context；只验证 legacy Store 允许的 SDK 启动路径。 */
  private fun verifyLegacyStartupRecovery() {
    val root = temporaryFolder.newFolder("startup-v2")
    val store = CandidateStore(root, OtaModels.StoreVersion.V2)
    val stale = store.stageCandidate(APP_STALE)
    val pending = store.stageCandidate(APP_PENDING)
    store.beginTrial(stale.scope)
    store.close()

    val restarted = sdk(root, OtaModels.StoreVersion.V2, APP_PENDING)
    restarted.reconcileUserContext()

    assertNull("V2: stale trial must be removed", restarted.candidate(APP_STALE))
    assertEquals("V2: stale current must remain stable", stale.embedded.context.releaseId, restarted.current(APP_STALE)?.context?.releaseId)
    assertEquals("V2: pending candidate must remain", pending.candidateReleaseId, restarted.candidate(APP_PENDING)?.release?.context?.releaseId)
    assertEquals("V2: pending candidate must not be promoted", OtaModels.CandidateStatus.PENDING, restarted.candidate(APP_PENDING)?.status)
  }

  /** v3 必须由真实 selected sync 写入 decision/selection，不能用无上下文的低层 Store 伪造。 */
  private fun verifySelectedV3StartupRecovery() = SelectedV3Fixture(temporaryFolder.newFolder("startup-v3")).use { fixture ->
    val producer = fixture.sdk(APP_PENDING)
    val stale = fixture.stageCandidate(producer, APP_STALE)
    val pending = fixture.stageCandidate(producer, APP_PENDING)
    producer.beginCandidateTrial(APP_STALE)

    val restarted = fixture.sdk(APP_PENDING)
    restarted.reconcileUserContext()

    assertNull("V3: stale trial must be removed", restarted.candidate(APP_STALE))
    assertEquals("V3: stale current must remain stable", stale.embedded.context.releaseId, restarted.current(APP_STALE)?.context?.releaseId)
    assertEquals("V3: selected pending candidate must remain", pending.candidateReleaseId, restarted.candidate(APP_PENDING)?.release?.context?.releaseId)
    assertEquals("V3: selected pending candidate must not be promoted", OtaModels.CandidateStatus.PENDING, restarted.candidate(APP_PENDING)?.status)
  }

  private fun verifyLegacyDirectBeginStartupMaintenance() {
    val root = temporaryFolder.newFolder("direct-begin-v2")
    val store = CandidateStore(root, OtaModels.StoreVersion.V2)
    val stale = store.stageCandidate(APP_STALE)
    val live = store.stageCandidate(APP_LIVE)
    store.beginTrial(stale.scope)
    store.close()

    val directSdk = sdk(root, OtaModels.StoreVersion.V2, APP_LIVE)
    val liveTrial = directSdk.beginCandidateTrial(APP_LIVE)
    assertNull("V2: stale trial must be recovered before direct begin", directSdk.candidate(APP_STALE))
    assertEquals("V2: direct begin must still enter trial", OtaModels.CandidateStatus.TRIAL, liveTrial.status)
    assertEquals(live.candidateReleaseId, liveTrial.release.context.releaseId)
    directSdk.reconcileUserContext()
    assertEquals("V2: repeated maintenance must preserve live trial", OtaModels.CandidateStatus.TRIAL, directSdk.candidate(APP_LIVE)?.status)
  }

  private fun verifySelectedV3DirectBeginStartupMaintenance() = SelectedV3Fixture(temporaryFolder.newFolder("direct-begin-v3")).use { fixture ->
    val producer = fixture.sdk(APP_LIVE)
    fixture.stageCandidate(producer, APP_STALE)
    val live = fixture.stageCandidate(producer, APP_LIVE)
    producer.beginCandidateTrial(APP_STALE)

    val directSdk = fixture.sdk(APP_LIVE)
    val liveTrial = directSdk.beginCandidateTrial(APP_LIVE)
    assertNull("V3: stale trial must be recovered before direct begin", directSdk.candidate(APP_STALE))
    assertEquals("V3: direct begin must still enter trial", OtaModels.CandidateStatus.TRIAL, liveTrial.status)
    assertEquals(live.candidateReleaseId, liveTrial.release.context.releaseId)
    directSdk.reconcileUserContext()
    assertEquals("V3: repeated maintenance must preserve live trial", OtaModels.CandidateStatus.TRIAL, directSdk.candidate(APP_LIVE)?.status)
  }

  private fun sdk(root: File, version: OtaModels.StoreVersion, appId: String): OtaSdk = OtaSdk(
    OtaModels.Configuration(
      apiBaseUri = API_BASE,
      hostApp = HOST,
      lynxAppId = appId,
      environment = ENV,
      platform = PLATFORM,
      appVersion = "1.0.0",
      buildNumber = "100",
      userId = null,
      deviceId = null,
      deviceModel = null,
      osVersion = null,
      channel = null,
      region = null,
      nativeProtocolVersion = null,
      // Store v2 仍走 legacy OTA 协议，不能伪造 versioncode 驱动的 selection context。
      lynxSdkVersion = if (version == OtaModels.StoreVersion.V3) "4.1.0" else null,
      otaClientToken = null,
      storageDirectory = root,
      candidateActivationEnabled = true,
      storeVersion = version,
      allowLocalHTTPForTest = true,
      versionCode = if (version == OtaModels.StoreVersion.V3) "100" else null,
    ),
    NoNetworkApi,
  )

  private data class StagedCandidate(
    val scope: ReleaseTransaction.ReleaseScope,
    val embedded: OtaModels.InstalledRelease,
    val candidateReleaseId: String,
  )

  /** 只通过 OtaSdk selected sync 构造合法 v3 ref，覆盖真实 decision/selection 写入顺序。 */
  private class SelectedV3Fixture(private val root: File) : Closeable {
    private val server = LoopbackBundleServer(OtaNativeReadinessTests.PAYLOAD)
    private val api = SelectedV3Api()

    fun sdk(appId: String): OtaSdk = OtaSdk(
      OtaModels.Configuration(
        apiBaseUri = server.uri,
        hostApp = OtaNativeReadinessTests.HOST,
        lynxAppId = appId,
        environment = OtaNativeReadinessTests.ENV,
        platform = OtaNativeReadinessTests.PLATFORM,
        appVersion = "1.0.0",
        buildNumber = "100",
        userId = "readiness-user-a",
        deviceId = null,
        deviceModel = null,
        osVersion = null,
        channel = null,
        region = null,
        nativeProtocolVersion = null,
        lynxSdkVersion = "4.1.0",
        otaClientToken = null,
        storageDirectory = root,
        candidateActivationEnabled = true,
        storeVersion = OtaModels.StoreVersion.V3,
        allowLocalHTTPForTest = true,
        versionCode = "100",
      ),
      api,
    )

    fun stageCandidate(sdk: OtaSdk, appId: String): StagedCandidate {
      val scope = ReleaseTransaction.ReleaseScope(
        OtaNativeReadinessTests.ENV,
        OtaNativeReadinessTests.HOST,
        appId,
        OtaNativeReadinessTests.PLATFORM,
      )
      val source = File(root, "$appId.selected.embedded.lynx.bundle")
      source.writeBytes(OtaNativeReadinessTests.PAYLOAD)
      val sha = OtaIO.sha256(source)
      val embedded = OtaModels.InstalledRelease(
        OtaModels.CurrentReleaseContext(
          OtaNativeReadinessTests.ENV,
          OtaNativeReadinessTests.HOST,
          appId,
          "embedded-$appId",
          OtaNativeReadinessTests.PLATFORM,
          OtaModels.ReleaseStatus.ACTIVE,
        ),
        Instant.EPOCH,
        listOf(OtaModels.InstalledBundle(
          OtaNativeReadinessTests.PAGE_ID,
          OtaNativeReadinessTests.BUNDLE,
          sha,
          server.uri,
          source.absolutePath,
        )),
      )
      val releaseId = "candidate-$appId"
      sdk.initializeEmbeddedRelease(embedded)
      api.put(appId, latest(appId, releaseId, sha, source.length().toInt()))
      val result = sdk.syncLatestBundleList(appId)
      assertEquals("V3 selected fixture must stage candidate", OtaModels.UpdateResultType.CANDIDATE, result.type)
      assertEquals("V3 selected fixture must keep pending", OtaModels.CandidateStatus.PENDING, sdk.candidate(appId)?.status)
      return StagedCandidate(scope, embedded, releaseId)
    }

    override fun close() {
      server.close()
    }

    private fun latest(appId: String, releaseId: String, sha: String, size: Int): OtaModels.LatestBundleList =
      OtaModels.LatestBundleList(
        env = OtaNativeReadinessTests.ENV,
        hostApp = OtaNativeReadinessTests.HOST,
        lynxAppId = appId,
        releaseId = releaseId,
        platform = OtaNativeReadinessTests.PLATFORM,
        platforms = listOf(OtaNativeReadinessTests.PLATFORM),
        status = OtaModels.ReleaseStatus.ACTIVE,
        updatedAt = null,
        minAppVersion = null,
        maxAppVersion = null,
        lynxSdkRange = OtaModels.ReleaseVersionRange("4.0", "4.1"),
        nativeProtocolVersionRange = null,
        changedBundles = listOf(OtaModels.BundleArtifact(
          OtaNativeReadinessTests.PAGE_ID,
          OtaNativeReadinessTests.BUNDLE,
          sha,
          server.uri,
          size,
        )),
        selectionSchemaVersion = 1,
        releaseSequence = "1",
        selection = OtaSelectionMetadata(OtaSelectionKind.FULL, null, "1", "latest_full"),
        versionCodeRange = OtaVersionCodeRange("1", "999"),
      )
  }

  private class SelectedV3Api : OtaApiClient {
    private val values = ConcurrentHashMap<String, OtaModels.LatestBundleList>()

    fun put(appId: String, latest: OtaModels.LatestBundleList) {
      values[appId] = latest
    }

    override fun fetchLatestBundleList(
      env: OtaModels.Environment,
      hostApp: OtaModels.HostApp,
      lynxAppId: String,
      platform: OtaModels.Platform,
      context: OtaUserContext,
    ): OtaLatestSelection = OtaLatestSelection.Release(requireNotNull(values[lynxAppId]))

    override fun checkForUpdate(request: OtaModels.PolicyMatchRequest): OtaModels.PolicyMatchResponse = error("selected fixture uses latest-bundle-list")
    override fun fetchManifest(releaseId: String, env: OtaModels.Environment, hostApp: OtaModels.HostApp, lynxAppId: String, platform: OtaModels.Platform): OtaModels.ReleaseManifest = error("selected fixture uses inline latest manifest")
    override fun fetchLatestBundleLists(env: OtaModels.Environment, hostApp: OtaModels.HostApp, platform: OtaModels.Platform): OtaModels.HostLatestBundleLists =
      OtaModels.HostLatestBundleLists(env, hostApp, platform, values.values.toList(), 1)
    override fun reportEvent(payload: OtaModels.ReportPayload) = Unit
  }

  /** 只包装两种真实 Store 的公共操作，测试不复刻 candidate/current 状态机。 */
  private class CandidateStore(
    private val root: File,
    private val version: OtaModels.StoreVersion,
    gate: InterruptPreservingFaultGate? = null,
  ) {
    private val server = LoopbackBundleServer(OtaNativeReadinessTests.PAYLOAD)
    private val remoteUri: URI = if (version == OtaModels.StoreVersion.V3) server.uri else OtaNativeReadinessTests.REMOTE_BUNDLE_URI
    private val legacy = if (version == OtaModels.StoreVersion.V2) {
      ReleaseTransaction(root, faultInjector = gate ?: ReleaseTransaction.TransactionFaultInjecting.NONE)
    } else {
      null
    }
    private val canonical = if (version == OtaModels.StoreVersion.V3) {
      ContentAddressedOtaStore(
        root,
        faultInjector = gate ?: ContentAddressedFaultInjecting.NONE,
        allowLocalHTTPForTest = true,
      )
    } else {
      null
    }

    fun stageCandidate(appId: String): StagedCandidate {
      val scope = ReleaseTransaction.ReleaseScope(
        OtaNativeReadinessTests.ENV,
        OtaNativeReadinessTests.HOST,
        appId,
        OtaNativeReadinessTests.PLATFORM,
      )
      val source = File(root, "$appId.lynx.bundle").also { it.writeBytes(OtaNativeReadinessTests.PAYLOAD) }
      val sha = OtaIO.sha256(source)
      val embedded = OtaModels.InstalledRelease(
        OtaModels.CurrentReleaseContext(
          OtaNativeReadinessTests.ENV,
          OtaNativeReadinessTests.HOST,
          appId,
          "embedded-$appId",
          OtaNativeReadinessTests.PLATFORM,
          OtaModels.ReleaseStatus.ACTIVE,
        ),
        Instant.EPOCH,
        listOf(OtaModels.InstalledBundle(
          OtaNativeReadinessTests.PAGE_ID,
          OtaNativeReadinessTests.BUNDLE,
          sha,
          remoteUri,
          source.absolutePath,
        )),
      )
      val candidateReleaseId = "candidate-$appId"
      val manifest = OtaModels.LatestBundleList(
        env = OtaNativeReadinessTests.ENV,
        hostApp = OtaNativeReadinessTests.HOST,
        lynxAppId = appId,
        releaseId = candidateReleaseId,
        platform = OtaNativeReadinessTests.PLATFORM,
        platforms = listOf(OtaNativeReadinessTests.PLATFORM),
        status = OtaModels.ReleaseStatus.ACTIVE,
        updatedAt = null,
        minAppVersion = null,
        maxAppVersion = null,
        lynxSdkRange = null,
        nativeProtocolVersionRange = null,
        changedBundles = listOf(OtaModels.BundleArtifact(
          OtaNativeReadinessTests.PAGE_ID,
          OtaNativeReadinessTests.BUNDLE,
          sha,
          remoteUri,
          source.length().toInt(),
        )),
      ).asManifest()
      when (version) {
        OtaModels.StoreVersion.V2 -> {
          legacy!!.registerEmbeddedRelease(embedded)
          legacy.install(ReleaseTransaction.InstallRequest(scope, manifest, embedded, stageAsCandidate = true))
        }
        OtaModels.StoreVersion.V3 -> {
          canonical!!.registerEmbeddedRelease(embedded)
          canonical.install(ReleaseTransaction.InstallRequest(scope, manifest, embedded, stageAsCandidate = true))
        }
      }
      assertEquals("${version.name}: fixture must stage pending candidate", OtaModels.CandidateStatus.PENDING, candidate(scope)?.status)
      return StagedCandidate(scope, embedded, candidateReleaseId)
    }

    fun beginTrial(scope: ReleaseTransaction.ReleaseScope): OtaModels.CandidateSnapshot = when (version) {
      OtaModels.StoreVersion.V2 -> legacy!!.beginCandidateTrial(scope)
      OtaModels.StoreVersion.V3 -> canonical!!.beginCandidateTrial(scope)
    }

    fun confirm(scope: ReleaseTransaction.ReleaseScope): OtaModels.InstalledRelease = when (version) {
      OtaModels.StoreVersion.V2 -> legacy!!.confirmCandidate(scope)
      OtaModels.StoreVersion.V3 -> canonical!!.confirmCandidate(scope)
    }

    fun current(scope: ReleaseTransaction.ReleaseScope): OtaModels.InstalledRelease? = when (version) {
      OtaModels.StoreVersion.V2 -> legacy!!.current(scope)
      OtaModels.StoreVersion.V3 -> canonical!!.current(scope)
    }

    fun candidate(scope: ReleaseTransaction.ReleaseScope): OtaModels.CandidateSnapshot? = when (version) {
      OtaModels.StoreVersion.V2 -> legacy!!.candidate(scope)
      OtaModels.StoreVersion.V3 -> canonical!!.candidate(scope)
    }

    fun close() {
      server.close()
    }
  }

  /** V3 必须经过真实、受地址策略约束的 loopback 下载，不能把 file URI 伪装为 Bundle URL。 */
  private class LoopbackBundleServer(private val payload: ByteArray) : AutoCloseable {
    private val server = ServerSocket(0, 16, InetAddress.getByName("127.0.0.1"))
    private val worker = Executors.newSingleThreadExecutor { runnable ->
      Thread(runnable, "ota-native-readiness-http").apply { isDaemon = true }
    }
    @Volatile private var closed = false
    val uri: URI = URI.create("http://127.0.0.1:${server.localPort}/bundle")

    init {
      worker.execute {
        while (!closed) {
          val socket = runCatching { server.accept() }.getOrNull() ?: break
          socket.use { connection ->
            connection.soTimeout = 5_000
            val reader = connection.getInputStream().bufferedReader(Charsets.US_ASCII)
            reader.readLine() ?: return@use
            while (reader.readLine()?.isNotEmpty() == true) Unit
            val header = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: ${payload.size}\r\nConnection: close\r\n\r\n"
            connection.getOutputStream().use { output ->
              output.write(header.toByteArray(Charsets.US_ASCII))
              output.write(payload)
              output.flush()
            }
          }
        }
      }
    }

    override fun close() {
      closed = true
      runCatching { server.close() }
      worker.shutdownNow()
    }
  }

  /**
   * 保留 Future.cancel(true) 的中断直到 fault 栅栏被主测试放行。
   * 这避免 CountDownLatch.await() 自己吞掉中断而绕过 Store 的提交线性化检查。
   */
  private class InterruptPreservingFaultGate :
    ContentAddressedFaultInjecting,
    ReleaseTransaction.TransactionFaultInjecting {
    private val reached = CountDownLatch(1)
    private val released = CountDownLatch(1)
    @Volatile private var target: String? = null

    fun arm(point: String) {
      target = point
    }

    fun awaitReached(): Boolean = reached.await(5, TimeUnit.SECONDS)

    fun release() {
      released.countDown()
    }

    override fun check(point: ContentAddressedFaultPoint) = blockIfNeeded(point.name)

    override fun check(point: ReleaseTransaction.TransactionFaultPoint) = blockIfNeeded(point.name)

    private fun blockIfNeeded(point: String) {
      if (target != point) return
      reached.countDown()
      var interrupted = false
      while (true) {
        try {
          released.await()
          break
        } catch (_: InterruptedException) {
          interrupted = true
        }
      }
      if (interrupted) Thread.currentThread().interrupt()
    }
  }

  private object NoNetworkApi : OtaApiClient {
    override fun checkForUpdate(request: OtaModels.PolicyMatchRequest): OtaModels.PolicyMatchResponse = error("network is not part of this core test")
    override fun fetchManifest(releaseId: String, env: OtaModels.Environment, hostApp: OtaModels.HostApp, lynxAppId: String, platform: OtaModels.Platform): OtaModels.ReleaseManifest = error("network is not part of this core test")
    override fun fetchLatestBundleLists(env: OtaModels.Environment, hostApp: OtaModels.HostApp, platform: OtaModels.Platform): OtaModels.HostLatestBundleLists = error("network is not part of this core test")
    override fun reportEvent(payload: OtaModels.ReportPayload) = Unit
  }

  private companion object {
    val ENV = OtaModels.Environment.TEST
    val HOST = OtaModels.HostApp.CAPP
    val PLATFORM = OtaModels.Platform.ANDROID
    val API_BASE: URI = URI.create("http://127.0.0.1:1")
    val REMOTE_BUNDLE_URI: URI = URI.create("https://cdn.invalid/readiness.lynx.bundle")
    val PAYLOAD: ByteArray = "ota-native-readiness".toByteArray(Charsets.UTF_8)
    const val APP_PRIMARY = "10000001"
    const val APP_STALE = "10000002"
    const val APP_PENDING = "10000003"
    const val APP_LIVE = "10000004"
    const val PAGE_ID = 1
    const val BUNDLE = "main.lynx.bundle"
  }
}
