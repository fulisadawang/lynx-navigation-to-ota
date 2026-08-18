package com.ota.android.sdk

import java.io.File
import java.io.FileOutputStream
import java.net.URI
import java.security.MessageDigest
import java.time.Instant
import java.util.concurrent.atomic.AtomicInteger
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * OTA 下载入口的回归门：真实远程来源只能是 HTTPS；测试中的本地文件仅用于已验证
 * bundle 的 copy-and-hash 路径，绝不作为远程下载协议的替代。
 */
class OtaReleaseSecurityGateTest {
  @get:Rule
  val temporaryFolder = TemporaryFolder()

  private val scope: ReleaseTransaction.ReleaseScope
    get() = ReleaseTransaction.ReleaseScope(
      OtaModels.Environment.TEST,
      OtaModels.HostApp.CAPP,
      APP_ID,
      OtaModels.Platform.ANDROID,
    )

  @After
  fun clearInterruptFlag() {
    Thread.interrupted()
  }

  @Test
  fun configurationRejectsHttpApiBaseUrl() {
    val error = assertFailure {
      configuration(temporaryFolder.newFolder("http-api"), URI.create("http://ota.invalid"))
    }

    assertNotNull(error)
  }

  @Test
  fun transactionRejectsHttpBundleUrlBeforeOpeningTheLocalFixtureServer() {
    val payload = "http-bundle-must-not-download".toByteArray()
    LocalHttpFixture(payload).use { fixture ->
      val transaction = transaction("http-bundle")

      val error = assertFailure {
        transaction.install(scope, manifest("http-bundle", activeArtifact(fixture.uri, payload)))
      }

      assertNotNull(error)
      assertEquals("HTTP bundle URL must be rejected before a request is opened", 0, fixture.requestCount.get())
      assertNull(transaction.current(scope))
    }
  }

  @Test
  fun streamingAcceptsExactly20MiBAndRejects20MiBPlusOne() {
    val exactDestination = temporaryFolder.newFile("exact-20m.lynx.bundle")
    val exact = OtaIO.writeAndHash(RepeatingInputStream(MAX_BUNDLE_BYTES), exactDestination)

    assertEquals(MAX_BUNDLE_BYTES.toLong(), exact.bytes)
    assertEquals(MAX_BUNDLE_BYTES.toLong(), exactDestination.length())

    val oversizedDestination = temporaryFolder.newFile("oversized-20m.lynx.bundle")
    val error = assertFailure {
      OtaIO.writeAndHash(RepeatingInputStream(MAX_BUNDLE_BYTES + 1), oversizedDestination)
    }

    assertNotNull(error)
    assertTrue("oversized stream must not be retained", !oversizedDestination.exists() || oversizedDestination.length() <= MAX_BUNDLE_BYTES)
  }

  @Test
  fun transactionRejectsMissingInvalidAndOversizedDeclaredSize() {
    val exactSource = repeatedFile("size-source.lynx.bundle", MAX_BUNDLE_BYTES, 0x2A)
    val exactSha = OtaIO.sha256(exactSource)
    val cases = listOf<Int?>(null, 0, MAX_BUNDLE_BYTES + 1)

    cases.forEachIndexed { index, declaredSize ->
      val transaction = transaction("declared-size-$index")
      val artifact = OtaModels.BundleArtifact(
        PAGE_ID,
        BUNDLE_PATH,
        exactSha,
        exactSource.toURI(),
        declaredSize,
      )

      val error = assertFailure {
        transaction.install(scope, manifest("invalid-size-$index", artifact))
      }

      assertNotNull(error)
      assertNull("invalid declared size must not update current", transaction.current(scope))
    }
  }

  @Test
  fun activeLatestReleaseIsAcceptedViaVerifiedLocalReuse() {
    val source = repeatedFile("active-source.lynx.bundle", 1024, 0x41)
    val artifact = activeArtifact(URI.create("https://cdn.invalid/$BUNDLE_PATH"), source.readBytes())
    val api = FakeLatestApi(latest("active-r2", OtaModels.ReleaseStatus.ACTIVE, artifact))
    val sdk = OtaSdk(configuration(temporaryFolder.newFolder("active-sdk")), api)

    sdk.initializeEmbeddedRelease(embeddedRelease("embedded-r1", source, artifact.bundleSha256))
    val result = sdk.syncLatestBundleList(APP_ID)

    assertEquals(OtaModels.UpdateResultType.UPDATED, result.type)
    assertEquals("active-r2", sdk.current(APP_ID)?.context?.releaseId)
  }

