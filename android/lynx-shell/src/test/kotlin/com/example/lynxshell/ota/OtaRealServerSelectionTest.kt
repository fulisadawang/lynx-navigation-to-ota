package com.example.lynxshell.ota

import com.ota.android.sdk.OtaModels
import com.ota.android.sdk.OtaSdk
import com.ota.android.sdk.OtaSdkException
import com.ota.android.sdk.OtaSelectionKind
import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import java.util.concurrent.Callable
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * JVM + loopback 真实 Server/HTTP/Store v3 协议验收。
 *
 * 这些测试不启动 Android Context、ADB、模拟器或设备。fixture 控制面只接受显式的
 * loopback origin 和本地控制 header；选择结果始终由真实 Server 与真实 OtaSdk 产生。
 */
class OtaRealServerSelectionTest {
  @get:Rule
  val temporaryFolder = TemporaryFolder()

  private lateinit var origin: URI

  @Before
  fun resetFixture() {
    val configured = System.getenv(SERVER_ORIGIN_ENV)?.trim().orEmpty()
    assumeTrue("$SERVER_ORIGIN_ENV 未设置，跳过 loopback 真实 Server 集成测试", configured.isNotEmpty())
    origin = URI.create(configured)
    require(
      origin.scheme == "http" && origin.host == "127.0.0.1" && origin.port in 1..65535 &&
        origin.userInfo == null && origin.rawPath.orEmpty() in setOf("", "/") &&
        origin.rawQuery == null && origin.rawFragment == null,
    ) { "$SERVER_ORIGIN_ENV 只允许 http://127.0.0.1:<port>" }
    control("reset")
  }

