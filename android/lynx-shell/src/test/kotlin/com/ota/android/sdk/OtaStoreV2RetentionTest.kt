package com.ota.android.sdk

import java.io.File
import java.net.URI
import java.time.Instant
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class OtaStoreV2RetentionTest {
  @get:Rule
  val temporaryFolder = TemporaryFolder()

  @Test
  fun `same release id is physically isolated by app id`() {
    val root = temporaryFolder.newFolder("same-release-two-apps")
    val transaction = ReleaseTransaction(root)
    val appA = fixture(APP_A, "embedded-a", "bundle-a")
    val appB = fixture(APP_B, "embedded-b", "bundle-b")
    transaction.registerEmbeddedRelease(appA.embedded)
    transaction.registerEmbeddedRelease(appB.embedded)

    transaction.install(appA.scope, appA.manifest(RELEASE_V5))
    transaction.install(appB.scope, appB.manifest(RELEASE_V5))

    val bundleA = transaction.ensureBundleReady(appA.scope, BUNDLE_PATH)
    val bundleB = transaction.ensureBundleReady(appB.scope, BUNDLE_PATH)
    assertEquals("bundle-a", bundleA.readText())
    assertEquals("bundle-b", bundleB.readText())
    assertEquals(
      root.resolve("apps/$APP_A/releases/$RELEASE_V5/$BUNDLE_PATH").canonicalFile,
      bundleA.canonicalFile,
    )
    assertEquals(
      root.resolve("apps/$APP_B/releases/$RELEASE_V5/$BUNDLE_PATH").canonicalFile,
      bundleB.canonicalFile,
    )
  }

  @Test
  fun `ten normal activations retain only current and previous`() {
    val root = temporaryFolder.newFolder("bounded-normal-retention")
    val transaction = ReleaseTransaction(root)
    val fixture = fixture(APP_A, "embedded", "stable-payload")
    transaction.registerEmbeddedRelease(fixture.embedded)

    for (version in 1..10) {
      transaction.install(fixture.scope, fixture.manifest("V$version"))
    }

    assertEquals("V10", transaction.current(fixture.scope)?.context?.releaseId)
    assertEquals(setOf("V9", "V10"), releaseNames(root, APP_A))
    val state = root.resolve("apps/$APP_A/state.json")
    assertTrue(state.isFile)
    assertTrue(state.readText().contains("\"schemaVersion\":2"))
    assertFalse(root.resolve("releases").exists())
    assertFalse(root.resolve("states").exists())
  }

  @Test
  fun `candidate mode retains current previous and one candidate then prunes after confirmation`() {
    val root = temporaryFolder.newFolder("bounded-candidate-retention")
    val transaction = ReleaseTransaction(root)
    val fixture = fixture(APP_A, "embedded", "stable-payload")
    transaction.registerEmbeddedRelease(fixture.embedded)
    for (version in 1..10) {
      transaction.install(fixture.scope, fixture.manifest("V$version"))
    }

    val outcome = transaction.install(
      ReleaseTransaction.InstallRequest(
        scope = fixture.scope,
        targetManifest = fixture.manifest("V11"),
        stageAsCandidate = true,
      ),
    )

    assertEquals(ReleaseTransaction.InstallResultType.CANDIDATE, outcome.type)
    assertEquals(setOf("V9", "V10", "V11"), releaseNames(root, APP_A))
    assertTrue(root.resolve("apps/$APP_A/candidate.json").isFile)

    transaction.beginCandidateTrial(fixture.scope)
    transaction.confirmCandidate(fixture.scope)

    assertEquals("V11", transaction.current(fixture.scope)?.context?.releaseId)
    assertEquals(setOf("V10", "V11"), releaseNames(root, APP_A))
    assertFalse(root.resolve("apps/$APP_A/candidate.json").exists())
  }

  @Test
  fun `deleting one app leaves another app with the same release untouched`() {
    val root = temporaryFolder.newFolder("delete-isolation")
    val transaction = ReleaseTransaction(root)
    val appA = fixture(APP_A, "embedded-a", "bundle-a")
    val appB = fixture(APP_B, "embedded-b", "bundle-b")
    transaction.registerEmbeddedRelease(appA.embedded)
    transaction.registerEmbeddedRelease(appB.embedded)
    transaction.install(appA.scope, appA.manifest(RELEASE_V5))
    transaction.install(appB.scope, appB.manifest(RELEASE_V5))

    transaction.deleteDownloadedBundles(APP_A)

    assertFalse(root.resolve("apps/$APP_A/state.json").exists())
    assertFalse(root.resolve("apps/$APP_A/releases/$RELEASE_V5").exists())
    assertTrue(root.resolve("apps/$APP_B/state.json").isFile)
    assertTrue(root.resolve("apps/$APP_B/releases/$RELEASE_V5").isDirectory)
    assertEquals("bundle-b", transaction.ensureBundleReady(appB.scope, BUNDLE_PATH).readText())
  }

  @Test
  fun `embedded registration never copies bundle bytes into ota store`() {
    val root = temporaryFolder.newFolder("embedded-direct-read")
    val transaction = ReleaseTransaction(root)
    val fixture = fixture(APP_A, "embedded", "baseline-bytes")

    transaction.registerEmbeddedRelease(fixture.embedded)

    assertEquals("embedded", transaction.current(fixture.scope)?.context?.releaseId)
    assertEquals(
      emptyList<File>(),
      root.walkTopDown().filter { it.isFile && it.name.endsWith(".lynx.bundle") }.toList(),
    )
    assertNotNull(transaction.ensureBundleReady(fixture.scope, BUNDLE_PATH))
  }

  @Test
  fun `insufficient storage keeps embedded current and publishes no partial release`() {
    val root = temporaryFolder.newFolder("insufficient-storage")
    val transaction = ReleaseTransaction(
      storageRoot = root,
      capacityProbe = ReleaseTransaction.CapacityProbe { 0L },
    )
    val fixture = fixture(APP_A, "embedded", "baseline")
    transaction.registerEmbeddedRelease(fixture.embedded)

    val error = runCatching {
      transaction.install(fixture.scope, fixture.manifest("V1"))
    }.exceptionOrNull()

    assertTrue(error is OtaSdkException)
    assertEquals("insufficient_storage", (error as OtaSdkException).reasonCode)
    assertEquals("embedded", transaction.current(fixture.scope)?.context?.releaseId)
    assertTrue(releaseNames(root, APP_A).isEmpty())
    assertTrue(root.resolve("apps/$APP_A/.staging").listFiles().orEmpty().isEmpty())
  }

  @Test
  fun `orphan pruning happens before capacity preflight`() {
    val root = temporaryFolder.newFolder("prune-before-preflight")
    val orphanRemovedBeforeProbe = AtomicBoolean(false)
    val orphan = root.resolve("apps/$APP_A/releases/orphan")
    val transaction = ReleaseTransaction(
      storageRoot = root,
      capacityProbe = ReleaseTransaction.CapacityProbe {
        orphanRemovedBeforeProbe.set(!orphan.exists())
        if (orphanRemovedBeforeProbe.get()) Long.MAX_VALUE else 0L
      },
    )
    val fixture = fixture(APP_A, "embedded", "baseline")
    transaction.registerEmbeddedRelease(fixture.embedded)
    orphan.mkdirs()
    orphan.resolve("stale.lynx.bundle").writeText("stale")

    transaction.install(fixture.scope, fixture.manifest("V1"))

    assertTrue(orphanRemovedBeforeProbe.get())
    assertFalse(orphan.exists())
    assertEquals("V1", transaction.current(fixture.scope)?.context?.releaseId)
  }

  @Test
  fun `state commit faults remain durable on both sides of the commit boundary`() {
    val beforeRoot = temporaryFolder.newFolder("fault-before-state")
    val beforeFixture = fixture(APP_A, "embedded-before", "payload-before")
    val failBefore = ReleaseTransaction(
      storageRoot = beforeRoot,
      faultInjector = ReleaseTransaction.TransactionFaultInjecting { point ->
        if (point == ReleaseTransaction.TransactionFaultPoint.BEFORE_STATE_COMMIT) {
          throw IllegalStateException("before state commit")
        }
      },
    )
    failBefore.registerEmbeddedRelease(beforeFixture.embedded)
    assertTrue(runCatching { failBefore.install(beforeFixture.scope, beforeFixture.manifest("V1")) }.isFailure)
    assertEquals("embedded-before", ReleaseTransaction(beforeRoot).current(beforeFixture.scope)?.context?.releaseId)

    val afterRoot = temporaryFolder.newFolder("fault-after-state")
    val afterFixture = fixture(APP_B, "embedded-after", "payload-after")
    val failAfter = ReleaseTransaction(
      storageRoot = afterRoot,
      faultInjector = ReleaseTransaction.TransactionFaultInjecting { point ->
        if (point == ReleaseTransaction.TransactionFaultPoint.AFTER_STATE_COMMIT) {
          throw IllegalStateException("after state commit")
        }
      },
    )
    failAfter.registerEmbeddedRelease(afterFixture.embedded)
    assertTrue(runCatching { failAfter.install(afterFixture.scope, afterFixture.manifest("V1")) }.isFailure)
    assertEquals("V1", ReleaseTransaction(afterRoot).current(afterFixture.scope)?.context?.releaseId)
  }

  @Test
  fun `staging recovery only touches the app currently installing`() {
    val root = temporaryFolder.newFolder("app-scoped-staging-recovery")
    val transaction = ReleaseTransaction(root)
    val fixture = fixture(APP_A, "embedded", "payload")
    transaction.registerEmbeddedRelease(fixture.embedded)
    val appAStaging = root.resolve("apps/$APP_A/.staging/old-a.tx")
    val appBStaging = root.resolve("apps/$APP_B/.staging/active-b.tx")
    appAStaging.mkdirs()
    appBStaging.mkdirs()
    appAStaging.resolve("a.part").writeText("partial-a")
    appBStaging.resolve("b.part").writeText("partial-b")

    transaction.install(fixture.scope, fixture.manifest("V1"))

    assertFalse(appAStaging.exists())
    assertTrue(appBStaging.resolve("b.part").isFile)
  }

  @Test
  fun `cold start maintenance removes v2 orphan and staging but preserves current`() {
    val root = temporaryFolder.newFolder("cold-maintenance")
    val transaction = ReleaseTransaction(root)
    val fixture = fixture(APP_A, "embedded", "payload")
    transaction.registerEmbeddedRelease(fixture.embedded)
    transaction.install(fixture.scope, fixture.manifest("V1"))
    val orphan = root.resolve("apps/$APP_A/releases/orphan")
    val staging = root.resolve("apps/$APP_A/.staging/abandoned.tx")
    orphan.mkdirs()
    staging.mkdirs()
    orphan.resolve("old.bundle").writeText("old")
    staging.resolve("partial.part").writeText("partial")

    ReleaseTransaction(root).pruneAllUnreferencedReleases()

    assertFalse(orphan.exists())
    assertFalse(staging.exists())
    assertTrue(root.resolve("apps/$APP_A/releases/V1").isDirectory)
    assertEquals("V1", ReleaseTransaction(root).current(fixture.scope)?.context?.releaseId)
  }

  @Test
  fun `cold maintenance never guesses when state is malformed`() {
    val root = temporaryFolder.newFolder("cold-maintenance-malformed")
    val transaction = ReleaseTransaction(root)
    val fixture = fixture(APP_A, "embedded", "payload")
    transaction.registerEmbeddedRelease(fixture.embedded)
    transaction.install(fixture.scope, fixture.manifest("V1"))
    val orphan = root.resolve("apps/$APP_A/releases/orphan")
    orphan.mkdirs()
    orphan.resolve("keep.bundle").writeText("keep")
    root.resolve("apps/$APP_A/state.json").writeText("malformed")

    ReleaseTransaction(root).pruneAllUnreferencedReleases()

    assertTrue(root.resolve("apps/$APP_A/releases/V1").isDirectory)
    assertTrue(orphan.isDirectory)
  }

  private fun releaseNames(root: File, appId: String): Set<String> {
    return root.resolve("apps/$appId/releases")
      .listFiles()
      .orEmpty()
      .filter(File::isDirectory)
      .map(File::getName)
      .toSet()
  }

  private fun fixture(appId: String, embeddedReleaseId: String, payload: String): Fixture {
    val source = temporaryFolder.newFile("$appId-$embeddedReleaseId.lynx.bundle")
      .also { it.writeText(payload) }
    val artifact = OtaModels.BundleArtifact(
      PAGE_ID,
      BUNDLE_PATH,
      OtaIO.sha256(source),
      REMOTE_BUNDLE_URI,
      source.length().toInt(),
    )
    val scope = ReleaseTransaction.ReleaseScope(
      OtaModels.Environment.TEST,
      OtaModels.HostApp.CAPP,
      appId,
      OtaModels.Platform.ANDROID,
    )
    val embedded = OtaModels.InstalledRelease(
      OtaModels.CurrentReleaseContext(
        OtaModels.Environment.TEST,
        OtaModels.HostApp.CAPP,
        appId,
        embeddedReleaseId,
        OtaModels.Platform.ANDROID,
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
    return Fixture(scope, embedded, artifact)
  }

  private data class Fixture(
    val scope: ReleaseTransaction.ReleaseScope,
    val embedded: OtaModels.InstalledRelease,
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
    const val APP_A = "10000009"
    const val APP_B = "10000010"
    const val RELEASE_V5 = "V5"
    const val PAGE_ID = 1
    const val BUNDLE_PATH = "main.lynx.bundle"
    val REMOTE_BUNDLE_URI: URI = URI.create("https://cdn.invalid/main.lynx.bundle")
  }
}