  @Test
  fun disabledAndRolledBackLatestReleasesAreSkippedWithoutChangingCurrent() {
    val source = repeatedFile("status-source.lynx.bundle", 1024, 0x52)
    val artifact = activeArtifact(URI.create("https://cdn.invalid/$BUNDLE_PATH"), source.readBytes())
    val api = FakeLatestApi(latest("active-r2", OtaModels.ReleaseStatus.ACTIVE, artifact))
    val sdk = OtaSdk(configuration(temporaryFolder.newFolder("status-sdk")), api)
    sdk.initializeEmbeddedRelease(embeddedRelease("embedded-r1", source, artifact.bundleSha256))
    sdk.syncLatestBundleList(APP_ID)

    for (status in listOf(OtaModels.ReleaseStatus.DISABLED, OtaModels.ReleaseStatus.ROLLED_BACK)) {
      api.latest = latest("$status-r3", status, artifact)

      val result = sdk.syncLatestBundleList(APP_ID)

      assertEquals(status.toString(), OtaModels.UpdateResultType.SKIPPED, result.type)
      assertEquals("active-r2", sdk.current(APP_ID)?.context?.releaseId)
    }
  }

  @Test
  fun transactionRejectsNonActiveManifestAndPreservesCurrent() {
    val source = repeatedFile("direct-status-source.lynx.bundle", 1024, 0x53)
    val artifact = activeArtifact(URI.create("https://cdn.invalid/$BUNDLE_PATH"), source.readBytes())
    val transaction = transaction("direct-status")
    transaction.registerEmbeddedRelease(embeddedRelease("embedded-r1", source, artifact.bundleSha256))

    val error = assertFailure {
      transaction.install(scope, manifest("disabled-r2", artifact, OtaModels.ReleaseStatus.DISABLED))
    }

    assertNotNull(error)
    assertEquals("embedded-r1", transaction.current(scope)?.context?.releaseId)
  }

  @Test
  fun localReuseCopiesTheVerifiedFileWithoutTreatingItsFileUriAsARemoteDownload() {
    val source = repeatedFile("reuse-source.lynx.bundle", 2048, 0x7E)
    val artifact = activeArtifact(URI.create("https://cdn.invalid/$BUNDLE_PATH"), source.readBytes())
    val transaction = transaction("local-reuse")
    transaction.registerEmbeddedRelease(embeddedRelease("embedded-r1", source, artifact.bundleSha256))

    val outcome = transaction.install(scope, manifest("reuse-r2", artifact))
    val installed = transaction.current(scope)

    assertEquals(ReleaseTransaction.InstallResultType.UPDATED, outcome.type)
    assertEquals(1, outcome.copiedBundleCount)
    assertEquals(0, outcome.downloadedBundleCount)
    assertEquals("reuse-r2", installed?.context?.releaseId)
    assertEquals(source.length(), transaction.ensureBundleReady(scope, BUNDLE_PATH).length())
  }

  private fun configuration(storageDirectory: File, apiBaseUri: URI = URI.create("https://ota.invalid")): OtaModels.Configuration {
    return OtaModels.Configuration(
      apiBaseUri = apiBaseUri,
      hostApp = OtaModels.HostApp.CAPP,
      lynxAppId = APP_ID,
      environment = OtaModels.Environment.TEST,
      platform = OtaModels.Platform.ANDROID,
      appVersion = null,
      buildNumber = null,
      userId = null,
      deviceId = null,
      deviceModel = null,
      osVersion = null,
      channel = null,
      region = null,
      nativeProtocolVersion = null,
      lynxSdkVersion = null,
      storageDirectory = storageDirectory,
    )
  }

  private fun transaction(directoryName: String): ReleaseTransaction {
    return ReleaseTransaction(temporaryFolder.newFolder(directoryName))
  }

  private fun manifest(
    releaseId: String,
    artifact: OtaModels.BundleArtifact,
    status: OtaModels.ReleaseStatus = OtaModels.ReleaseStatus.ACTIVE,
  ): OtaModels.ReleaseManifest = latest(releaseId, status, artifact).asManifest()

  private fun latest(
    releaseId: String,
    status: OtaModels.ReleaseStatus,
    artifact: OtaModels.BundleArtifact,
  ): OtaModels.LatestBundleList {
    return OtaModels.LatestBundleList(
      OtaModels.Environment.TEST,
      OtaModels.HostApp.CAPP,
      APP_ID,
      releaseId,
      OtaModels.Platform.ANDROID,
      listOf(OtaModels.Platform.ANDROID),
      status,
      "2026-08-18T00:00:00Z",
      null,
      null,
      null,
      null,
      listOf(artifact),
    )
  }