  @Test
  fun `real HTTP selects full gray newer full promotion rollback and forced embedded cold state`() {
    val ids = releaseIds()
    val root = temporaryFolder.newFolder("real-selection")
    val sdk = newSdk(root, userId = null)
    val phases = JSONArray()

    control("metrics/reset")
    val full5 = sdk.syncLatestBundleList(APP_ID)
    assertEquals(ids.full5, sdk.current(APP_ID)?.context?.releaseId)
    assertEquals(100, full5.summary?.downloadedBundleCount)
    assertEquals(100, appSnapshot(root).objectCount)
    phases.put(evidencePhase(root, sdk, "anonymous-full5", "anonymous", listOf("downloaded-100", "cas-100")))

    control("stage", json("stage", "gray6"))
    assertTrue(sdk.registerUserId(USER_A))
    sdk.reconcileUserContext()
    control("metrics/reset")
    val gray6 = sdk.syncLatestBundleList(APP_ID)
    assertEquals(ids.gray6, sdk.current(APP_ID)?.context?.releaseId)
    assertEquals(OtaSelectionKind.GRAY, sdk.current(APP_ID)?.selection?.kind)
    assertEquals(1, gray6.summary?.downloadedBundleCount)
    assertEquals(99, gray6.summary?.reusedBundleCount)
    assertEquals(101, appSnapshot(root).objectCount)
    phases.put(evidencePhase(root, sdk, "A-gray6", "A", listOf("downloaded-1", "reused-99", "cas-101")))

    assertTrue(sdk.registerUserId(USER_B))
    assertEquals(ids.full5, sdk.current(APP_ID)?.context?.releaseId)
    sdk.reconcileUserContext()
    control("metrics/reset")
    sdk.syncLatestBundleList(APP_ID)
    assertEquals(ids.full5, sdk.current(APP_ID)?.context?.releaseId)
    assertEquals(0, metrics().getInt("bundleSuccessCount"))
    phases.put(evidencePhase(root, sdk, "B-full5", "B", listOf("gray-not-authorized", "bundle-get-0")))

    control("stage", json("stage", "full7"))
    assertTrue(sdk.registerUserId(USER_A))
    sdk.reconcileUserContext()
    control("metrics/reset")
    val full7 = sdk.syncLatestBundleList(APP_ID)
    assertEquals(ids.full7, sdk.current(APP_ID)?.context?.releaseId)
    assertEquals(OtaSelectionKind.FULL, sdk.current(APP_ID)?.selection?.kind)
    assertEquals(1, full7.summary?.downloadedBundleCount)
    phases.put(evidencePhase(root, sdk, "A-full7-wins", "A", listOf("newer-full-over-gray", "downloaded-1")))

    control("stage", json("stage", "gray8"))
    control("metrics/reset")
    val gray8 = sdk.syncLatestBundleList(APP_ID)
    assertEquals(ids.gray8, sdk.current(APP_ID)?.context?.releaseId)
    assertEquals(OtaSelectionKind.GRAY, sdk.current(APP_ID)?.selection?.kind)
    assertEquals(1, gray8.summary?.downloadedBundleCount)
    phases.put(evidencePhase(root, sdk, "A-gray8", "A", listOf("gray-selected", "downloaded-1")))

    control("publish", json("alias", "gray8", "type", "full"))
    assertTrue(sdk.registerUserId(USER_B))
    sdk.reconcileUserContext()
    control("metrics/reset")
    sdk.syncLatestBundleList(APP_ID)
    assertEquals(ids.gray8, sdk.current(APP_ID)?.context?.releaseId)
    assertEquals(OtaSelectionKind.FULL, sdk.current(APP_ID)?.selection?.kind)
    assertEquals(0, metrics().getInt("bundleSuccessCount"))
    phases.put(evidencePhase(root, sdk, "B-gray8-promoted-full", "B", listOf("same-release-kind-full", "bundle-get-0")))

    val fixtureState = control("state")
    val full5MarkerSha = fixtureState.getJSONObject("aliases").getJSONObject("full5").getString("markerSha256")
    val beforeRollback = appSnapshot(root)
    assertEquals(ids.gray8, beforeRollback.state?.currentReleaseId)
    assertEquals(ids.full7, beforeRollback.state?.previousReleaseId)
    assertEquals(101, beforeRollback.objectCount)
    assertFalse("超出 current/previous retention 的 full5 独有 050 对象应已被 GC", casObjectFile(root, full5MarkerSha).isFile)

    control("rollback", json("from", "gray8", "target", "full5"))
    control("metrics/reset")
    val rollback = sdk.syncLatestBundleList(APP_ID)
    assertEquals(ids.full5, sdk.current(APP_ID)?.context?.releaseId)
    assertEquals("server_rollback", lastDecisionReason(root))
    assertEquals(1, rollback.summary?.downloadedBundleCount)
    assertEquals(99, rollback.summary?.reusedBundleCount)
    assertEquals(0, rollback.summary?.copiedBundleCount)
    assertEquals(1, metrics().getInt("bundleRequestCount"))
    assertEquals(1, metrics().getInt("bundleSuccessCount"))
    assertEquals(101, appSnapshot(root).objectCount)
    assertTrue("回滚 full5 后应重新写入其独有 050 CAS 对象", casObjectFile(root, full5MarkerSha).isFile)
    phases.put(evidencePhase(root, sdk, "server-rollback-full5", "B", listOf("server-rollback-reason", "downloaded-1", "reused-99", "copied-0", "cas-bounded-101")))

    control("fallback", json("enabled", true, "platforms", listOf("android")))
    control("metrics/reset")
    val forced = sdk.syncLatestBundleList(APP_ID)
    assertEquals(OtaModels.UpdateResultType.NO_RELEASE, forced.type)
    assertNull(sdk.current(APP_ID))

    val cold = newSdk(root, userId = USER_B)
    assertNull("持久化 use_embedded 决定必须在冷 SDK 中继续屏蔽 remote current", cold.current(APP_ID))
    assertEquals("use_embedded", lastDecisionAction(root))
    phases.put(evidencePhase(root, cold, "forced-embedded-cold-state", "B", listOf("effective-current-null", "decision-persisted")))
    writeEvidence(
      "01-real-selection-flow.json",
      "real HTTP selects full gray newer full promotion rollback and forced embedded cold state",
      phases,
      listOf("real-http", "store-v3", "no-device"),
    )
  }

