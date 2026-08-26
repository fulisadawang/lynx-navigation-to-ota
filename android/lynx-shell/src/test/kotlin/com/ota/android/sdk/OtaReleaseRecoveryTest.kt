package com.ota.android.sdk

import java.io.File
import java.time.Instant
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class OtaReleaseRecoveryTest {
  @get:Rule
  val temporaryFolder = TemporaryFolder()

  private val scope = ReleaseTransaction.ReleaseScope(
    OtaModels.Environment.TEST,
    OtaModels.HostApp.CAPP,
    APP_ID,
    OtaModels.Platform.ANDROID,
  )

  @Test
  fun `published releases roll back to their direct predecessor`() {
    val source = fixtureFile("release-chain.lynx.bundle", "embedded baseline")
    val artifact = artifactFor(source)
    val transaction = transaction("release-chain")
    transaction.registerEmbeddedRelease(embeddedRelease("embedded-r1", source, artifact.bundleSha256))

    assertEquals(
      ReleaseTransaction.InstallResultType.UPDATED,
      transaction.install(scope, manifest("downloaded-r2", artifact)).type,
    )
    assertEquals(
      ReleaseTransaction.InstallResultType.UPDATED,
      transaction.install(scope, manifest("downloaded-r3", artifact)).type,
    )
    assertEquals("downloaded-r3", transaction.current(scope)?.context?.releaseId)

    val rollback = transaction.rollbackOutcome(scope)

    assertEquals("downloaded-r3", rollback.fromReleaseId)
    assertEquals("downloaded-r2", rollback.toReleaseId)
    assertEquals("downloaded-r2", transaction.current(scope)?.context?.releaseId)
  }

  @Test
  fun `changed current bundle fingerprint cannot be resolved from cached verification`() {
    val source = fixtureFile("cache-source.lynx.bundle", "verified bundle")
    val artifact = artifactFor(source)
    val transaction = transaction("validation-cache")
    transaction.registerEmbeddedRelease(embeddedRelease("embedded-r1", source, artifact.bundleSha256))
    transaction.install(scope, manifest("downloaded-r2", artifact))
    val current = transaction.ensureBundleReady(scope, BUNDLE_PATH)
    val originalModifiedAt = current.lastModified()

    current.writeBytes("tampered bundle".toByteArray())
    assertTrue(current.setLastModified(originalModifiedAt + 2_000L))
    assertTrue("test fixture must change the cached file fingerprint", current.lastModified() != originalModifiedAt)

    assertNull(transaction.currentBundle(scope, BUNDLE_PATH))
  }

  @Test
  fun `corrupted downloaded current rolls back to the verified embedded baseline`() {
    val payload = "embedded bundle".toByteArray()
    val source = fixtureFile("fallback-source.lynx.bundle", "embedded bundle")
    val artifact = artifactFor(source)
    val transaction = transaction("embedded-fallback")
    transaction.registerEmbeddedRelease(embeddedRelease("embedded-r1", source, artifact.bundleSha256))
    transaction.install(scope, manifest("downloaded-r2", artifact))
    val downloaded = transaction.ensureBundleReady(scope, BUNDLE_PATH)

    downloaded.writeBytes("corrupted bundle".toByteArray())

    val restored = transaction.rollback(scope)
    val fallback = transaction.ensureBundleReady(scope, BUNDLE_PATH)

    assertEquals("embedded-r1", restored?.context?.releaseId)
    assertEquals("embedded-r1", transaction.current(scope)?.context?.releaseId)
    assertArrayEquals(payload, fallback.readBytes())
  }

  private fun transaction(directoryName: String): ReleaseTransaction =
    ReleaseTransaction(temporaryFolder.newFolder(directoryName))

  private fun fixtureFile(name: String, content: String): File =
    temporaryFolder.newFile(name).also { it.writeText(content) }

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
