package com.ota.android.sdk

import java.io.Closeable
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URI
import java.net.URLDecoder
import java.security.MessageDigest
import java.time.Instant
import java.util.Collections
import java.util.concurrent.Callable
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class OtaUserSelectionTest {
  @get:Rule val temporary = TemporaryFolder()
  private fun fixture() = SelectionFixture(temporary.newFolder())

  @Test fun `normalizers match Server trim controls and integer precision`() {
    assertEquals("000AbC", OtaUserContext.normalizeUserId(" 000AbC "))
    assertNull(OtaUserContext.normalizeUserId(" \u3000 "))
    for (number in (0..31).toList() + (127..159).toList()) {
      expectCode("invalid_user_id") { OtaUserContext.normalizeUserId(number.toChar() + "user") }
      expectCode("invalid_user_id") { OtaUserContext.normalizeUserId("user" + number.toChar()) }
    }
    expectCode("invalid_user_id") { OtaUserContext.normalizeUserId("中".repeat(86)) }
    assertEquals("9223372036854775807", OtaUserContext.normalizeVersionCode(" \n0009223372036854775807\t"))
    for (value in listOf("0", "-1", "1.2", "1e3", "9223372036854775808", "１２")) expectCode("invalid_version_code") { OtaUserContext.normalizeVersionCode(value) }
    assertEquals("4.10.0", OtaUserContext.normalizeLynxSdkVersion(" \n04.10\t"))
    assertEquals("9223372036854775808.0.0", OtaUserContext.normalizeLynxSdkVersion("9223372036854775808"))
    for (value in listOf("4.0-beta", "4. 0", "4..0")) expectCode("invalid_sdk_version") { OtaUserContext.normalizeLynxSdkVersion(value) }
  }

  @Test fun `code and SDK range endpoints are inclusive and missing context fails closed`() {
    val range = OtaVersionCodeRange("20", "29")
    assertFalse(OtaSelectionValidation.matchesCode("19", range)); assertTrue(OtaSelectionValidation.matchesCode("20", range))
    assertTrue(OtaSelectionValidation.matchesCode("29", range)); assertFalse(OtaSelectionValidation.matchesCode("30", range))
    assertFalse(OtaSelectionValidation.matchesCode(null, range))
    assertTrue(OtaSelectionValidation.matchesCode("9223372036854775807", OtaVersionCodeRange("9007199254740993")))
    assertFalse(OtaSelectionValidation.matchesCode("9007199254740992", OtaVersionCodeRange("9007199254740993")))
    val sdk = OtaModels.ReleaseVersionRange("4.9", "4.10")
    assertTrue(OtaSelectionValidation.matchesVersion("4.10", sdk, true))
    assertTrue(OtaSelectionValidation.matchesVersion("4.9", sdk, true))
    assertFalse(OtaSelectionValidation.matchesVersion("4.8", sdk, true))
    assertFalse(OtaSelectionValidation.matchesVersion(null, sdk, true))
  }

  @Test fun `real HTTP query carries exact context decodes directives and keeps context ETags separate`() = fixture().use { f ->
    val box = OtaUserContextBox(f.configuration("000A"))
    val client = OtaApiClient.server(f.server.base, null, OtaModels.Environment.TEST, true)
    f.server.response = OtaJson.stringify(f.wire(f.latest("6", kind = OtaSelectionKind.GRAY)))
    assertTrue(client.fetchLatestBundleList(ENV, HOST, APP, PLATFORM, box.capture()) is OtaLatestSelection.Release)
    val first = f.server.queries.last()
    assertEquals("25", first["versioncode"]); assertEquals("4.0.0", first["lynxSdkVersion"]); assertEquals("000A", first["userId"])
    assertFalse(first.containsKey("versionCode")); assertFalse(first.containsKey("selectionProtocol"))
    client.fetchLatestBundleList(ENV, HOST, APP, PLATFORM, box.capture())
    assertEquals("fixture-etag", f.server.conditionals.last())
    box.register("B")
    f.server.response = OtaJson.stringify(mapOf("env" to "TEST", "hostApp" to "capp", "platform" to "android", "selectionSchemaVersion" to 1,
      "decision" to OtaSelectionDirective(APP, OtaSelectionAction.USE_EMBEDDED, "2", "forced").toJsonMap()))
    val directive = client.fetchLatestBundleList(ENV, HOST, APP, PLATFORM, box.capture()) as OtaLatestSelection.Directive
    assertEquals(OtaSelectionAction.USE_EMBEDDED, directive.directive.action)
    assertNull(f.server.conditionals.last())
    box.register(null)
    f.server.response = OtaJson.stringify(mapOf("env" to "TEST", "hostApp" to "capp", "platform" to "android", "selectionSchemaVersion" to 1,
      "bundleLists" to emptyList<Any>(), "directives" to listOf(directive.directive.toJsonMap())))
    assertEquals(1, client.fetchLatestBundleLists(ENV, HOST, PLATFORM, box.capture()).directives.size)
    assertFalse(f.server.queries.last().containsKey("userId"))
    assertFalse(f.server.queries.last().containsKey("lynxAppId"))
  }

  @Test fun `wire rejects missing selection bad ranges and accepts Harmony in platform arrays`() = fixture().use { f ->
    val wire = f.wire(f.latest("5")).toMutableMap()
    wire["platforms"] = listOf("android", "ios", "harmony")
    assertTrue(OtaModels.LatestBundleList.fromJsonMap(wire).platforms.contains(OtaModels.Platform.HARMONY))
    wire["versionCodeRange"] = mapOf("minimum" to "20")
    expectCode("invalid_selection_metadata") { OtaModels.LatestBundleList.fromJsonMap(wire) }
    val sdk = f.sdk("A")
    f.api.selection = OtaLatestSelection.Release(f.latest("5", metadata = false))
    expectCode("missing_selection_metadata") { sdk.syncLatestBundleList(APP) }
    assertEquals(0, f.server.downloads.get())
  }

  @Test fun `same user registration is a no-op and raw unicode identifiers remain distinct`() = fixture().use { f ->
    val sdk = f.sdk("A")
    assertFalse(sdk.registerUserId(" A ")); assertEquals(0L, sdk.userIdentityEpoch)
    assertTrue(sdk.registerUserId("e\u0301")); assertTrue(sdk.registerUserId("é"))
    assertEquals(2L, sdk.userIdentityEpoch); assertEquals(0, f.api.queryCount.get())
  }

  @Test fun `C04 gray A is immediately ineligible for B before reconcile with full previous fallback`() = fixture().use { f ->
    val sdk = f.sdk("A"); f.install(sdk, "5", revision = "1"); f.install(sdk, "6", OtaSelectionKind.GRAY, "2")
    assertEquals("6", sdk.current(APP)?.context?.releaseId)
    sdk.registerUserId("B")
    assertEquals("5", sdk.current(APP)?.context?.releaseId)
    sdk.reconcileUserContext(); assertEquals("5", sdk.current(APP)?.context?.releaseId)
    expectCode("stale_decision") { sdk.rollback(APP, "old current callback", "6", sdk.userIdentityEpoch) }
  }

  @Test fun `C05 installed gray then offline B uses embedded or nil without a full release`() {
    for (embedded in listOf(false, true)) fixture().use { f ->
      val sdk = f.sdk("A", embedded = embedded); f.install(sdk, "6", OtaSelectionKind.GRAY, "1")
      f.api.failure = IOException("offline")
      sdk.registerUserId("B"); sdk.reconcileUserContext()
      assertEquals(if (embedded) "embedded" else null, sdk.current(APP)?.context?.releaseId)
      assertNull(sdk.acquireCurrentBundleLease(APP, BUNDLE)); assertEquals(1, f.server.downloads.get())
    }
  }

  @Test fun `C10 previous exactly A gray cannot be restored by B rollback`() = fixture().use { f ->
    val sdk = f.sdk("A"); f.install(sdk, "5", OtaSelectionKind.GRAY, "1")
    sdk.registerUserId("B"); f.install(sdk, "6", revision = "2")
    assertEquals("5", OtaJson.asObject(f.state()["previous"], "previous")["releaseId"])
    assertEquals("embedded", sdk.rollback(APP, "B recovery", "6", sdk.userIdentityEpoch)?.context?.releaseId)
    assertNull(sdk.acquireBundleLeaseForRelease(APP, "5", BUNDLE))
  }

  @Test fun `C11 anonymous cold SDK cannot use disk current directly pointing to A gray`() = fixture().use { f ->
    val a = f.sdk("A"); f.install(a, "6", OtaSelectionKind.GRAY, "1")
    assertEquals("6", OtaJson.asObject(f.state()["current"], "current")["releaseId"])
    val anonymous = f.sdk(null)
    assertEquals("embedded", anonymous.current(APP)?.context?.releaseId)
    assertNull(anonymous.acquireCurrentBundleLease(APP, BUNDLE))
    assertEquals("6", f.sdk("A").current(APP)?.context?.releaseId)
  }

  @Test fun `C08 gray to full same release changes metadata with zero more GETs and survives restart`() = fixture().use { f ->
    val sdk = f.sdk("A"); f.install(sdk, "6", OtaSelectionKind.GRAY, "1")
    f.install(sdk, "6", OtaSelectionKind.FULL, "2")
    assertEquals(1, f.server.downloads.get()); assertEquals(OtaSelectionKind.FULL, sdk.current(APP)?.selection?.kind)
    sdk.registerUserId(null); assertEquals("6", sdk.current(APP)?.context?.releaseId)
    assertEquals(OtaSelectionKind.FULL, f.sdk(null).current(APP)?.selection?.kind)
    assertFalse(f.root.resolve("users").exists()); assertFalse(f.stateFile().readText().contains("\"userId\""))
  }

  @Test fun `C06 delayed response A cannot commit after B completed a newer release`() = fixture().use { f ->
    val sdk = f.sdk("A"); val gate = SelectionGate()
    f.api.selection = OtaLatestSelection.Release(f.latest("6", OtaSelectionKind.GRAY, "1")); f.api.pause = gate
    val pending = f.async { sdk.syncLatestBundleList(APP) }; gate.awaitStarted()
    sdk.registerUserId("B"); sdk.reconcileUserContext(); f.install(sdk, "7", revision = "2")
    val stateB = f.stateFile().readText(); gate.release.countDown()
    expectCode("stale_identity") { pending.get(8, TimeUnit.SECONDS) }
    assertEquals(stateB, f.stateFile().readText()); assertEquals("7", sdk.current(APP)?.context?.releaseId)
  }

  @Test fun `invalidatePendingOperations always advances anonymous epoch and rejects old SDK writes`() = fixture().use { f ->
    val sdk = f.sdk(null); val gate = SelectionGate()
    f.api.selection = OtaLatestSelection.Release(f.latest("5")); f.api.pause = gate
    val pending = f.async { sdk.syncLatestBundleList(APP) }; gate.awaitStarted()
    sdk.invalidatePendingOperations(); assertEquals(1L, sdk.userIdentityEpoch)
    val fresh = f.sdk(null); f.install(fresh, "7", revision = "2")
    val state = f.stateFile().readText(); gate.release.countDown()
    expectCode("stale_identity") { pending.get(8, TimeUnit.SECONDS) }
    assertEquals(state, f.stateFile().readText()); assertEquals("7", fresh.current(APP)?.context?.releaseId)
  }

  @Test fun `final State rename and registration share one guard after file preparation`() = fixture().use { f ->
    val hook = SelectionFault(); val sdk = f.sdk("A", fault = hook)
    hook.arm(ContentAddressedFaultPoint.BEFORE_STATE_RENAME, skip = 1) { sdk.registerUserId("B") }
    f.api.selection = OtaLatestSelection.Release(f.latest("6", OtaSelectionKind.GRAY, "1"))
    expectCode("stale_identity") { sdk.syncLatestBundleList(APP) }
    assertEquals("embedded", OtaJson.asObject(f.state()["current"], "current")["releaseId"])
    assertEquals("embedded", sdk.current(APP)?.context?.releaseId)
  }

  @Test fun `download A can wait while B sync and current lease make progress`() = fixture().use { f ->
    val sdk = f.sdk("A"); f.install(sdk, "5", revision = "1")
    val old = f.latest("6", OtaSelectionKind.GRAY, "2"); val gate = SelectionGate()
    f.server.pauses[old.changedBundles[0].bundleUrl.path] = gate; f.api.selection = OtaLatestSelection.Release(old)
    val pending = f.async { sdk.syncLatestBundleList(APP) }; gate.awaitStarted()
    val lease = f.async { sdk.acquireCurrentBundleLease(APP, BUNDLE) }.get(2, TimeUnit.SECONDS)!!
    assertEquals("5", lease.release.context.releaseId)
    sdk.registerUserId("B"); sdk.reconcileUserContext()
    f.async { f.install(sdk, "7", revision = "3") }.get(3, TimeUnit.SECONDS)
    val b = f.stateFile().readText(); gate.release.countDown()
    expectCode("stale_identity") { pending.get(8, TimeUnit.SECONDS) }
    assertEquals(b, f.stateFile().readText()); assertEquals("7", sdk.current(APP)?.context?.releaseId); lease.close()
  }

  @Test fun `same identity old revision download cannot overwrite newer decision`() = fixture().use { f ->
    val sdk = f.sdk("A"); val old = f.latest("6", OtaSelectionKind.GRAY, "1"); val gate = SelectionGate()
    f.server.pauses[old.changedBundles[0].bundleUrl.path] = gate; f.api.selection = OtaLatestSelection.Release(old)
    val pending = f.async { sdk.syncLatestBundleList(APP) }; gate.awaitStarted()
    f.async { f.install(sdk, "7", revision = "2") }.get(3, TimeUnit.SECONDS)
    val state = f.stateFile().readText(); gate.release.countDown()
    expectCode("stale_decision") { pending.get(8, TimeUnit.SECONDS) }; assertEquals(state, f.stateFile().readText())
  }

  @Test fun `C07 candidate trial acquire is atomic against another candidate replacement`() = fixture().use { f ->
    val hook = SelectionFault(); val sdk = f.sdk("A", candidate = true, fault = hook)
    f.install(sdk, "6", OtaSelectionKind.GRAY, "1")
    val gate = SelectionGate(); hook.arm(ContentAddressedFaultPoint.BEFORE_STATE_COMMIT) { gate.block() }
    val acquiring = f.async { sdk.acquireCandidateTrialBundleLease(APP, BUNDLE) }; gate.awaitStarted()
    val replacing = f.async { f.install(sdk, "7", revision = "2") }
    assertFalse(replacing.isDone); gate.release.countDown()
    val lease = acquiring.get(3, TimeUnit.SECONDS)!!; replacing.get(3, TimeUnit.SECONDS)
    assertEquals("6", lease.release.context.releaseId); assertEquals("7", sdk.candidate(APP)?.release?.context?.releaseId)
    expectCode("stale_candidate") { sdk.confirmCandidateHealthy(APP, "6", sdk.userIdentityEpoch) }
    assertTrue(lease.file.isFile); lease.close(); assertFalse(lease.file.exists())
    val newLease = sdk.acquireCandidateTrialBundleLease(APP, BUNDLE)!!
    assertEquals(OtaModels.CandidateStatus.TRIAL, sdk.candidate(APP)?.status)
    assertEquals("7", sdk.confirmCandidateHealthy(APP, "7", sdk.userIdentityEpoch).context.releaseId); newLease.close()
  }

  @Test fun `candidate trial final identity failure closes its registered lease`() = fixture().use { f ->
    val hook = SelectionFault(); val sdk = f.sdk("A", candidate = true, fault = hook)
    f.install(sdk, "6", OtaSelectionKind.GRAY, "1")
    hook.arm(ContentAddressedFaultPoint.BEFORE_STATE_RENAME) { sdk.registerUserId("B") }
    expectCode("stale_identity") { sdk.acquireCandidateTrialBundleLease(APP, BUNDLE) }
    assertFalse(f.snapshot().apps.single().releases.any { OtaStorageReleaseRole.LEASED in it.roles })
  }

  @Test fun `same candidate resync preserves active trial and avoids another download`() = fixture().use { f ->
    val sdk = f.sdk("A", candidate = true)
    f.install(sdk, "6", OtaSelectionKind.GRAY, "1")
    val lease = sdk.acquireCandidateTrialBundleLease(APP, BUNDLE)!!
    assertEquals(OtaModels.CandidateStatus.TRIAL, sdk.candidate(APP)?.status)
    f.install(sdk, "6", OtaSelectionKind.GRAY, "1")
    assertEquals(OtaModels.CandidateStatus.TRIAL, sdk.candidate(APP)?.status)
    assertEquals(1, f.server.downloads.get())
    assertEquals("6", sdk.confirmCandidateHealthy(APP, "6", sdk.userIdentityEpoch).context.releaseId)
    lease.close()
  }

  @Test fun `B reuses bytes from an unpromoted A candidate only after its own selection`() = fixture().use { f ->
    val sdk = f.sdk("A", candidate = true)
    f.install(sdk, "6", OtaSelectionKind.GRAY, "1")
    sdk.registerUserId("B"); sdk.reconcileUserContext(); assertNull(sdk.candidate(APP))
    f.api.selection = OtaLatestSelection.Release(f.latest("7", revision = "2", reuseVersion = "6"))
    val result = sdk.syncLatestBundleList(APP)
    assertEquals("B", f.api.contexts.last().userId)
    assertEquals(1, f.server.downloads.get()); assertEquals(1, result.summary?.reusedBundleCount)
    assertEquals("7", sdk.candidate(APP)?.release?.context?.releaseId)
    assertEquals(OtaSelectionKind.FULL, sdk.candidate(APP)?.release?.selection?.kind)
  }

  @Test fun `new context refuses V2 reads and malformed directive containers while legacy remains available`() = fixture().use { f ->
    val contextual = OtaSdk(f.configuration("A", storeVersion = OtaModels.StoreVersion.V2), f.api)
    expectCode("requires_store_v3") { contextual.candidate(APP) }
    assertNull(OtaSdk(f.configuration(null, code = null, storeVersion = OtaModels.StoreVersion.V2), f.api).candidate(APP))
    assertTrue(runCatching { OtaModels.HostLatestBundleLists.fromJsonMap(mapOf(
      "env" to "TEST", "hostApp" to "capp", "platform" to "android", "selectionSchemaVersion" to 1,
      "bundleLists" to emptyList<Any>(), "directives" to mapOf("not" to "an array"))) }.isFailure)
  }

  @Test fun `rollback expected current check prevents old page from rolling back new full in same epoch`() = fixture().use { f ->
    val sdk = f.sdk("A"); f.install(sdk, "5", revision = "1"); f.install(sdk, "6", revision = "2")
    val expectedEpoch = sdk.userIdentityEpoch; val oldCurrent = sdk.current(APP)!!.context.releaseId
    f.install(sdk, "7", revision = "3"); val state = f.stateFile().readText()
    expectCode("stale_decision") { sdk.rollback(APP, "old-page-failed", oldCurrent, expectedEpoch) }
    assertEquals(state, f.stateFile().readText()); assertEquals("7", sdk.current(APP)?.context?.releaseId)
  }

  @Test fun `rollback missing unreadable or corrupt previous atomically falls back to embedded or sentinel`() {
    for (embedded in listOf(false, true)) for (corruption in listOf("missing", "manifest", "object")) fixture().use { f ->
      val sdk = f.sdk("A", embedded = embedded)
      if (corruption != "missing") f.install(sdk, "5", revision = "1")
      f.install(sdk, "6", revision = "2")
      if (corruption == "missing") {
        f.stateFile().writeText(OtaJson.stringify(f.state().toMutableMap().apply { remove("previous") }))
      } else {
        val previous = OtaJson.asObject(f.state()["previous"], "previous")
        val manifest = f.root.resolve("apps/$APP/manifests/${previous["manifestId"]}.json")
        if (corruption == "manifest") manifest.writeText("invalid-json")
        else {
          val record = OtaJson.asObject(OtaJson.parse(manifest.readText()), "manifest")
          val bundle = OtaJson.asObject(OtaJson.asArray(record["bundles"], "bundles")[0], "bundle")
          val hash = bundle["bundleSha256"].toString().removePrefix("sha256:")
          f.root.resolve("apps/$APP/objects/${hash.take(2)}/$hash.lynx.bundle").writeText("damaged")
        }
      }
      assertEquals(if (embedded) "embedded" else null, sdk.rollback(APP, "recover", "6", sdk.userIdentityEpoch)?.context?.releaseId)
      assertEquals("embedded", OtaJson.asObject(f.state()["current"], "current")["kind"])
    }
  }

  @Test fun `C16 directives survive restart reject old revision and allow server rollback lower sequence`() = fixture().use { f ->
    val sdk = f.sdk("A"); f.install(sdk, "5", revision = "10"); f.install(sdk, "10", revision = "11")
    f.api.selection = OtaLatestSelection.Release(f.latest("5", revision = "12", reason = "server_rollback")); sdk.syncLatestBundleList(APP)
    assertEquals("5", sdk.current(APP)?.context?.releaseId)
    f.api.selection = OtaLatestSelection.Directive(OtaSelectionDirective(APP, OtaSelectionAction.USE_EMBEDDED, "13", "forced")); sdk.syncLatestBundleList(APP)
    assertEquals("embedded", f.sdk("A").current(APP)?.context?.releaseId)
    f.api.selection = OtaLatestSelection.Release(f.latest("10", revision = "12"))
    expectCode("stale_decision") { sdk.syncLatestBundleList(APP) }
    assertEquals("embedded", sdk.rollback(APP, "manual")?.context?.releaseId)
  }

  @Test fun `C14 and C15 one changed object out of 100 with independent B authorization and zero copies`() = fixture().use { f ->
    val sdk = f.sdk("A"); f.api.selection = OtaLatestSelection.Release(f.latest("5", revision = "1", count = 100)); sdk.syncLatestBundleList(APP)
    f.api.selection = OtaLatestSelection.Release(f.latest("6", OtaSelectionKind.GRAY, "2", count = 100, reuseVersion = "5"))
    val result = sdk.syncLatestBundleList(APP)
    assertEquals(1, result.summary?.downloadedBundleCount); assertEquals(99, result.summary?.reusedBundleCount); assertEquals(0, result.summary?.copiedBundleCount)
    assertEquals(101, f.server.downloads.get()); assertEquals(101, f.snapshot().apps.single().objectCount)
    sdk.registerUserId("B")
    f.api.selection = OtaLatestSelection.Release(f.latest("6", revision = "3", count = 100, reuseVersion = "5")); sdk.syncLatestBundleList(APP)
    assertEquals("B", f.api.contexts.last().userId); assertEquals(101, f.server.downloads.get())
    assertEquals(OtaSelectionKind.FULL, sdk.current(APP)?.selection?.kind)
  }

  @Test fun `old v3 unknown metadata waits for new confirmation and reuses all CAS objects`() = fixture().use { f ->
    val legacy = f.sdk(null, code = null); f.api.selection = OtaLatestSelection.Release(f.latest("5", count = 100, metadata = false)); legacy.syncLatestBundleList(APP)
    val next = f.sdk("A"); assertEquals("embedded", next.current(APP)?.context?.releaseId)
    f.api.selection = OtaLatestSelection.Release(f.latest("5", revision = "1", count = 100)); next.syncLatestBundleList(APP)
    assertEquals(100, f.server.downloads.get()); assertEquals(100, next.current(APP)?.bundles?.size)
  }

  @Test fun `C09 live lease stays readable across account switch until close`() = fixture().use { f ->
    val sdk = f.sdk("A"); f.install(sdk, "5", revision = "1"); f.install(sdk, "6", OtaSelectionKind.GRAY, "2")
    val lease = sdk.acquireCurrentBundleLease(APP, BUNDLE)!!; val bytes = lease.file.readText()
    sdk.registerUserId("B"); sdk.reconcileUserContext(); f.install(sdk, "7", revision = "3"); f.install(sdk, "8", revision = "4")
    assertEquals(bytes, lease.file.readText()); lease.close(); assertFalse(lease.file.exists())
  }

  @Test fun `C21 native or SDK context change rechecks cold State compatibility`() = fixture().use { f ->
    val sdk = f.sdk("A"); f.install(sdk, "5", revision = "1")
    assertEquals("embedded", f.sdk("A", code = "30").current(APP)?.context?.releaseId)
    assertEquals("embedded", f.sdk("A", runtime = "4.2.0").current(APP)?.context?.releaseId)
    expectCode("invalid_sdk_version") { f.sdk("A", runtime = null).syncLatestBundleList(APP) }
  }

  @Test fun `batch commits all decisions before any bytes and retains every failed and completed App`() = fixture().use { f ->
    val sdk = f.sdk("A"); val first = f.latest("6"); val bad = f.latest("8", appId = "10000003"); val good = f.latest("7", appId = "10000004")
    val gate = SelectionGate(); f.server.pauses[first.changedBundles[0].bundleUrl.path] = gate
    f.server.failures.add(first.changedBundles[0].bundleUrl.path); f.server.failures.add(bad.changedBundles[0].bundleUrl.path)
    f.api.group = OtaModels.HostLatestBundleLists(ENV, HOST, PLATFORM, listOf(first, bad, good), 1,
      listOf(OtaSelectionDirective("10000002", OtaSelectionAction.USE_EMBEDDED, "1", "forced")))
    val pending = f.async { sdk.syncLatestBundleLists() }; gate.awaitStarted()
    val allDecisions = listOf(APP, "10000002", "10000003", "10000004").all { f.state(it)["lastDecision"] != null }
    gate.release.countDown(); assertTrue(allDecisions)
    try { pending.get(8, TimeUnit.SECONDS); fail("expected partial batch") } catch (error: ExecutionException) {
      val partial = error.cause as OtaHostBundleListSyncException
      assertEquals(setOf(APP, "10000003"), partial.failures.keys)
      assertEquals(setOf("10000002", "10000004"), partial.partialResult.results.keys)
    }
    assertEquals("7", sdk.current("10000004")?.context?.releaseId); assertNull(f.sdk("A").current("10000002"))
  }

  @Test fun `malformed later selection prevents any batch State change or byte download`() = fixture().use { f ->
    val sdk = f.sdk("A"); val before = f.stateFile().readText()
    f.api.group = OtaModels.HostLatestBundleLists(ENV, HOST, PLATFORM, listOf(f.latest("5"), f.latest("6", metadata = false, appId = "10000003")), 1,
      listOf(OtaSelectionDirective("10000002", OtaSelectionAction.USE_EMBEDDED, "1", "forced")))
    expectCode("missing_selection_metadata") { sdk.syncLatestBundleLists() }
    assertEquals(before, f.stateFile().readText()); assertEquals(0, f.server.downloads.get()); assertFalse(f.stateFile("10000002").exists())
  }

  @Test fun `query failure and candidate check reports use captured identity with sanitized diagnostics`() = fixture().use { f ->
    val raw = "synthetic-private-user-A"; val sdk = f.sdk(raw); val gate = SelectionGate()
    f.api.selection = OtaLatestSelection.Release(f.latest("5")); f.api.failure = OtaSdkException.invalidResponse(503, "userId=$raw"); f.api.pause = gate
    val pending = f.async { sdk.syncLatestBundleList(APP) }; gate.awaitStarted(); sdk.registerUserId("B"); gate.release.countDown()
    runCatching { pending.get(8, TimeUnit.SECONDS) }
    val failed = f.api.reports.single { it.event == OtaModels.ReportEvent.CHECK_RESULT }
    assertEquals(raw, failed.userId); assertEquals("25", failed.versioncode)
    assertFalse(failed.reasonMessage.orEmpty().contains(raw)); assertFalse(failed.message.orEmpty().contains(raw))
    f.api.failure = null
    val candidate = f.sdk("B", candidate = true); f.install(candidate, "6", OtaSelectionKind.GRAY, "2")
    assertTrue(f.api.reports.any { it.releaseId == "6" && it.event == OtaModels.ReportEvent.CHECK_RESULT && it.eventResult == OtaModels.ReportEventResult.SUCCESS && it.userId == "B" })
  }

  @Test fun `outer identity context cannot be replaced by B after probe and rejected leases close`() = fixture().use { f ->
    val sdk = f.sdk("A"); f.install(sdk, "5", revision = "1"); f.install(sdk, "6", revision = "2")
    val original = sdk.userIdentityEpoch; val gate = SelectionGate()
    val pending = f.async { sdk.withUserIdentity(original) { sdk.candidate(APP); gate.block(); sdk.rollback(APP, "old callback", "6", original) } }
    gate.awaitStarted(); sdk.registerUserId("B"); sdk.reconcileUserContext(); val state = f.stateFile().readText(); gate.release.countDown()
    expectCode("stale_identity") { pending.get(8, TimeUnit.SECONDS) }; assertEquals(state, f.stateFile().readText())
    val retained = AtomicReference<ReleaseTransaction.BundleLease>()
    expectCode("stale_identity") {
      sdk.withUserIdentity(sdk.userIdentityEpoch) { val lease = sdk.acquireCurrentBundleLease(APP, BUNDLE)!!; retained.set(lease); sdk.registerUserId("C"); lease }
    }
    assertFalse(f.snapshot().apps.single().releases.any { OtaStorageReleaseRole.LEASED in it.roles })
    retained.get().close()
  }

  @Test fun `Executor operation snapshots explicitly capture and restore ThreadLocal identity`() = fixture().use { f ->
    val box = OtaUserContextBox(f.configuration("A")); val a = box.capture()
    val executor = Executors.newSingleThreadExecutor()
    try {
      val snapshot = OtaOperationContext.withIdentity(a) { OtaOperationContext.snapshot() }
      box.register("B")
      assertEquals("A", executor.submit(Callable { OtaOperationContext.withSnapshot(snapshot) { OtaOperationContext.identity?.userId } }).get())
      assertNull(executor.submit(Callable { OtaOperationContext.identity }).get())
    } finally { executor.shutdownNow() }
  }

  private fun expectCode(code: String, operation: () -> Any?) {
    try { operation(); fail("expected $code") } catch (error: Throwable) {
      val cause = if (error is ExecutionException) error.cause else error
      assertEquals(code, (cause as? OtaSdkException)?.reasonCode)
    }
  }
}