  @Test
  fun `held A response fails after B sync and cannot change B state`() {
    val ids = releaseIds()
    val root = temporaryFolder.newFolder("held-identity")
    val sdk = newSdk(root, userId = USER_B)
    sdk.syncLatestBundleList(APP_ID)
    assertEquals(ids.full5, sdk.current(APP_ID)?.context?.releaseId)

    control("stage", json("stage", "gray6"))
    control("delay-latest", json("audience", "A", "count", 1, "milliseconds", 0))
    assertTrue(sdk.registerUserId(USER_A))
    sdk.reconcileUserContext()
    val aEpoch = sdk.userIdentityEpoch
    val worker = Executors.newSingleThreadExecutor()
    try {
      val heldA = worker.submit(Callable {
        sdk.withUserIdentity(aEpoch) { sdk.syncLatestBundleList(APP_ID) }
      })
      awaitPendingLatest()

      assertTrue(sdk.registerUserId(USER_B))
      sdk.reconcileUserContext()
      sdk.syncLatestBundleList(APP_ID)
      assertEquals(ids.full5, sdk.current(APP_ID)?.context?.releaseId)
      val bState = stateFile(root).readBytes()

      control("release-delays")
      expectSdkCode("stale_identity") { heldA.get(20, TimeUnit.SECONDS) }
      assertTrue("旧 A 响应完成后不得改写 B 的 State", bState.contentEquals(stateFile(root).readBytes()))
      assertEquals(ids.full5, sdk.current(APP_ID)?.context?.releaseId)
      val phases = JSONArray().put(
        evidencePhase(
          root,
          sdk,
          "held-A-released-after-B",
          "B",
          listOf("A-stale-identity-rejected", "B-state-byte-identical", "B-current-unchanged"),
        ),
      )
      writeEvidence(
        "02-held-identity-flow.json",
        "held A response fails after B sync and cannot change B state",
        phases,
        listOf("captured-A-response", "B-completed-first", "old-write-rejected", "no-device"),
      )
    } finally {
      runCatching { control("release-delays") }
      worker.shutdownNow()
    }
  }

  @Test
  fun `candidate stays staged until explicit SDK health confirmation then logout and incompatibility reject it`() {
    val ids = releaseIds()
    val root = temporaryFolder.newFolder("candidate-protocol")
    newSdk(root, userId = USER_A, candidateEnabled = false).syncLatestBundleList(APP_ID)

    control("stage", json("stage", "gray6"))
    val candidateSdk = newSdk(root, userId = USER_A, candidateEnabled = true)
    val phases = JSONArray()
    val staged = candidateSdk.syncLatestBundleList(APP_ID)
    assertEquals(OtaModels.UpdateResultType.CANDIDATE, staged.type)
    assertEquals(ids.full5, candidateSdk.current(APP_ID)?.context?.releaseId)
    assertEquals(ids.gray6, candidateSdk.candidate(APP_ID)?.release?.context?.releaseId)
    assertEquals(OtaModels.CandidateStatus.PENDING, candidateSdk.candidate(APP_ID)?.status)
    phases.put(evidencePhase(root, candidateSdk, "candidate-staged", "A", listOf("current-full5", "candidate-gray6-pending"), candidateSdk))

    val epoch = candidateSdk.userIdentityEpoch
    val lease = candidateSdk.acquireCandidateTrialBundleLease(APP_ID, CHANGED_BUNDLE)
    assertNotNull(lease)
    val trialLease = requireNotNull(lease)
    try {
      assertEquals(ids.gray6, trialLease.release.context.releaseId)
      assertTrue(trialLease.file.isFile)
      assertEquals(OtaModels.CandidateStatus.TRIAL, candidateSdk.candidate(APP_ID)?.status)
      phases.put(evidencePhase(root, candidateSdk, "candidate-trial-lease", "A", listOf("lease-readable", "candidate-trial"), candidateSdk))
      // 仅模拟 SDK 健康确认；这不是 Lynx UI 首屏或设备运行证明。
      val promoted = candidateSdk.confirmCandidateHealthy(APP_ID, trialLease.release.context.releaseId, epoch)
      assertEquals(ids.gray6, promoted.context.releaseId)
      assertEquals(ids.gray6, candidateSdk.current(APP_ID)?.context?.releaseId)
      assertNull(candidateSdk.candidate(APP_ID))
      phases.put(evidencePhase(root, candidateSdk, "candidate-sdk-health-confirmed", "A", listOf("explicit-sdk-confirm", "current-gray6", "not-ui-first-screen"), candidateSdk))
    } finally {
      trialLease.close()
    }

    assertTrue(candidateSdk.registerUserId(null))
    candidateSdk.reconcileUserContext()
    assertEquals(ids.full5, candidateSdk.current(APP_ID)?.context?.releaseId)
    candidateSdk.syncLatestBundleList(APP_ID)
    assertEquals(ids.full5, candidateSdk.current(APP_ID)?.context?.releaseId)
    phases.put(evidencePhase(root, candidateSdk, "logout-full5", "anonymous", listOf("gray-not-reused-after-logout")))

    val incompatible = newSdk(root, userId = USER_A, versionCode = "1000")
    incompatible.reconcileUserContext()
    val rejected = incompatible.syncLatestBundleList(APP_ID)
    assertEquals(OtaModels.UpdateResultType.NO_RELEASE, rejected.type)
    assertNull(incompatible.current(APP_ID))
    phases.put(evidencePhase(root, incompatible, "incompatible-version-code", "A", listOf("version-code-1000-rejected", "effective-current-null")))
    writeEvidence(
      "03-candidate-protocol-flow.json",
      "candidate stays staged until explicit SDK health confirmation then logout and incompatibility reject it",
      phases,
      listOf("candidate-not-current-before-confirm", "explicit-sdk-health-confirm-only", "logout-isolated", "compatibility-fail-closed", "no-device"),
    )
  }

