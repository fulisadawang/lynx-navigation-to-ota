package com.ota.android.sdk

import java.io.IOException
import java.net.URI
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class OtaSidecarContractTest {
  @get:Rule val temporary = TemporaryFolder()

  private val mainSha = "sha256:" + "a".repeat(64)
  private val asyncSha = "sha256:" + "b".repeat(64)

  @Test fun templateHostIsExplicitAndLegacyNamesRemainStable() {
    assertEquals("template", OtaModels.HostApp.TEMPLATE.wireValue)
    assertEquals(OtaModels.HostApp.TEMPLATE, OtaModels.HostApp.fromWire("template"))
    assertEquals(OtaModels.HostApp.CAPP, OtaModels.HostApp.fromWire("capp"))
    assertEquals(OtaModels.HostApp.GAPP, OtaModels.HostApp.fromWire("gapp"))
  }

  @Test fun latestAndInstalledSidecarFieldsRoundTrip() {
    val ref = OtaSidecarModels.AsyncManifestRef(1, URI.create("https://example.invalid/async.json"), asyncSha, 949)
    val latest = OtaModels.LatestBundleList.fromJsonMap(mapOf(
      "env" to "TEST", "hostApp" to "template", "lynxAppId" to "10020000",
      "releaseId" to "fixture-r1", "platform" to "android", "status" to "active",
      "changedBundles" to listOf(mapOf("pageId" to 1, "bundlePath" to "HomePage.lynx.bundle",
        "bundleSha256" to mainSha, "bundleUrl" to "https://example.invalid/HomePage.lynx.bundle", "size" to 100)),
      "asyncBundleManifest" to ref.toJsonMap(),
    ))
    val manifest = OtaModels.ReleaseManifest.fromJsonMap(latest.asManifest().toJsonMap())
    assertEquals(ref, manifest.asyncBundleManifest)

    val installed = OtaModels.InstalledRelease(
      OtaModels.CurrentReleaseContext(OtaModels.Environment.TEST, OtaModels.HostApp.TEMPLATE,
        "10020000", "fixture-r1", OtaModels.Platform.ANDROID, OtaModels.ReleaseStatus.ACTIVE),
      java.time.Instant.EPOCH, emptyList(), asyncBundleManifest = ref,
    )
    val decoded = OtaModels.InstalledRelease.fromJsonMap(installed.toJsonMap())
    assertEquals(ref, decoded.asyncBundleManifest)
  }

  @Test fun lowLevelInstallRejectsUnstagedAsyncBeforeAnyMainDownload() {
    val ref = OtaSidecarModels.AsyncManifestRef(1, URI.create("https://example.invalid/async.json"), asyncSha, 949)
    val manifest = OtaModels.ReleaseManifest(
      OtaModels.Environment.TEST, OtaModels.HostApp.TEMPLATE, "10020000", "fixture-r1",
      OtaModels.Platform.ANDROID, listOf(OtaModels.Platform.ANDROID), listOf(
        OtaModels.BundleArtifact(1, "HomePage.lynx.bundle", mainSha,
          URI.create("https://example.invalid/HomePage.lynx.bundle"), 100)),
      OtaModels.ReleaseStatus.ACTIVE, ref,
    )
    val store = ContentAddressedOtaStore(temporary.newFolder("store"))
    assertThrows(IOException::class.java) {
      store.install(ReleaseTransaction.InstallRequest(ReleaseTransaction.ReleaseScope.fromManifest(manifest), manifest))
    }
  }

  @Test fun requestKeyRetainsSingleLeadingSlashAndRejectsTraversal() {
    assertEquals("/lazy-bundle/part.bundle", OtaSidecarModels.safePath("/lazy-bundle/part.bundle", true))
    for (bad in listOf("//lazy/a.bundle", "/lazy/../a.bundle", "/lazy/a.bundle?x=1", "lazy\\a.bundle")) {
      assertTrue(runCatching { OtaSidecarModels.safePath(bad, true) }.isFailure)
    }
  }

}