private val ENV = OtaModels.Environment.TEST
private val HOST = OtaModels.HostApp.CAPP
private val PLATFORM = OtaModels.Platform.ANDROID
private const val APP = "10000001"
private const val BUNDLE = "main.lynx.bundle"

private class SelectionGate {
  val started = CountDownLatch(1); val release = CountDownLatch(1)
  fun block() { started.countDown(); if (!release.await(8, TimeUnit.SECONDS)) throw IOException("fixture gate timed out") }
  fun awaitStarted() { assertTrue("fixture operation did not reach gate", started.await(5, TimeUnit.SECONDS)) }
}

private class SelectionFault : ContentAddressedFaultInjecting {
  private var point: ContentAddressedFaultPoint? = null; private var skip = 0; private var callback: (() -> Unit)? = null
  @Synchronized fun arm(point: ContentAddressedFaultPoint, skip: Int = 0, callback: () -> Unit) { this.point = point; this.skip = skip; this.callback = callback }
  override fun check(point: ContentAddressedFaultPoint) {
    val action = synchronized(this) {
      if (this.point != point) null else if (skip > 0) { skip--; null } else callback.also { callback = null }
    }
    action?.invoke()
  }
}

private class SelectionApi : OtaApiClient {
  @Volatile var selection: OtaLatestSelection? = null
  @Volatile var group: OtaModels.HostLatestBundleLists? = null
  @Volatile var failure: Exception? = null
  @Volatile var pause: SelectionGate? = null
  val queryCount = AtomicInteger()
  val contexts = Collections.synchronizedList(mutableListOf<OtaUserContext>())
  val reports = Collections.synchronizedList(mutableListOf<OtaModels.ReportPayload>())
  private fun probe(context: OtaUserContext?) {
    queryCount.incrementAndGet(); if (context != null) contexts.add(context)
    val gate = synchronized(this) { pause.also { pause = null } }; val error = failure
    gate?.block(); if (error != null) throw error
  }
  override fun checkForUpdate(request: OtaModels.PolicyMatchRequest) = OtaModels.PolicyMatchResponse(false, null, null, null, null, null)
  override fun fetchManifest(releaseId: String, env: OtaModels.Environment, hostApp: OtaModels.HostApp, lynxAppId: String, platform: OtaModels.Platform) = (selection as OtaLatestSelection.Release).bundleList.asManifest()
  override fun fetchLatestBundleList(env: OtaModels.Environment, hostApp: OtaModels.HostApp, lynxAppId: String, platform: OtaModels.Platform): OtaModels.LatestBundleList {
    val result = selection as OtaLatestSelection.Release; probe(null); return result.bundleList
  }
  override fun fetchLatestBundleList(env: OtaModels.Environment, hostApp: OtaModels.HostApp, lynxAppId: String, platform: OtaModels.Platform, context: OtaUserContext): OtaLatestSelection {
    val result = requireNotNull(selection); probe(context); return result
  }
  override fun fetchLatestBundleLists(env: OtaModels.Environment, hostApp: OtaModels.HostApp, platform: OtaModels.Platform): OtaModels.HostLatestBundleLists {
    probe(null); return group ?: OtaModels.HostLatestBundleLists(env, hostApp, platform, listOf((selection as OtaLatestSelection.Release).bundleList))
  }
  override fun fetchLatestBundleLists(env: OtaModels.Environment, hostApp: OtaModels.HostApp, platform: OtaModels.Platform, context: OtaUserContext): OtaModels.HostLatestBundleLists {
    val result = group ?: OtaModels.HostLatestBundleLists(env, hostApp, platform, listOf((selection as OtaLatestSelection.Release).bundleList), 1)
    probe(context); return result
  }
  override fun reportEvent(payload: OtaModels.ReportPayload) { reports.add(payload) }
}