  private fun newSdk(
    root: File,
    userId: String?,
    candidateEnabled: Boolean = false,
    versionCode: String = "1",
  ): OtaSdk = OtaSdk(
    OtaModels.Configuration(
      apiBaseUri = origin,
      hostApp = OtaModels.HostApp.CAPP,
      lynxAppId = APP_ID,
      environment = OtaModels.Environment.TEST,
      platform = OtaModels.Platform.ANDROID,
      appVersion = "1.0.0",
      buildNumber = "1",
      userId = userId,
      deviceId = null,
      deviceModel = null,
      osVersion = null,
      channel = null,
      region = null,
      nativeProtocolVersion = null,
      lynxSdkVersion = "4.1.0",
      otaClientToken = CLIENT_TOKEN,
      storageDirectory = root,
      candidateActivationEnabled = candidateEnabled,
      storeVersion = OtaModels.StoreVersion.V3,
      allowLocalHTTPForTest = true,
      versionCode = versionCode,
    ),
  )

  private fun releaseIds(): ReleaseIds {
    val ids = control("state").getJSONObject("actualReleaseIds")
    return ReleaseIds(
      full5 = ids.getString("full5"),
      gray6 = ids.getString("gray6"),
      full7 = ids.getString("full7"),
      gray8 = ids.getString("gray8"),
    )
  }

  private fun appSnapshot(root: File) = com.ota.android.sdk.OtaStorageDiagnostics(
    root,
    storeVersion = OtaModels.StoreVersion.V3,
  ).snapshot().apps.single { it.appId == APP_ID }

  private fun stateFile(root: File): File = root.resolve("apps/$APP_ID/state.json")

  private fun casObjectFile(root: File, sha256: String): File {
    val hash = sha256.removePrefix("sha256:")
    require(Regex("^[0-9a-f]{64}$").matches(hash)) { "fixture marker SHA-256 不合法" }
    return root.resolve("apps/$APP_ID/objects/${hash.take(2)}/$hash.lynx.bundle")
  }

  private fun lastDecisionReason(root: File): String? {
    val state = JSONObject(stateFile(root).readText())
    return state.optJSONObject("lastDecision")?.optString("reason")
  }

  private fun lastDecisionAction(root: File): String? {
    val state = JSONObject(stateFile(root).readText())
    return state.optJSONObject("lastDecision")?.optString("action")
  }

  private fun lastDecisionRevision(root: File): String? {
    val state = JSONObject(stateFile(root).readText())
    return state.optJSONObject("lastDecision")?.optString("policyRevision")
  }

  private fun evidencePhase(
    root: File,
    sdk: OtaSdk,
    phase: String,
    audience: String,
    assertions: List<String>,
    candidateSdk: OtaSdk? = null,
  ): JSONObject {
    val current = sdk.current(APP_ID)
    val candidate = candidateSdk?.candidate(APP_ID)
    val metrics = metrics()
    val server = control("state")
    return JSONObject()
      .put("phase", phase)
      .put("audience", audience)
      .put("serverStage", server.getString("stage"))
      .put("currentReleaseId", current?.context?.releaseId ?: JSONObject.NULL)
      .put("selectionKind", current?.selection?.kind?.wireValue ?: JSONObject.NULL)
      .put("policyRevision", current?.selection?.policyRevision ?: lastDecisionRevision(root) ?: JSONObject.NULL)
      .put("candidateReleaseId", candidate?.release?.context?.releaseId ?: JSONObject.NULL)
      .put("candidateStatus", candidate?.status?.wireValue ?: JSONObject.NULL)
      .put("casObjectCount", appSnapshot(root).objectCount)
      .put("latestCompletedCount", metrics.getInt("latestCompletedCount"))
      .put("bundleRequestCount", metrics.getInt("bundleRequestCount"))
      .put("bundleSuccessCount", metrics.getInt("bundleSuccessCount"))
      .put("assertions", JSONArray(assertions))
  }

