package com.ota.android.sdk

import java.io.File
import java.net.URI
import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class OtaCandidateActivationTest {
  @get:Rule
  val temporaryFolder = TemporaryFolder()

  @Test
  fun `candidate stays out of current until healthy confirmation`() {
    val source = fixtureFile("candidate-source.lynx.bundle", "embedded payload")
    val artifact = artifactFor(source)
    val scope = scope()
    val transaction = ReleaseTransaction(temporaryFolder.newFolder("candidate-promote"))
    transaction.registerEmbeddedRelease(embeddedRelease("embedded-r1", source, artifact.bundleSha256))

    val outcome = transaction.install(
      ReleaseTransaction.InstallRequest(
        scope = scope,
        targetManifest = manifest("downloaded-r2", artifact),
        embeddedDescriptor = embeddedRelease("embedded-r1", source, artifact.bundleSha256),
        stageAsCandidate = true,
      ),
    )

    assertEquals(ReleaseTransaction.InstallResultType.CANDIDATE, outcome.type)
    assertEquals("embedded-r1", transaction.current(scope)?.context?.releaseId)
    assertEquals(OtaModels.CandidateStatus.PENDING, transaction.candidate(scope)?.status)

    val trial = transaction.beginCandidateTrial(scope)
    assertEquals(OtaModels.CandidateStatus.TRIAL, trial.status)
    val confirmed = transaction.confirmCandidate(scope)

    assertEquals("downloaded-r2", confirmed.context.releaseId)
    assertEquals("downloaded-r2", transaction.current(scope)?.context?.releaseId)
    assertEquals("downloaded-r2", transaction.rollbackOutcome(scope).fromReleaseId)
    assertNull(transaction.candidate(scope))
  }

  @Test
  fun `unfinished trial is discarded after a new transaction is created`() {
    val source = fixtureFile("candidate-restart-source.lynx.bundle", "embedded payload")
    val artifact = artifactFor(source)
    val scope = scope()
    val root = temporaryFolder.newFolder("candidate-restart")
    val first = ReleaseTransaction(root)
    first.registerEmbeddedRelease(embeddedRelease("embedded-r1", source, artifact.bundleSha256))
    first.install(
      ReleaseTransaction.InstallRequest(
        scope = scope,
        targetManifest = manifest("downloaded-r2", artifact),
        embeddedDescriptor = embeddedRelease("embedded-r1", source, artifact.bundleSha256),
        stageAsCandidate = true,
      ),
    )
    first.beginCandidateTrial(scope)

    val restarted = ReleaseTransaction(root)
    restarted.recoverInterruptedCandidate(scope)

    assertNull(restarted.candidate(scope))
    assertEquals("embedded-r1", restarted.current(scope)?.context?.releaseId)
    assertTrue(root.resolve("releases/downloaded-r2").exists().not())
  }

  @Test
  fun `rollback commit remains readable after a post-commit process fault`() {
    val source = fixtureFile("rollback-fault-source.lynx.bundle", "embedded payload")
    val artifact = artifactFor(source)
    val scope = scope()
    val root = temporaryFolder.newFolder("rollback-fault")
    val failAfterCommit = ReleaseTransaction.TransactionFaultInjecting { point ->
      if (point == ReleaseTransaction.TransactionFaultPoint.AFTER_ROLLBACK_COMMIT) {
        throw IllegalStateException("simulated process termination after rollback commit")
      }
    }
    val transaction = ReleaseTransaction(root, faultInjector = failAfterCommit)
    transaction.registerEmbeddedRelease(embeddedRelease("embedded-r1", source, artifact.bundleSha256))
    transaction.install(
      scope,
      manifest("downloaded-r2", artifact),
      embeddedRelease("embedded-r1", source, artifact.bundleSha256),
    )

    try {
      transaction.rollback(scope)
    } catch (_: IllegalStateException) {
      // 进程故障点发生在 state 已写入之后；下面用新 Transaction 证明 durable state。
    }

    val restarted = ReleaseTransaction(root)
    assertEquals("embedded-r1", restarted.current(scope)?.context?.releaseId)
    assertNull(restarted.rollbackOutcome(scope).restored)
  }

  private fun scope(): ReleaseTransaction.ReleaseScope = ReleaseTransaction.ReleaseScope(
    OtaModels.Environment.TEST,
    OtaModels.HostApp.CAPP,
    APP_ID,
    OtaModels.Platform.ANDROID,
  )

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
    val REMOTE_BUNDLE_URI: URI = URI.create("https://cdn.invalid/main.lynx.bundle")
  }
}