private class SelectionServer : Closeable {
  private val server = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
  private val executor = Executors.newCachedThreadPool { Thread(it, "ota-selection-http").apply { isDaemon = true } }
  private val sockets = ConcurrentHashMap.newKeySet<Socket>()
  @Volatile private var closed = false
  val base = URI.create("http://127.0.0.1:${server.localPort}")
  val bodies = ConcurrentHashMap<String, ByteArray>(); val pauses = ConcurrentHashMap<String, SelectionGate>()
  val failures = ConcurrentHashMap.newKeySet<String>(); val downloads = AtomicInteger()
  val queries = Collections.synchronizedList(mutableListOf<Map<String, String>>())
  val conditionals = Collections.synchronizedList(mutableListOf<String?>())
  @Volatile var response = "{}"
  init {
    executor.execute {
      while (!closed) {
        val socket = runCatching { server.accept() }.getOrNull() ?: break
        sockets.add(socket)
        executor.execute {
          try { handle(socket) } catch (_: Exception) { /* Cancellation closes the local socket. */ }
          finally { sockets.remove(socket); runCatching { socket.close() } }
        }
      }
    }
  }
  private fun handle(socket: Socket) {
    socket.soTimeout = 10_000
    val reader = socket.getInputStream().bufferedReader(Charsets.US_ASCII)
    val request = reader.readLine() ?: return
    val uri = URI.create(request.split(' ')[1])
    val headers = mutableMapOf<String, String>()
    while (true) {
      val line = reader.readLine() ?: break
      if (line.isEmpty()) break
      val index = line.indexOf(':')
      if (index > 0) headers[line.substring(0, index).lowercase()] = line.substring(index + 1).trim()
    }
    val status: Int; val body: ByteArray
    if (uri.path.startsWith("/bundle/")) {
      downloads.incrementAndGet(); pauses.remove(uri.path)?.block()
      body = bodies[uri.path] ?: "missing fixture".toByteArray()
      status = if (uri.path in failures) 503 else 200
    } else {
      val query = uri.rawQuery.orEmpty().split('&').filter { it.isNotEmpty() }.associate {
        val parts = it.split('=', limit = 2); URLDecoder.decode(parts[0], "UTF-8") to URLDecoder.decode(parts.getOrElse(1) { "" }, "UTF-8")
      }
      queries.add(query); val conditional = headers["if-none-match"]; conditionals.add(conditional)
      status = if (conditional != null) 304 else 200
      body = if (status == 304) byteArrayOf() else response.toByteArray()
    }
    val output = socket.getOutputStream()
    output.write(("HTTP/1.1 $status OK\r\nContent-Length: ${body.size}\r\nETag: fixture-etag\r\nConnection: close\r\n\r\n").toByteArray(Charsets.US_ASCII))
    output.write(body); output.flush()
  }
  override fun close() {
    closed = true; pauses.values.forEach { it.release.countDown() }; server.close()
    sockets.toList().forEach { runCatching { it.close() } }; executor.shutdownNow()
  }
}

