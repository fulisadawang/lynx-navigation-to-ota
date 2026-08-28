package com.ota.android.sdk

import java.io.File
import java.net.URI
import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class OtaReleaseLeaseTest {
  @get:Rule
  val temporaryFolder = TemporaryFolder()

  @Test
  fun `active page lease retains old release until page closes`() {
    val fixture = fixture("lease-navigation-stack")
    fixture.transaction.install(fixture.scope, fixture.manifest("V1"))
    val lease = fixture.transaction.acquireCurrentBundleLease(fixture.scope, BUNDLE_PATH)
    assertNotNull(lease)

    fixture.transaction.install(fixture.scope, fixture.manifest("V2"))
    fixture.transaction.install(fixture.scope, fixture.manifest("V3"))

    assertEquals("V1", lease!!.release.context.releaseId)
    assertTrue(fixture.releaseDirectory("V1").isDirectory)
    assertTrue(lease.file.isFile)

    lease.close()

    assertFalse(fixture.releaseDirectory("V1").exists())
    assertEquals(setOf("V2", "V3"), fixture.releaseNames())
  }

  @Test
  fun `explicit delete defers leased release deletion until final close`() {
    val fixture = fixture("lease-explicit-delete")
    fixture.transaction.install(fixture.scope, fixture.manifest("V1"))
    val lease = requireNotNull(
      fixture.transaction.acquireCurrentBundleLease(fixture.scope, BUNDLE_PATH),
    )

    fixture.transaction.deleteDownloadedBundles(APP_ID)

    assertFalse(fixture.root.resolve("apps/$APP_ID/state.json").exists())
    assertTrue(fixture.releaseDirectory("V1").isDirectory)
    assertEquals("payload", lease.file.readText())

    lease.close()
    lease.close()

    assertFalse(fixture.releaseDirectory("V1").exists())
  }

  @Test
  fun `discarded candidate is retained only while its trial page is alive`() {
    val fixture = fixture("lease-candidate")
    fixture.transaction.install(fixture.scope, fixture.manifest("V1"))
    fixture.transaction.install(
      ReleaseTransaction.InstallRequest(
        scope = fixture.scope,
        targetManifest = fixture.manifest("V2"),
        stageAsCandidate = true,
      ),
    )
    val lease = requireNotNull(
      fixture.transaction.acquireCandidateBundleLease(fixture.scope, BUNDLE_PATH),
    )

    fixture.transaction.discardCandidate(fixture.scope)

    assertFalse(fixture.root.resolve("apps/$APP_ID/candidate.json").exists())
    assertTrue(fixture.releaseDirectory("V2").isDirectory)
    assertEquals(setOf("V1", "V2"), fixture.releaseNames())

    lease.close()

    assertFalse(fixture.releaseDirectory("V2").exists())
    assertEquals(setOf("V1"), fixture.releaseNames())
  }

  private fun fixture(name: String): Fixture {
    val root = temporaryFolder.newFolder(name)
    val source = temporaryFolder.newFile("$name.lynx.bundle").also { it.writeText("payload") }
    val scope = ReleaseTransaction.ReleaseScope(
      OtaModels.Environment.TEST,
      OtaModels.HostApp.CAPP,
      APP_ID,
      OtaModels.Platform.ANDROID,
    )
    val artifact = OtaModels.BundleArtifact(
      PAGE_ID,
      BUNDLE_PATH,
      OtaIO.sha256(source),
      REMOTE_BUNDLE_URI,
      source.length().toInt(),
    )
    val embedded = OtaModels.InstalledRelease(
      OtaModels.CurrentReleaseContext(
        scope.env,
        scope.hostApp,
        scope.lynxAppId,
        "embedded",
        scope.platform,
        OtaModels.ReleaseStatus.ACTIVE,
      ),
      Instant.EPOCH,
      listOf(
        OtaModels.InstalledBundle(
          PAGE_ID,
          BUNDLE_PATH,
          artifact.bundleSha256,
          REMOTE_BUNDLE_URI,
          source.absolutePath,
        ),
      ),
    )
    val transaction = ReleaseTransaction(root)
    transaction.registerEmbeddedRelease(embedded)
    return Fixture(root, transaction, scope, artifact)
  }

  private data class Fixture(
    val root: File,
    val transaction: ReleaseTransaction,
    val scope: ReleaseTransaction.ReleaseScope,
    val artifact: OtaModels.BundleArtifact,
  ) {
    fun manifest(releaseId: String): OtaModels.ReleaseManifest = OtaModels.LatestBundleList(
      scope.env,
      scope.hostApp,
      scope.lynxAppId,
      releaseId,
      scope.platform,
      listOf(scope.platform),
      OtaModels.ReleaseStatus.ACTIVE,
      "2026-08-27T00:00:00Z",
      null,
      null,
      null,
      null,
      listOf(artifact),
    ).asManifest()

    fun releaseDirectory(releaseId: String): File =
      root.resolve("apps/${scope.lynxAppId}/releases/$releaseId")

    fun releaseNames(): Set<String> =
      root.resolve("apps/${scope.lynxAppId}/releases")
        .listFiles()
        .orEmpty()
        .filter(File::isDirectory)
        .map(File::getName)
        .toSet()
  }

  private companion object {
    const val APP_ID = "10000009"
    const val PAGE_ID = 1
    const val BUNDLE_PATH = "main.lynx.bundle"
    val REMOTE_BUNDLE_URI: URI = URI.create("https://cdn.invalid/main.lynx.bundle")
  }
}
