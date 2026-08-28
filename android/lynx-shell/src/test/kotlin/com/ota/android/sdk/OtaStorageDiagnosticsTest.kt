package com.ota.android.sdk

import java.io.File
import java.net.URI
import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class OtaStorageDiagnosticsTest {
  @get:Rule
  val temporaryFolder = TemporaryFolder()

  @Test
  fun `empty snapshot exposes the real root without creating store files`() {
    val root = temporaryFolder.newFolder("empty-diagnostics")
    val before = root.walkTopDown().map(File::getCanonicalPath).toList()

    val snapshot = OtaStorageDiagnostics(root).snapshot()

    assertEquals(root.canonicalPath, snapshot.rootPath)
    assertEquals(0L, snapshot.totalBytes)
    assertEquals(0, snapshot.fileCount)
    assertTrue(snapshot.apps.isEmpty())
    assertEquals(before, root.walkTopDown().map(File::getCanonicalPath).toList())
  }

  @Test
  fun `snapshot reports state candidate leases orphan and staging from one consistent store view`() {
    val fixture = fixture("diagnostics-roles")
    fixture.transaction.install(fixture.scope, fixture.manifest("V1"))
    fixture.transaction.install(fixture.scope, fixture.manifest("V2"))
    val lease = requireNotNull(
      fixture.transaction.acquireCurrentBundleLease(fixture.scope, BUNDLE_PATH),
    )
    fixture.transaction.install(
      ReleaseTransaction.InstallRequest(
        fixture.scope,
        fixture.manifest("V3"),
        stageAsCandidate = true,
      ),
    )
    val orphan = fixture.root.resolve("apps/$APP_ID/releases/orphan")
    orphan.mkdirs()
    orphan.resolve("release-manifest.json").writeText("not-json")
    val staging = fixture.root.resolve("apps/$APP_ID/.staging/V4.tx-test")
    staging.mkdirs()
    staging.resolve("main.lynx.bundle.part").writeText("partial")

    val snapshot = OtaStorageDiagnostics(fixture.root).snapshot()
    val app = snapshot.apps.single()

    assertEquals(APP_ID, app.appId)
    assertEquals("V2", app.state?.currentReleaseId)
    assertEquals("V1", app.state?.previousReleaseId)
    assertEquals("V3", app.candidate?.releaseId)
    assertEquals(OtaModels.CandidateStatus.PENDING.wireValue, app.candidate?.status)
    assertEquals(setOf("V1", "V2", "V3", "orphan"), app.releases.map { it.releaseId }.toSet())
    assertTrue(app.releases.single { it.releaseId == "V2" }.roles.contains(OtaStorageReleaseRole.LEASED))
    assertTrue(app.releases.single { it.releaseId == "V2" }.roles.contains(OtaStorageReleaseRole.CURRENT))
    assertTrue(app.releases.single { it.releaseId == "V1" }.roles.contains(OtaStorageReleaseRole.PREVIOUS))
    assertTrue(app.releases.single { it.releaseId == "V3" }.roles.contains(OtaStorageReleaseRole.CANDIDATE))
    assertEquals(setOf(OtaStorageReleaseRole.ORPHAN), app.releases.single { it.releaseId == "orphan" }.roles)
    assertFalse(app.releases.single { it.releaseId == "orphan" }.manifestValid)
    assertEquals("V4.tx-test", app.staging.single().transactionName)
    assertEquals("main.lynx.bundle.part", app.staging.single().files.single().relativePath)
    assertEquals(actualFileBytes(fixture.root), snapshot.totalBytes)
    assertEquals(actualFileCount(fixture.root), snapshot.fileCount)

    lease.close()
  }

  @Test
  fun `same release id remains visible under both app cards`() {
    val root = temporaryFolder.newFolder("diagnostics-two-apps")
    val appA = fixture(root, APP_ID, "payload-a")
    val appB = fixture(root, SECOND_APP_ID, "payload-b")
    appA.transaction.install(appA.scope, appA.manifest("V5"))
    appB.transaction.install(appB.scope, appB.manifest("V5"))

    val snapshot = OtaStorageDiagnostics(root).snapshot()

    assertEquals(setOf(APP_ID, SECOND_APP_ID), snapshot.apps.map { it.appId }.toSet())
    assertTrue(snapshot.apps.all { app -> app.releases.single().releaseId == "V5" })
    assertTrue(snapshot.apps.all { app -> app.releases.single().roles.contains(OtaStorageReleaseRole.CURRENT) })
  }

  private fun fixture(name: String): Fixture = fixture(temporaryFolder.newFolder(name), APP_ID, "payload")

  private fun fixture(root: File, appId: String, payload: String): Fixture {
    val source = temporaryFolder.newFile("$appId-${root.name}.lynx.bundle").also { it.writeText(payload) }
    val scope = ReleaseTransaction.ReleaseScope(
      OtaModels.Environment.TEST,
      OtaModels.HostApp.CAPP,
      appId,
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

  private fun actualFileBytes(root: File): Long = root.walkTopDown().filter(File::isFile).sumOf(File::length)

  private fun actualFileCount(root: File): Int = root.walkTopDown().count(File::isFile)

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
  }

  private companion object {
    const val APP_ID = "10000009"
    const val SECOND_APP_ID = "10000010"
    const val PAGE_ID = 1
    const val BUNDLE_PATH = "main.lynx.bundle"
    val REMOTE_BUNDLE_URI: URI = URI.create("https://cdn.invalid/main.lynx.bundle")
  }
}
