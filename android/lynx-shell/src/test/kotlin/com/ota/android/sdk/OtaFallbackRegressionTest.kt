package com.ota.android.sdk

import java.io.File
import java.time.Instant
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class OtaFallbackRegressionTest {
  @get:Rule
  val temporaryFolder = TemporaryFolder()

  private val scope = ReleaseTransaction.ReleaseScope(
    OtaModels.Environment.TEST,
    OtaModels.HostApp.CAPP,
    APP_ID,
    OtaModels.Platform.ANDROID,
  )

  @Test
  fun `rollback skips a corrupted predecessor and restores the verified embedded baseline`() {
    val payload = "embedded bundle".toByteArray()
    val source = fixtureFile("embedded-source.lynx.bundle", payload)
    val artifact = artifactFor(source)
    val transaction = ReleaseTransaction(temporaryFolder.newFolder("corrupted-predecessor"))
    transaction.registerEmbeddedRelease(embeddedRelease("embedded-r1", source, artifact.bundleSha256))
    transaction.install(scope, manifest("downloaded-r2", artifact))
    val predecessor = transaction.ensureBundleReady(scope, BUNDLE_PATH)
    transaction.install(scope, manifest("downloaded-r3", artifact))

    predecessor.writeBytes("corrupted predecessor".toByteArray())

    val restored = transaction.rollback(scope)
    val fallback = transaction.ensureBundleReady(scope, BUNDLE_PATH)

    assertEquals("embedded-r1", restored?.context?.releaseId)
    assertEquals("embedded-r1", transaction.current(scope)?.context?.releaseId)
    assertArrayEquals(payload, fallback.readBytes())
  }

  private fun fixtureFile(name: String, content: ByteArray): File =
    temporaryFolder.newFile(name).also { it.writeBytes(content) }

  private fun artifactFor(source: File): OtaModels.BundleArtifact = OtaModels.BundleArtifact(
    PAGE_ID,
    BUNDLE_PATH,
    OtaIO.sha256(source),
    REMOTE_BUNDLE_URI,
    source.length().toInt(),
  )

  private fun manifest(
    releaseId: String,
    artifact: OtaModels.BundleArtifact,
  ): OtaModels.ReleaseManifest = OtaModels.LatestBundleList(
    OtaModels.Environment.TEST,
    OtaModels.HostApp.CAPP,
    APP_ID,
    releaseId,
    OtaModels.Platform.ANDROID,
    listOf(OtaModels.Platform.ANDROID),
    OtaModels.ReleaseStatus.ACTIVE,
    "2026-08-26T00:00:00Z",
    null,
    null,
    null,
    null,
    listOf(artifact),
  ).asManifest()

  private fun embeddedRelease(
    releaseId: String,
    source: File,
    sha256: String,
  ): OtaModels.InstalledRelease = OtaModels.InstalledRelease(
    OtaModels.CurrentReleaseContext(
      OtaModels.Environment.TEST,
      OtaModels.HostApp.CAPP,
      APP_ID,
      releaseId,
      OtaModels.Platform.ANDROID,
      OtaModels.ReleaseStatus.ACTIVE,
    ),
    Instant.EPOCH,
    listOf(OtaModels.InstalledBundle(PAGE_ID, BUNDLE_PATH, sha256, REMOTE_BUNDLE_URI, source.absolutePath)),
  )

  private companion object {
    const val APP_ID = "10000001"
    const val PAGE_ID = 1
    const val BUNDLE_PATH = "main.lynx.bundle"
    val REMOTE_BUNDLE_URI = java.net.URI.create("https://cdn.invalid/main.lynx.bundle")
  }
}