  private fun activeArtifact(remoteUri: URI, payload: ByteArray): OtaModels.BundleArtifact {
    return OtaModels.BundleArtifact(PAGE_ID, BUNDLE_PATH, sha256(payload), remoteUri, payload.size)
  }

  private fun embeddedRelease(releaseId: String, file: File, sha256: String): OtaModels.InstalledRelease {
    return OtaModels.InstalledRelease(
      OtaModels.CurrentReleaseContext(
        OtaModels.Environment.TEST,
        OtaModels.HostApp.CAPP,
        APP_ID,
        releaseId,
        OtaModels.Platform.ANDROID,
        OtaModels.ReleaseStatus.ACTIVE,
      ),
      Instant.EPOCH,
      listOf(OtaModels.InstalledBundle(PAGE_ID, BUNDLE_PATH, sha256, file.toURI(), file.absolutePath)),
    )
  }

  private fun repeatedFile(name: String, size: Int, value: Int): File {
    val file = temporaryFolder.newFile(name)
    FileOutputStream(file).use { output ->
      val buffer = ByteArray(64 * 1024) { value.toByte() }
      var remaining = size
      while (remaining > 0) {
        val count = minOf(buffer.size, remaining)
        output.write(buffer, 0, count)
        remaining -= count
      }
    }
    return file
  }

  private fun sha256(payload: ByteArray): String {
    val digest = MessageDigest.getInstance("SHA-256")
    return "sha256:" + digest.digest(payload).joinToString("") { "%02x".format(it) }
  }

  private fun assertFailure(block: () -> Unit): Throwable {
    try {
      block()
    } catch (error: Throwable) {
      return error
    }
    throw AssertionError("Expected OTA gate to reject the input")
  }

  private class FakeLatestApi(var latest: OtaModels.LatestBundleList) : OtaApiClient {
    override fun checkForUpdate(request: OtaModels.PolicyMatchRequest): OtaModels.PolicyMatchResponse {
      return OtaModels.PolicyMatchResponse(false, null, null, null, null, null)
    }

    override fun fetchManifest(
      releaseId: String,
      env: OtaModels.Environment,
      hostApp: OtaModels.HostApp,
      lynxAppId: String,
      platform: OtaModels.Platform,
    ): OtaModels.ReleaseManifest = throw AssertionError("latest-bundle-list tests must not fetch a manifest")

    override fun fetchLatestBundleLists(
      env: OtaModels.Environment,
      hostApp: OtaModels.HostApp,
      platform: OtaModels.Platform,
    ): OtaModels.HostLatestBundleLists {
      return OtaModels.HostLatestBundleLists(env, hostApp, platform, listOf(latest))
    }

    override fun fetchLatestBundleList(
      env: OtaModels.Environment,
      hostApp: OtaModels.HostApp,
      lynxAppId: String,
      platform: OtaModels.Platform,
    ): OtaModels.LatestBundleList = latest

    override fun reportEvent(payload: OtaModels.ReportPayload) = Unit
  }

  private class RepeatingInputStream(private var remaining: Int) : java.io.InputStream() {
    override fun read(): Int {
      if (remaining <= 0) return -1
      remaining -= 1
      return 0x5A
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
      if (remaining <= 0) return -1
      val count = minOf(length, remaining)
      buffer.fill(0x5A.toByte(), offset, offset + count)
      remaining -= count
      return count
    }
  }

  /** 本地 socket 仅用于证明 HTTP URI 在连接建立前被拒绝；不访问外部网络。 */
  private class LocalHttpFixture(private val payload: ByteArray) : AutoCloseable {
    private val server = java.net.ServerSocket(0, 1, java.net.InetAddress.getByName("127.0.0.1"))
    val requestCount = AtomicInteger()
    val uri: URI = URI.create("http://127.0.0.1:${server.localPort}/bundle.lynx.bundle")
    private val worker = Thread({
      try {
        server.accept().use { socket ->
          requestCount.incrementAndGet()
          val response = "HTTP/1.1 200 OK\r\nContent-Length: ${payload.size}\r\nConnection: close\r\n\r\n".toByteArray()
          socket.getOutputStream().use { output ->
            output.write(response)
            output.write(payload)
          }
        }
      } catch (_: java.io.IOException) {
        // close() interrupts accept when the gate correctly rejects before connecting.
      }
    }, "ota-local-http-fixture").apply {
      isDaemon = true
      start()
    }

    override fun close() {
      server.close()
      worker.join(1_000L)
    }
  }

  private companion object {
    const val APP_ID = "10000001"
    const val PAGE_ID = 1
    const val BUNDLE_PATH = "home.lynx.bundle"
    const val MAX_BUNDLE_BYTES = 20 * 1024 * 1024
  }
}
