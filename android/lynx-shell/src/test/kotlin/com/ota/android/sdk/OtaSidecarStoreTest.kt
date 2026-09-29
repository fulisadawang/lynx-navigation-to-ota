package com.ota.android.sdk

import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URI
import java.security.MessageDigest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class OtaSidecarStoreTest {
  @get:Rule val temporary = TemporaryFolder()

  @Test fun stagesAsyncBytesAndKeepsOldPageLease() {
    val server = SidecarFixtureServer()
    val base = server.base
    val main = "main-bundle".toByteArray()
    val next = "next-bundle".toByteArray()
    val later = "later-bundle".toByteArray()
    val lazy = "lazy-bundle".toByteArray()
    val image = "png-bytes".toByteArray()
    val entries = listOf(
      OtaSidecarModels.AsyncEntry("HomePage.lynx.bundle", "/lazy-bundle/panel.bundle", "lazy-bundle/panel.bundle",
        URI.create("$base/lazy"), sha(lazy), lazy.size, OtaSidecarModels.AsyncKind.BUNDLE),
      OtaSidecarModels.AsyncEntry("HomePage.lynx.bundle", "/static/image/panel.png", "static/image/panel.png",
        URI.create("$base/image"), sha(image), image.size, OtaSidecarModels.AsyncKind.ASSET),
    )
    val asyncBytes = OtaJson.stringify(OtaSidecarModels.AsyncManifest(1, entries).toJsonMap()).toByteArray()
    val ref = OtaSidecarModels.AsyncManifestRef(1, URI.create("$base/async"), sha(asyncBytes), asyncBytes.size)
    server.bodies.putAll(mapOf(
      "/main" to main, "/next" to next, "/later" to later, "/lazy" to lazy,
      "/image" to image, "/async" to asyncBytes,
    ))
    try {
      val storeRoot = temporary.newFolder("ota")
      val store = ContentAddressedOtaStore(storeRoot, allowLocalHTTPForTest = true)
      val first = release("r1", "$base/main", main, ref)
      val scope = ReleaseTransaction.ReleaseScope.fromManifest(first)
      store.reserveSidecars("10020000", ref).use {
        store.stageAsyncResources(first)
        store.install(ReleaseTransaction.InstallRequest(scope, first))
      }
      val lease = store.acquireCurrentBundleLease(scope, "HomePage.lynx.bundle")
      assertNotNull(lease)
      val resources = requireNotNull(lease).sidecars!!
      assertEquals(lazy.toList(), resources.resource("/lazy-bundle/panel.bundle")!!.file.readBytes().toList())
      assertEquals(image.toList(), resources.resource("webpack:///static/image/panel.png")!!.file.readBytes().toList())

      val second = release("r2", "$base/next", next)
      store.install(ReleaseTransaction.InstallRequest(scope, second))
      val third = release("r3", "$base/later", later)
      store.install(ReleaseTransaction.InstallRequest(scope, third))
      assertTrue(resources.resource("/lazy-bundle/panel.bundle")!!.file.isFile)
      lease.close()
      store.pruneAllUnreferencedReleases()
      assertFalse(resources.resource("/lazy-bundle/panel.bundle")!!.file.exists())
    } finally {
      server.close()
    }
  }

  @Test fun missingAsyncObjectMakesCurrentUnavailable() {
    val server = SidecarFixtureServer()
    val base = server.base
    val main = "main-bundle".toByteArray()
    val lazy = "lazy-bundle".toByteArray()
    val entry = OtaSidecarModels.AsyncEntry("HomePage.lynx.bundle", "/lazy-bundle/panel.bundle", "lazy-bundle/panel.bundle",
      URI.create("$base/lazy"), sha(lazy), lazy.size, OtaSidecarModels.AsyncKind.BUNDLE)
    val bytes = OtaJson.stringify(OtaSidecarModels.AsyncManifest(1, listOf(entry)).toJsonMap()).toByteArray()
    server.bodies.putAll(mapOf("/main" to main, "/lazy" to lazy, "/async" to bytes))
    try {
      val root = temporary.newFolder("ota")
      val store = ContentAddressedOtaStore(root, allowLocalHTTPForTest = true)
      val ref = OtaSidecarModels.AsyncManifestRef(1, URI.create("$base/async"), sha(bytes), bytes.size)
      val manifest = release("r1", "$base/main", main, ref)
      val scope = ReleaseTransaction.ReleaseScope.fromManifest(manifest)
      store.reserveSidecars("10020000", ref).use {
        store.stageAsyncResources(manifest)
        store.install(ReleaseTransaction.InstallRequest(scope, manifest))
      }
      val lease = requireNotNull(store.acquireCurrentBundleLease(scope, "HomePage.lynx.bundle"))
      val lazyFile = lease.sidecars!!.resource("/lazy-bundle/panel.bundle")!!.file
      lease.close()
      val priorModified = lazyFile.lastModified()
      lazyFile.writeBytes(ByteArray(lazy.size) { 0x41 })
      assertTrue(lazyFile.setLastModified(priorModified))
      assertNull(store.current(scope))
      val orphan = root.resolve("apps/10020000/async-bundles/objects/ff/orphan")
      orphan.parentFile!!.mkdirs()
      orphan.writeText("keep until roots recover")
      store.pruneAllUnreferencedReleases()
      assertTrue(orphan.exists())
    } finally {
      server.close()
    }
  }

  @Test fun sameLengthAndMtimeMainTamperFailsCurrentValidation() {
    val server = SidecarFixtureServer()
    val base = server.base
    val bytes = "main-bundle".toByteArray()
    server.bodies["/main"] = bytes
    try {
      val store = ContentAddressedOtaStore(temporary.newFolder("ota"), allowLocalHTTPForTest = true)
      val manifest = release("r1", "$base/main", bytes)
      val scope = ReleaseTransaction.ReleaseScope.fromManifest(manifest)
      store.install(ReleaseTransaction.InstallRequest(scope, manifest))
      val lease = requireNotNull(store.acquireCurrentBundleLease(scope, "HomePage.lynx.bundle"))
      val file = lease.file
      lease.close()
      val priorModified = file.lastModified()
      file.writeBytes(ByteArray(bytes.size) { 0x42 })
      assertTrue(file.setLastModified(priorModified))
      assertNull(store.current(scope))
    } finally {
      server.close()
    }
  }

  @Test fun resourceCapabilityHeaderIsSentOnlyByV3AwareApiClient() {
    val server = SidecarFixtureServer()
    val response = "{}".toByteArray()
    val paths = listOf(
      "/api/ota/v1/releases/latest-bundle-list",
      "/api/ota/v1/policy/match",
      "/api/ota/v1/release/fixture/manifest",
    )
    paths.forEach { server.bodies[it] = response }
    try {
      val client = OtaApiClient.server(URI.create(server.base), "test-token", OtaModels.Environment.TEST, true, true)
      runCatching { client.fetchLatestBundleList(OtaModels.Environment.TEST, OtaModels.HostApp.TEMPLATE,
        "10020000", OtaModels.Platform.ANDROID) }
      runCatching { client.checkForUpdate(OtaModels.PolicyMatchRequest(
        OtaModels.Environment.TEST, OtaModels.HostApp.TEMPLATE, "10020000", OtaModels.Platform.ANDROID,
        "1.0", "1", null, null, null, null, null, 1, null, "4.1.0")) }
      runCatching { client.fetchManifest("fixture", OtaModels.Environment.TEST, OtaModels.HostApp.TEMPLATE,
        "10020000", OtaModels.Platform.ANDROID) }
      for (path in paths) {
        assertEquals("1", server.headersByPath[path]?.get(OtaApiClient.RESOURCE_SCHEMA_HEADER))
      }

      val legacy = OtaApiClient.server(URI.create(server.base), "test-token", OtaModels.Environment.TEST, true)
      runCatching { legacy.fetchLatestBundleList(OtaModels.Environment.TEST, OtaModels.HostApp.TEMPLATE,
        "10020000", OtaModels.Platform.ANDROID) }
      assertNull(server.headersByPath[paths[0]]?.get(OtaApiClient.RESOURCE_SCHEMA_HEADER))
    } finally {
      server.close()
    }
  }

  private fun release(id: String, url: String, bytes: ByteArray,
    ref: OtaSidecarModels.AsyncManifestRef? = null): OtaModels.ReleaseManifest = OtaModels.ReleaseManifest(
    OtaModels.Environment.TEST, OtaModels.HostApp.TEMPLATE, "10020000", id,
    OtaModels.Platform.ANDROID, listOf(OtaModels.Platform.ANDROID), listOf(
      OtaModels.BundleArtifact(1, "HomePage.lynx.bundle", sha(bytes), URI.create(url), bytes.size)),
    OtaModels.ReleaseStatus.ACTIVE, ref,
  )

  private fun sha(bytes: ByteArray): String = "sha256:" + MessageDigest.getInstance("SHA-256")
    .digest(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }
}