private class SelectionFixture(val root: File) : Closeable {
  val server = SelectionServer(); val api = SelectionApi()
  private val workers = Executors.newCachedThreadPool { Thread(it, "ota-selection-test").apply { isDaemon = true } }
  fun <T> async(action: () -> T): Future<T> = workers.submit(Callable(action))
  fun configuration(user: String?, code: String? = "25", runtime: String? = "4.0.0", candidate: Boolean = false, storeVersion: OtaModels.StoreVersion = OtaModels.StoreVersion.V3) = OtaModels.Configuration(
    apiBaseUri = server.base, hostApp = HOST, lynxAppId = APP, environment = ENV, platform = PLATFORM,
    appVersion = "1.0.0", buildNumber = "legacy-build", userId = user, deviceId = null, deviceModel = null,
    osVersion = null, channel = null, region = null, nativeProtocolVersion = null, lynxSdkVersion = runtime,
    otaClientToken = null, storageDirectory = root, candidateActivationEnabled = candidate, storeVersion = storeVersion,
    allowLocalHTTPForTest = true, versionCode = code,
  )
  fun sdk(user: String?, code: String? = "25", runtime: String? = "4.0.0", candidate: Boolean = false, embedded: Boolean = true, fault: ContentAddressedFaultInjecting = ContentAddressedFaultInjecting.NONE): OtaSdk {
    val sdk = OtaSdk(configuration(user, code, runtime, candidate), api, fault)
    if (embedded) sdk.initializeEmbeddedRelease(OtaModels.InstalledRelease(OtaModels.CurrentReleaseContext(ENV, HOST, APP, "embedded", PLATFORM, OtaModels.ReleaseStatus.ACTIVE), Instant.EPOCH,
      listOf(OtaModels.InstalledBundle(1, BUNDLE, sha("embedded".toByteArray()), URI.create("asset:///bundles/$APP/$BUNDLE"), "asset:///bundles/$APP/$BUNDLE"))))
    return sdk
  }
  fun latest(version: String, kind: OtaSelectionKind = OtaSelectionKind.FULL, revision: String = "1", appId: String = APP, count: Int = 1, metadata: Boolean = true, reuseVersion: String? = null, reason: String? = null): OtaModels.LatestBundleList {
    val artifacts = (0 until count).map { index ->
      val bytesVersion = if (index == 50) version else reuseVersion ?: version
      val bytes = "version=$bytesVersion;bundle=$index".toByteArray(); val path = "/bundle/$appId/$version/$index"
      server.bodies[path] = bytes
      OtaModels.BundleArtifact(index + 1, if (count == 1) BUNDLE else "bundle-$index.lynx.bundle", sha(bytes), server.base.resolve(path), bytes.size)
    }
    return OtaModels.LatestBundleList(ENV, HOST, appId, version, PLATFORM, listOf(PLATFORM), OtaModels.ReleaseStatus.ACTIVE, null, null, null,
      OtaModels.ReleaseVersionRange("4.0", "4.1"), null, artifacts, if (metadata) 1 else null, if (metadata) version else null,
      if (metadata) OtaSelectionMetadata(kind, if (kind == OtaSelectionKind.GRAY) "test-rule" else null, revision, reason ?: if (kind == OtaSelectionKind.GRAY) "matched_gray" else "latest_full") else null,
      OtaVersionCodeRange("20", "29"))
  }
  fun install(sdk: OtaSdk, version: String, kind: OtaSelectionKind = OtaSelectionKind.FULL, revision: String) {
    api.selection = OtaLatestSelection.Release(latest(version, kind, revision)); sdk.syncLatestBundleList(APP)
  }
  fun stateFile(appId: String = APP) = root.resolve("apps/$appId/state.json")
  fun snapshot() = OtaStorageDiagnostics(root, 5000, OtaModels.StoreVersion.V3).snapshot()
  fun state(appId: String = APP) = OtaJson.asObject(OtaJson.parse(stateFile(appId).readText()), "state")
  fun wire(latest: OtaModels.LatestBundleList): Map<String, Any?> = latest.asManifest().toJsonMap() + mapOf(
    "selectionSchemaVersion" to latest.selectionSchemaVersion, "releaseSequence" to latest.releaseSequence,
    "selection" to latest.selection?.toJsonMap(), "versionCodeRange" to latest.versionCodeRange?.toJsonMap(),
    "lynxSdkRange" to mapOf("min" to "4.0", "max" to "4.1"), "changedBundles" to latest.changedBundles.map { it.toJsonMap() })
  override fun close() { api.pause?.release?.countDown(); server.close(); workers.shutdownNow() }
  private fun sha(bytes: ByteArray): String = "sha256:" + MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }
}
