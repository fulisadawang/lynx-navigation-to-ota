package com.ota.android.sdk

import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.File
import java.net.InetSocketAddress
import java.net.URI
import java.net.ServerSocket
import java.net.Socket
import java.nio.file.Files
import java.nio.file.attribute.BasicFileAttributes
import java.nio.charset.StandardCharsets
import java.time.Instant
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class OtaStoreV3Golden100Test {
  @get:Rule
  val temporaryFolder = TemporaryFolder()

  @Test
  fun `v1 to v2 downloads one changed bundle and stores one new CAS object`() {
    val server = GoldenBundleServer()
    server.start()
    try {
      val root = temporaryFolder.newFolder("golden-v3")
      val store = ContentAddressedOtaStore(
        root,
        allowLocalHTTPForTest = true,
        environment = OtaModels.Environment.TEST,
      )
      val scope = scope(APP_ID)

      val v1 = manifest(scope, "V1", server, changedIndex = null)
      val first = store.install(ReleaseTransaction.InstallRequest(scope, v1))
      assertEquals(100, first.downloadedBundleCount)
      assertEquals(0, first.reusedBundleCount)
      assertEquals(100, server.bundleRequests.get())
      assertEquals(100, store.storageSnapshot(5000).apps.single().objectCount)
      val unchangedFingerprints = v1.bundles
        .filter { it.bundlePath != "pages/$APP_ID/bundle-050.lynx.bundle" }
        .associate { it.bundlePath to fingerprint(root, APP_ID, it.bundleSha256) }

      val v2 = manifest(scope, "V2", server, changedIndex = 50)
      val second = store.install(ReleaseTransaction.InstallRequest(scope, v2))
      assertEquals(1, second.downloadedBundleCount)
      assertEquals(99, second.reusedBundleCount)
      assertEquals(101, server.bundleRequests.get())
      assertEquals(1, store.operationMetrics().objectWriteCount)
      assertEquals(1, store.operationMetrics().manifestWriteCount)
      unchangedFingerprints.forEach { (bundlePath, before) ->
        val artifact = v2.bundles.single { it.bundlePath == bundlePath }
        assertEquals(before, fingerprint(root, APP_ID, artifact.bundleSha256))
      }

      val app = store.storageSnapshot(5000).apps.single()
      assertEquals(101, app.objectCount)
      assertEquals(2, app.releases.size)
      assertEquals("V2", app.state?.currentReleaseId)
      assertEquals("V1", app.state?.previousReleaseId)
      assertEquals(100, app.releases.single { it.releaseId == "V1" }.bundleCount)
      assertEquals(100, app.releases.single { it.releaseId == "V2" }.bundleCount)
      assertTrue(app.releases.all { it.manifestId?.startsWith("sha256:") == true })
    } finally {
      server.close()
    }
  }

  @Test
  fun `v1 active lease survives explicit v2 delete until the lease closes`() {
    val server = GoldenBundleServer()
    server.start()
    try {
      val root = temporaryFolder.newFolder("delete-with-lease-v3")
      val store = ContentAddressedOtaStore(
        root,
        allowLocalHTTPForTest = true,
        environment = OtaModels.Environment.TEST,
      )
      val scope = scope(APP_ID)
      val v1 = manifest(scope, "V1", server, changedIndex = null)
      val v2 = manifest(scope, "V2", server, changedIndex = 50)

      store.install(ReleaseTransaction.InstallRequest(scope, v1))
      store.install(ReleaseTransaction.InstallRequest(scope, v2))

      val v1BundlePath = "pages/$APP_ID/bundle-050.lynx.bundle"
      val lease = requireNotNull(
        store.acquireBundleLeaseForRelease(scope, "V1", v1BundlePath),
      )
      try {
        assertEquals("V1", lease.release.context.releaseId)
        assertEquals("bundle-v1-50", lease.file.readText())

        store.deleteDownloadedBundles(APP_ID)

        val afterDelete = store.storageSnapshot(5000).apps.single()
        assertFalse(root.resolve("apps/$APP_ID/state.json").exists())
        assertNull(store.current(scope))
        assertNull(afterDelete.state)
        assertEquals(listOf("V1"), afterDelete.releases.map { it.releaseId })
        assertEquals(100, afterDelete.objectCount)
        assertTrue(afterDelete.manifestBytes > 0L)

        val retained = afterDelete.releases.single()
        assertEquals(setOf(OtaStorageReleaseRole.LEASED), retained.roles)
        assertEquals(100, lease.release.bundles.size)
        assertTrue(lease.file.isFile)
        assertEquals("bundle-v1-50", lease.file.readText())
      } finally {
        lease.close()
      }

      val afterClose = store.storageSnapshot(5000).apps.single()
      assertTrue(afterClose.releases.isEmpty())
      assertEquals(0, afterClose.objectCount)
      assertEquals(0L, afterClose.manifestBytes)
      assertFalse(lease.file.exists())
    } finally {
      server.close()
    }
  }

  @Test
  fun `rollback reuses previous CAS objects and app ids stay isolated`() {
    val server = GoldenBundleServer()
    server.start()
    try {
      val root = temporaryFolder.newFolder("rollback-v3")
      val store = ContentAddressedOtaStore(root, allowLocalHTTPForTest = true)
      val firstScope = scope(APP_ID)
      val secondScope = scope(SECOND_APP_ID)
      val v1 = manifest(firstScope, "V1", server, changedIndex = null)
      val v2 = manifest(firstScope, "V2", server, changedIndex = 50)
      store.install(ReleaseTransaction.InstallRequest(firstScope, v1))
      store.install(ReleaseTransaction.InstallRequest(firstScope, v2))
      val requestsBeforeRollback = server.bundleRequests.get()

      val restored = store.rollback(firstScope)
      assertEquals("V1", restored?.context?.releaseId)
      assertEquals("V1", store.current(firstScope)?.context?.releaseId)
      assertEquals(requestsBeforeRollback, server.bundleRequests.get())

      val sharedArtifact = v1.bundles.first()
      server.payloads["/SECOND/0"] = server.payloads["/V1/0"] ?: error("missing shared fixture payload")
      val secondManifest = OtaModels.ReleaseManifest(
        secondScope.env,
        secondScope.hostApp,
        secondScope.lynxAppId,
        "SECOND",
        secondScope.platform,
        listOf(secondScope.platform),
        listOf(
          OtaModels.BundleArtifact(
            sharedArtifact.pageId,
            sharedArtifact.bundlePath,
            sharedArtifact.bundleSha256,
            sharedArtifact.bundleUrl,
            sharedArtifact.size,
          ),
        ),
      )
      store.install(ReleaseTransaction.InstallRequest(secondScope, secondManifest))
      val apps = store.storageSnapshot(5000).apps.associateBy { it.appId }
      assertEquals(100, apps[APP_ID]?.objectCount)
      assertEquals(1, apps[SECOND_APP_ID]?.objectCount)
      assertEquals(1, apps[SECOND_APP_ID]?.releases?.single()?.bundleCount)
    } finally {
      server.close()
    }
  }

  @Test
  fun `candidate is durable and a manifest fault does not change current`() {
    val server = GoldenBundleServer()
    server.start()
    try {
      val root = temporaryFolder.newFolder("candidate-v3")
      val scope = scope(APP_ID)
      val v1 = manifest(scope, "V1", server, changedIndex = null)
      val v2 = manifest(scope, "V2", server, changedIndex = 50)
      val stable = ContentAddressedOtaStore(root, allowLocalHTTPForTest = true)
      stable.install(ReleaseTransaction.InstallRequest(scope, v1))

      val failing = ContentAddressedOtaStore(
        root,
        faultInjector = ContentAddressedFaultInjecting { point ->
          if (point == ContentAddressedFaultPoint.BEFORE_MANIFEST_COMMIT) error("injected manifest fault")
        },
        allowLocalHTTPForTest = true,
      )
      runCatching {
        failing.install(ReleaseTransaction.InstallRequest(scope, v2))
      }.onSuccess { error("expected manifest fault") }
      assertEquals("V1", stable.current(scope)?.context?.releaseId)

      val candidateStore = ContentAddressedOtaStore(root, allowLocalHTTPForTest = true)
      val candidate = candidateStore.install(
        ReleaseTransaction.InstallRequest(scope, v2, stageAsCandidate = true),
      )
      assertEquals(ReleaseTransaction.InstallResultType.CANDIDATE, candidate.type)
      assertEquals("V1", candidateStore.current(scope)?.context?.releaseId)
      assertEquals(OtaModels.CandidateStatus.PENDING, candidateStore.candidate(scope)?.status)
      candidateStore.beginCandidateTrial(scope)
      assertEquals(OtaModels.CandidateStatus.TRIAL, candidateStore.candidate(scope)?.status)
      candidateStore.confirmCandidate(scope)
      assertEquals("V2", candidateStore.current(scope)?.context?.releaseId)
      assertNotNull(candidateStore.currentBundle(scope, "pages/10000001/bundle-050.lynx.bundle"))
    } finally {
      server.close()
    }
  }

  private fun scope(appId: String): ReleaseTransaction.ReleaseScope = ReleaseTransaction.ReleaseScope(
    OtaModels.Environment.TEST,
    OtaModels.HostApp.CAPP,
    appId,
    OtaModels.Platform.ANDROID,
  )

  private fun manifest(
    scope: ReleaseTransaction.ReleaseScope,
    releaseId: String,
    server: GoldenBundleServer,
    changedIndex: Int?,
  ): OtaModels.ReleaseManifest {
    val bundles = (0 until 100).map { index ->
      val path = "pages/${scope.lynxAppId}/bundle-%03d.lynx.bundle".format(index)
      val payload = if (changedIndex == index) "bundle-v2-$index" else "bundle-v1-$index"
      val bytes = payload.toByteArray(StandardCharsets.UTF_8)
      server.payloads["/$releaseId/$index"] = bytes
      val source = temporaryFolder.newFile("$releaseId-$index.bundle").also { it.writeBytes(bytes) }
      OtaModels.BundleArtifact(
        pageId = index,
        bundlePath = path,
        bundleSha256 = OtaIO.sha256(source),
        bundleUrl = URI.create("http://127.0.0.1:${server.port}/$releaseId/$index"),
        size = bytes.size,
      )
    }
    return OtaModels.ReleaseManifest(
      scope.env,
      scope.hostApp,
      scope.lynxAppId,
      releaseId,
      scope.platform,
      listOf(scope.platform),
      bundles,
    )
  }

  private fun fingerprint(root: File, appId: String, objectId: String): String {
    val hex = objectId.removePrefix("sha256:")
    val file = root.resolve("apps/$appId/objects/${hex.take(2)}/$hex.lynx.bundle")
    val attributes = Files.readAttributes(file.toPath(), BasicFileAttributes::class.java)
    return listOf(
      attributes.fileKey()?.toString() ?: "no-file-key",
      attributes.size().toString(),
      attributes.lastModifiedTime().toMillis().toString(),
    ).joinToString("|")
  }

  private class GoldenBundleServer {
    val payloads = ConcurrentHashMap<String, ByteArray>()
    val bundleRequests = AtomicInteger(0)
    private var server: ServerSocket? = null
    private var worker: Thread? = null
    var port: Int = 0
      private set

    fun start() {
      server = ServerSocket().also { socket ->
        socket.bind(InetSocketAddress("127.0.0.1", 0))
        port = socket.localPort
        worker = Thread {
          while (!socket.isClosed) {
            runCatching { socket.accept() }
              .onSuccess { client -> Thread { handle(client) }.apply { isDaemon = true }.start() }
              .onFailure { if (!socket.isClosed) throw it }
          }
        }.apply { isDaemon = true; start() }
      }
    }

    fun close() {
      server?.close()
      server = null
      worker = null
    }

    private fun handle(socket: Socket) {
      socket.use { client ->
        val reader = BufferedReader(InputStreamReader(client.getInputStream(), StandardCharsets.US_ASCII))
        val requestLine = reader.readLine().orEmpty()
        while (reader.readLine()?.isNotEmpty() == true) Unit
        val path = requestLine.split(' ').getOrNull(1).orEmpty().substringBefore('?')
        val payload = payloads[path]
        if (payload == null) {
          writeResponse(client, 404, "not found".toByteArray(StandardCharsets.UTF_8))
          return
        }
        bundleRequests.incrementAndGet()
        writeResponse(client, 200, payload)
      }
    }

    private fun writeResponse(socket: Socket, statusCode: Int, body: ByteArray) {
      val reason = if (statusCode == 200) "OK" else "Not Found"
      val header = "HTTP/1.1 $statusCode $reason\r\n" +
        "Content-Type: application/octet-stream\r\n" +
        "Content-Length: ${body.size}\r\n" +
        "Connection: close\r\n\r\n"
      socket.getOutputStream().use { output ->
        output.write(header.toByteArray(StandardCharsets.US_ASCII))
        output.write(body)
        output.flush()
      }
    }
  }

  private companion object {
    const val APP_ID = "10000001"
    const val SECOND_APP_ID = "10000002"
  }
}