private class SidecarFixtureServer : AutoCloseable {
  private val socket = ServerSocket(0, 10, InetAddress.getByName("127.0.0.1"))
  val base = "http://127.0.0.1:${socket.localPort}"
  val bodies = java.util.concurrent.ConcurrentHashMap<String, ByteArray>()
  val headersByPath = java.util.concurrent.ConcurrentHashMap<String, Map<String, String>>()
  private val worker = Thread {
    while (!socket.isClosed) {
      val client = runCatching { socket.accept() }.getOrNull() ?: break
      runCatching { handle(client) }
    }
  }.apply { isDaemon = true; start() }

  private fun handle(client: Socket) {
    client.use { connection ->
      val reader = connection.getInputStream().bufferedReader(Charsets.US_ASCII)
      val line = reader.readLine().orEmpty()
      val path = line.split(' ').getOrNull(1).orEmpty().substringBefore('?')
      val headers = linkedMapOf<String, String>()
      while (true) {
        val header = reader.readLine() ?: break
        if (header.isEmpty()) break
        val separator = header.indexOf(':')
        if (separator > 0) headers[header.substring(0, separator).lowercase()] = header.substring(separator + 1).trim()
      }
      headersByPath[path] = headers
      val data = bodies[path]
      val code = if (data == null) 404 else 200
      val body = data ?: "missing".toByteArray()
      val header = "HTTP/1.1 $code ${if (code == 200) "OK" else "Not Found"}\r\n" +
        "Content-Length: ${body.size}\r\nConnection: close\r\n\r\n"
      connection.getOutputStream().use { output ->
        output.write(header.toByteArray(Charsets.US_ASCII))
        output.write(body)
        output.flush()
      }
    }
  }

  override fun close() {
    socket.close()
    worker.join(1000)
  }
}
