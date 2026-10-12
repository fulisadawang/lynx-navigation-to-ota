package com.ota.android.sdk

import java.io.File
import java.net.URI
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test

class EngineResourceIdentityTest {
  private val owner = "HomePage.lynx.bundle"
  private val sha = "sha256:" + "0".repeat(64)

  private fun entry() = OtaSidecarModels.AsyncEntry(
    owner, "/lazy/panel.bundle", "lazy/panel.bundle",
    URI.create("https://fixture.example/lazy/panel.bundle"), sha, 11,
    OtaSidecarModels.AsyncKind.BUNDLE,
  )

  @Test fun manualResourcesRemainUnknownAndOriginalConstructorsStayCompatible() {
    val file = OtaSidecarViewResources.ResolvedEntry("/lazy/panel.bundle", "https://fixture.example/lazy", OtaSidecarModels.AsyncKind.BUNDLE, File("/tmp/manual-panel"))
    val asset = OtaSidecarViewResources.ResolvedEntry.fromAsset("/lazy/panel.bundle", OtaSidecarModels.AsyncKind.BUNDLE) { byteArrayOf(1) }
    val positionalReader = OtaSidecarViewResources.ResolvedEntry.fromAsset("/lazy/other.bundle", OtaSidecarModels.AsyncKind.BUNDLE, { byteArrayOf(2) })
    assertNull(OtaSidecarViewResources(owner, listOf(file, asset)).snapshotIdentity)
    listOf(file, asset, positionalReader).forEach {
      assertNull(it.expectedSha256)
      assertNull(it.expectedSize)
    }
  }

  @Test fun validatedMetadataIsPreservedForFileAndAssetEntries() {
    val file = OtaSidecarViewResources.ResolvedEntry("/lazy/panel.bundle", "https://fixture.example/lazy", OtaSidecarModels.AsyncKind.BUNDLE, File("/tmp/validated-panel"), sha, 11)
    val asset = OtaSidecarViewResources.ResolvedEntry.fromAsset("/lazy/panel.bundle", OtaSidecarModels.AsyncKind.BUNDLE, sha, 11) { ByteArray(11) }
    listOf(file, asset).forEach {
      assertEquals(sha, it.expectedSha256)
      assertEquals(11, it.expectedSize)
    }
  }

  @Test fun downloadedIdentityIsDeterministicRegardlessOfManifestEntryOrder() {
    val first = entry()
    val second = first.copy(requestKey = "/lazy/second.bundle", path = "lazy/second.bundle", url = URI.create("https://fixture.example/lazy/second.bundle"))
    assertEquals(
      OtaSidecarViewResources.downloadedSnapshotIdentity(owner, listOf(first, second)),
      OtaSidecarViewResources.downloadedSnapshotIdentity(owner, listOf(second, first)),
    )
  }

  @Test fun identitySerializationHasFixedShaVectors() {
    assertEquals("sha256:d25407a8742dd2cb8577b191f702df65d8a73dfce27f8c87ae296f549adcf0e6",
      OtaSidecarViewResources.downloadedSnapshotIdentity(owner, listOf(entry())))
    assertEquals("sha256:347595cf2b529f091ce6d51c1ab6e048ed18d7f0169950d32b5816854ac7966b",
      OtaSidecarViewResources.embeddedSnapshotIdentity(owner, sha))
  }

  @Test fun downloadedIdentityIncludesEveryLogicalResourceFieldAndMainOwner() {
    val first = entry()
    val original = OtaSidecarViewResources.downloadedSnapshotIdentity(owner, listOf(first))
    listOf(
      first.copy(requestKey = "/lazy/new-request.bundle"),
      first.copy(url = URI.create("https://fixture.example/lazy/new-url.bundle")),
      first.copy(kind = OtaSidecarModels.AsyncKind.SCRIPT),
      first.copy(path = "lazy/new-path.bundle"),
      first.copy(ownerBundlePath = "OtherPage.lynx.bundle"),
      first.copy(sha256 = "sha256:" + "1".repeat(64)),
      first.copy(size = 12),
    ).forEach { changed ->
      assertNotEquals(original, OtaSidecarViewResources.downloadedSnapshotIdentity(owner, listOf(changed)))
    }
    assertNotEquals(original, OtaSidecarViewResources.downloadedSnapshotIdentity("OtherPage.lynx.bundle", listOf(first)))
  }

  @Test fun embeddedIdentityUsesVerifiedIndexDigestAndMainOwner() {
    val original = OtaSidecarViewResources.embeddedSnapshotIdentity(owner, sha)
    assertEquals(original, OtaSidecarViewResources.embeddedSnapshotIdentity(owner, sha))
    assertNotEquals(original, OtaSidecarViewResources.embeddedSnapshotIdentity("OtherPage.lynx.bundle", sha))
    assertNotEquals(original, OtaSidecarViewResources.embeddedSnapshotIdentity(owner, "sha256:" + "1".repeat(64)))
  }
}