  private fun writeEvidence(fileName: String, testName: String, phases: JSONArray, assertions: List<String>) {
    val configured = System.getenv(EVIDENCE_DIRECTORY_ENV)?.trim().orEmpty()
    if (configured.isEmpty()) return
    val directory = File(configured).canonicalFile
    check((directory.isDirectory || directory.mkdirs()) && directory.isDirectory) {
      "$EVIDENCE_DIRECTORY_ENV 不是可写任务目录：$directory"
    }
    val payload = JSONObject()
      .put("schemaVersion", 1)
      .put("evidenceKind", "desktop-sdk-real-server")
      .put("testName", testName)
      .put("serverOrigin", origin.toString())
      .put("platform", "android")
      .put("storeVersion", "v3")
      .put("deviceTested", false)
      .put("screenshots", JSONArray())
      .put("phases", phases)
      .put("assertions", JSONArray(assertions))
    val target = directory.resolve(fileName)
    target.writeText(payload.toString(2) + "\n", Charsets.UTF_8)
    println("OTA_USER_GRAY_EVIDENCE file=${target.absolutePath} kind=desktop-sdk-real-server deviceTested=false")
  }

  private fun awaitPendingLatest() {
    repeat(200) {
      if (metrics().getInt("pendingLatestCount") == 1) return
      Thread.sleep(10)
    }
    fail("A 请求没有进入真实 Server 的捕获后延迟队列")
  }

  private fun metrics(): JSONObject = control("metrics")

  private fun control(path: String, body: JSONObject? = null): JSONObject {
    val connection = origin.resolve("/_fixture/$path").toURL().openConnection() as HttpURLConnection
    try {
      connection.requestMethod = if (body == null && path in setOf("state", "metrics")) "GET" else "POST"
      connection.connectTimeout = 5_000
      connection.readTimeout = 35_000
      connection.setRequestProperty(CONTROL_HEADER, CONTROL_VALUE)
      if (connection.requestMethod == "POST") {
        connection.doOutput = true
        connection.setRequestProperty("content-type", "application/json")
        connection.outputStream.use { it.write((body ?: JSONObject()).toString().toByteArray(Charsets.UTF_8)) }
      }
      val status = connection.responseCode
      val stream = if (status in 200..299) connection.inputStream else connection.errorStream
      val response = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty()
      assertTrue("fixture control $path 返回 $status: $response", status in 200..299)
      return JSONObject(response)
    } finally {
      connection.disconnect()
    }
  }

  private fun json(vararg pairs: Any?): JSONObject {
    require(pairs.size % 2 == 0)
    return JSONObject().also { value ->
      pairs.toList().chunked(2).forEach { (key, item) -> value.put(key as String, item) }
    }
  }

  private fun expectSdkCode(code: String, operation: () -> Any?) {
    try {
      operation()
      fail("expected $code")
    } catch (error: Throwable) {
      val cause = if (error is ExecutionException) error.cause else error
      assertEquals(code, (cause as? OtaSdkException)?.reasonCode)
    }
  }

  private data class ReleaseIds(
    val full5: String,
    val gray6: String,
    val full7: String,
    val gray8: String,
  )

  private companion object {
    const val SERVER_ORIGIN_ENV = "OTA_USER_GRAY_SERVER_ORIGIN"
    const val EVIDENCE_DIRECTORY_ENV = "OTA_USER_GRAY_EVIDENCE_DIR"
    const val CLIENT_TOKEN = "ota-user-gray-local-client-token"
    const val CONTROL_HEADER = "x-ota-fixture-control"
    const val CONTROL_VALUE = "local-fixture-only"
    const val APP_ID = "10000001"
    const val USER_A = "user_demo_A"
    const val USER_B = "user_demo_B"
    const val CHANGED_BUNDLE = "pages/10000001/bundle-050.lynx.bundle"
  }
}
