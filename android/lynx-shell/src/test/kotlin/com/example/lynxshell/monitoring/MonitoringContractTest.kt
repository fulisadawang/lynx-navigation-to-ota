package com.example.lynxshell.monitoring

import com.example.lynxshell.ota.PreparedActivityBundle
import com.lynx.tasm.performance.performanceobserver.LoadBundleEntry
import com.lynx.tasm.performance.performanceobserver.PipelineEntry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CompletionStage
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class MonitoringContractTest {
    @Test fun utf8LimitDoesNotSplitEmojiAndChinese() {
        assertEquals("汉😀", utf8Prefix("汉😀字", 7))
        assertEquals("汉", utf8Prefix("汉😀字", 6))
        assertEquals(7, utf8Prefix("汉😀字", 7).toByteArray(Charsets.UTF_8).size)
    }

    @Test fun privacyKeepsDebugKeyAndRemovesQueriesAndCredentials() {
        val policy = MonitorTextPolicy(listOf("customer-private"))
        val value = policy.sanitize("customer-private token=abc https://cdn.example/main.js?secret=1#frag debugmetadata:abc-123")
        assertFalse(value.contains("customer-private"))
        assertFalse(value.contains("secret=1"))
        assertFalse(value.contains("token=abc"))
        assertTrue(value.contains("debugmetadata:abc-123"))
    }

    @Test fun mainThreadNumbersWithoutFormatEvidenceRemainReportedForLaterSymbolication() {
        val frames = MonitorProjection.parseFrames("    at handler (file:///main-thread.js:23:13)", "debugmetadata:key1", mutableListOf())
        assertEquals(1, frames.size)
        assertEquals(ErrorPosition.Reported(23, 13), frames.single().position)
        assertEquals("key1", frames.single().debugKey)
        val explicit = MonitorProjection.parseFrames("function_id:23 pc_index:13 debugmetadata:key2", null, mutableListOf())
        assertEquals(ErrorPosition.FunctionPc(23, 13), explicit.single().position)
    }

    @Test fun backgroundFramePreservesColumnZero() {
        val frames = MonitorProjection.parseFrames("    at click (file:///background.js:20:0)", "debugmetadata:text-key", mutableListOf(),
            ScriptPositionFormats(mapOf("text-key" to ScriptPositionFormat.LINE_COLUMN)))
        assertEquals(ErrorPosition.LineColumn(20, 0), frames.single().position)
        val unknown = MonitorProjection.parseFrames("    at click (file:///background.js:20:0)", null, mutableListOf())
        assertEquals(ErrorPosition.Reported(20, 0), unknown.single().position)
    }

    @Test fun sdkStructuredFramesKeepPerFrameDebugKeysAndReportedPositions() {
        val report = """
            {"error":{"rawError":{"message":"tap token=private","stack":"at ignored (file:///fallback.js:1:2)"},
            "sentry":{"exception":{"values":[{"stacktrace":{"frames":[
              {"filename":"file:///main-thread.js?token=secret","function":"runMain","release":"debugmetadata:main-key","lineno":23,"colno":13},
              {"filename":"file:///background.js","function":"runBackground","release":"debugmetadata:background-key","lineno":"41","colno":"0"}
            ]}}]}}}}
        """.trimIndent()

        val projection = MonitorProjection.error(
            CapturedJsError("1101", "110100", "error", "main_thread", report, report, false),
            MonitorTextPolicy(),
            "running",
            ScriptPositionFormats(mapOf("main-key" to ScriptPositionFormat.FUNCTION_PC)),
        )

        val payload = projection.payload
        assertEquals("tap token=[redacted]", payload.message)
        assertEquals(2, payload.frames.size)
        assertEquals("main-key", payload.frames[0].debugKey)
        assertEquals(ErrorPosition.FunctionPc(23, 13), payload.frames[0].position)
        assertEquals("background-key", payload.frames[1].debugKey)
        assertEquals(ErrorPosition.Reported(41, 0), payload.frames[1].position)
        assertFalse(payload.frames[0].file.orEmpty().contains("token=secret"))
    }

    @Test fun nestedSdkJsonUsesRawErrorWithoutForwardingWrapperText() {
        val report = """
            {"error":{"rawError":{"message":"operation token=secret","stack":"at task (file:///main.js:8:2)"},
            "sentry":{"exception":{"values":[]}},"ignored_wrapper":"must_not_leave_device"}}
        """.trimIndent()

        val projection = MonitorProjection.error(
            CapturedJsError("100", "0", "error", "background", report, report, false),
            MonitorTextPolicy(),
            "running",
            ScriptPositionFormats(),
        )
        val event = monitorEvent(identity(), projection.payload)
        val json = event.toJson()

        assertEquals("operation token=[redacted]", projection.payload.message)
        assertEquals("at task (file:///main.js:8:2)", projection.payload.rawStack)
        assertFalse(json.contains("ignored_wrapper"))
        assertFalse(json.contains("must_not_leave_device"))
        assertFalse(json.contains("token=secret"))
    }

    @Test fun structuredSdkFramesHonorBoundAndExposeTruncation() {
        val frames = org.json.JSONArray()
        repeat(65) { index ->
            frames.put(JSONObject()
                .put("filename", "file:///background-$index.js")
                .put("function", "handler$index")
                .put("release", "debugmetadata:key-$index")
                .put("lineno", index + 1)
                .put("colno", 0))
        }
        val report = JSONObject().put("error", JSONObject()
            .put("rawError", JSONObject().put("message", "many frames").put("stack", "at fallback (file:///fallback.js:1:2)"))
            .put("sentry", JSONObject().put("exception", JSONObject().put("values", org.json.JSONArray().put(
                JSONObject().put("stacktrace", JSONObject().put("frames", frames)),
            ))))).toString()

        val projection = MonitorProjection.error(
            CapturedJsError("100", "0", "error", "background", report, report, true),
            MonitorTextPolicy(),
            "running",
            ScriptPositionFormats(),
        )

        assertEquals(64, projection.payload.frames.size)
        assertEquals("key-0", projection.payload.frames.first().debugKey)
        assertTrue("frames" in projection.truncated)
        assertTrue("sdk_error_input" in projection.truncated)
    }

    @Test fun preparedOtaIdentityFreezesScopeAndBundlePathIntoProviderJson() {
        val prepared = PreparedActivityBundle(
            lynxAppId = "travel-app",
            bundleName = "HomePage.lynx.bundle",
            bytes = "bundle".toByteArray(),
            releaseId = "release-3",
            releaseSequence = "3",
            sha256 = "a".repeat(64),
            env = "production",
            hostApp = "travel-ios-android",
            bundlePath = "pages/home/HomePage.lynx.bundle",
        )

        val identity = BundleIdentities.prepared(prepared)
        val bundle = JSONObject(monitorEvent(identity).toJson()).getJSONObject("bundle")

        assertEquals("travel-app", bundle.getString("lynxAppId"))
        assertEquals("HomePage.lynx.bundle", bundle.getString("bundleName"))
        assertEquals("release-3", bundle.getString("releaseId"))
        assertEquals("production", bundle.getString("env"))
        assertEquals("travel-ios-android", bundle.getString("hostApp"))
        assertEquals("pages/home/HomePage.lynx.bundle", bundle.getString("bundlePath"))
        assertEquals("verified", bundle.getString("identityStatus"))
    }

    @Test fun invalidOtaScopeFieldsAreRemovedAndSurfacedInEventQuality() {
        val identity = BundleIdentities.prepared(PreparedActivityBundle(
            lynxAppId = "travel-app",
            bundleName = "HomePage.lynx.bundle",
            bytes = "bundle".toByteArray(),
            sha256 = "a".repeat(64),
            env = " ",
            hostApp = "汉".repeat(683),
            bundlePath = "pages/home/HomePage.lynx.bundle",
        ))
        assertNull(identity.env)
        assertNull(identity.hostApp)
        assertTrue("bundle.env" in identity.identityInvalidFields)
        assertTrue("bundle.hostApp" in identity.identityTruncatedFields)

        val provider = WaitingProvider()
        val runtime = runtime(provider)
        runtime.start()
        requireNotNull(runtime.reserve(ContainerKind.PAGE, LoadKind.INITIAL, identity, Visibility.VISIBLE))
        provider.awaitEvents = CountDownLatch(1)
        provider.ready.complete(InitResult("ready"))
        assertTrue(provider.awaitEvents.await(5, TimeUnit.SECONDS))

        val event = provider.snapshot().single()
        assertTrue("bundle.env" in event.quality.invalidFields)
        assertTrue("bundle.hostApp" in event.quality.truncatedFields)
        val bundle = JSONObject(event.toJson()).getJSONObject("bundle")
        assertTrue(bundle.isNull("env"))
        assertTrue(bundle.isNull("hostApp"))
        runtime.dispose()
    }

    @Test fun preparedBundlePathRejectsNonLogicalOrAmbiguousValues() {
        val invalidPaths = listOf(
            "/pages/home.lynx.bundle",
            "\\pages\\home.lynx.bundle",
            "pages\\home.lynx.bundle",
            "pages\u0000home.lynx.bundle",
            "./pages/home.lynx.bundle",
            "pages/../home.lynx.bundle",
            "pages/./home.lynx.bundle",
            "https://cdn.example/home.lynx.bundle",
        )

        invalidPaths.forEach { bundlePath ->
            val identity = BundleIdentities.prepared(PreparedActivityBundle(
                lynxAppId = "travel-app",
                bundleName = "HomePage.lynx.bundle",
                bytes = "bundle".toByteArray(),
                sha256 = "a".repeat(64),
                env = "test",
                hostApp = "travel-app",
                bundlePath = bundlePath,
            ))
            assertNull("$bundlePath must not reach Provider", identity.bundlePath)
            assertTrue("bundle.bundlePath" in identity.identityInvalidFields)
        }
    }

    @Test fun invalidSdkDebugMetadataNeverReachesProviderProjection() {
        val queryRelease = "debugmetadata:main-key?access_token=private"
        val overlongRelease = "debugmetadata:" + "a".repeat(1025)
        val frames = org.json.JSONArray()
            .put(JSONObject().put("filename", "file:///main.js").put("release", queryRelease).put("lineno", 1).put("colno", 2))
            .put(JSONObject().put("filename", "file:///other.js").put("release", overlongRelease).put("lineno", 3).put("colno", 4))
        val report = JSONObject().put("error", JSONObject()
            .put("release", queryRelease)
            .put("rawError", JSONObject().put("message", "bad release").put("stack", "at render (file:///fallback.js:5:6)"))
            .put("sentry", JSONObject().put("exception", JSONObject().put("values", org.json.JSONArray().put(
                JSONObject().put("stacktrace", JSONObject().put("frames", frames)),
            ))))).toString()

        val projection = MonitorProjection.error(
            CapturedJsError("100", "0", "error", "background", report, report, false),
            MonitorTextPolicy(),
            "running",
            ScriptPositionFormats(),
        )
        val stackFrames = MonitorProjection.parseFrames(
            "at render (file:///fallback.js:5:6) $queryRelease",
            null,
            mutableListOf(),
        )
        val json = monitorEvent(identity(), projection.payload).toJson()

        assertTrue("sdk_release" in projection.invalid)
        assertTrue("frames.release" in projection.invalid)
        assertTrue(projection.payload.frames.all { it.runtimeRelease == null && it.debugKey == null })
        assertNull(stackFrames.single().runtimeRelease)
        assertNull(stackFrames.single().debugKey)
        assertFalse(json.contains("access_token"))
        assertFalse(json.contains(overlongRelease))
    }

    @Test fun performanceDistinguishesMissingInvalidAndRealZero() {
        val raw = hashMapOf<String, Any>("name" to "pipeline", "entryType" to "pipeline", "identifier" to "op-1",
            "pipelineStart" to 10.0, "pipelineEnd" to 10.0, "layoutStart" to -1.0, "layoutEnd" to 30.0,
            "mtsRenderStart" to Double.NaN, "mtsRenderEnd" to 30.0)
        val projection = requireNotNull(MonitorProjection.performance(PipelineEntry(raw)))
        assertEquals(0.0, projection.payload.metrics.single { it.name == "pipeline_ms" }.value, 0.0)
        assertTrue("layoutStart" in projection.invalid)
        assertTrue("resolveStart" in projection.missing)
        assertTrue("mtsRenderStart" in projection.invalid)
        assertFalse(projection.payload.metrics.any { it.name == "layout_ms" })
    }

    @Test fun initializationQueueIsBoundedAndDropsPerformanceFirst() {
        val provider = WaitingProvider()
        val runtime = runtime(provider)
        runtime.start()
        val binding = requireNotNull(runtime.reserve(ContainerKind.PAGE, LoadKind.INITIAL, identity(), Visibility.HIDDEN))
        repeat(160) { binding.performance(pipeline(it.toDouble())) }
        val diagnostics = runtime.diagnostics()
        assertEquals(128, diagnostics.queuedEvents)
        assertTrue(diagnostics.queuedBytes <= MAX_QUEUE_BYTES)
        assertTrue((diagnostics.counters["dropped.lynx.performance"] ?: 0) > 0)
        provider.awaitEvents = CountDownLatch(128)
        provider.ready.complete(InitResult("ready"))
        assertTrue(provider.awaitEvents.await(5, TimeUnit.SECONDS))
        assertEquals(EventType.LOAD, provider.snapshot().first().eventType)
        assertEquals(128, provider.snapshot().size)
        runtime.dispose()
    }

    @Test fun frozenDirectIdentityIsNotBackfilledIntoStartedEvent() {
        val provider = WaitingProvider()
        val runtime = runtime(provider)
        runtime.start()
        val binding = requireNotNull(runtime.reserve(ContainerKind.TAB, LoadKind.INITIAL, identity(), Visibility.HIDDEN))
        binding.bytesResolved("hello".toByteArray())
        binding.visibility(Visibility.VISIBLE)
        // reserve 尚未 attach 到真实 LynxView；创建前的 visible 只更新目标状态，不发送生命周期事件。
        provider.awaitEvents = CountDownLatch(2)
        provider.ready.complete(InitResult("ready"))
        assertTrue(provider.awaitEvents.await(5, TimeUnit.SECONDS))
        val events = provider.snapshot()
        assertNull(events.first().bundle?.sha256)
        assertEquals("computed", events[1].bundle?.identityStatus)
        assertEquals("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", events[1].bundle?.sha256)
        assertEquals(events.first().viewId, events.last().viewId)
        assertEquals(events.first().loadId, events.last().loadId)
        val json = JSONObject(events[1].toJson())
        assertEquals("1.0", json.getString("schemaVersion"))
        assertTrue(json.isNull("nativeInstanceId"))
        assertTrue(events[1].wireBytes() >= events[1].toJson().toByteArray(Charsets.UTF_8).size)
        runtime.dispose()
    }

    @Test fun sameViewReloadNeverReassignsEventsToLaterPreparedBundle() {
        val provider = WaitingProvider()
        val runtime = runtime(provider)
        runtime.start()
        val first = PreparedActivityBundle(
            lynxAppId = "travel-app", bundleName = "HomePage.lynx.bundle", bytes = byteArrayOf(1, 2),
            releaseId = "release-1", sha256 = "a".repeat(64), env = "test", hostApp = "host", bundlePath = "home.lynx.bundle",
        )
        val later = first.copy(releaseId = "release-2", sha256 = "b".repeat(64))
        val binding = requireNotNull(runtime.reserve(ContainerKind.TAB, LoadKind.INITIAL, BundleIdentities.prepared(first), Visibility.VISIBLE))
        binding.resolvePrepared(first)
        binding.pageStarted(false)
        binding.pageStarted(true)
        binding.resolvePrepared(later)
        binding.performance(pipeline(10.0))
        binding.performance(pipeline(20.0))
        provider.awaitEvents = CountDownLatch(5)
        provider.ready.complete(InitResult("ready"))
        assertTrue(provider.awaitEvents.await(5, TimeUnit.SECONDS))
        provider.snapshot().takeLast(2).forEach {
            assertEquals("exact_view", it.quality.association)
            assertNull(it.loadId); assertNull(it.loadKind); assertNull(it.bundle)
            assertTrue("ambiguous_load" in it.quality.missingFields)
            assertFalse(it.toJson().contains("release-2"))
        }
        runtime.dispose()
    }

    @Test fun performanceRateZeroStillRecordsFirstContentAndCloseIsIdempotent() {
        val provider = WaitingProvider()
        val runtime = runtime(provider, 0.0)
        runtime.start()
        val binding = requireNotNull(runtime.reserve(ContainerKind.PAGE, LoadKind.INITIAL, identity(), Visibility.VISIBLE))
        binding.performance(LoadBundleEntry(hashMapOf("name" to "loadBundle", "entryType" to "pipeline",
            "lynxFcp" to hashMapOf<String, Any>("duration" to 0.0))))
        binding.firstContent()
        binding.failed("late_error")
        binding.close(); binding.close()
        binding.performance(pipeline(1.0))
        provider.awaitEvents = CountDownLatch(2)
        provider.ready.complete(InitResult("ready"))
        assertTrue(provider.awaitEvents.await(5, TimeUnit.SECONDS))
        assertEquals(listOf("started", "first_content"), provider.snapshot().map { (it.payload as LoadPayload).phase })
        assertEquals(1L, runtime.diagnostics().counters["callback_after_close"])
        runtime.dispose()
    }

    @Test fun failedInitializationDiscardsPendingAndDoesNotKeepCollecting() {
        val provider = WaitingProvider()
        val runtime = runtime(provider)
        runtime.start()
        val binding = requireNotNull(runtime.reserve(ContainerKind.PAGE, LoadKind.INITIAL, identity(), Visibility.VISIBLE))
        provider.ready.complete(InitResult("failed", "fixture"))
        assertEquals("failed", runtime.initialization.get(5, TimeUnit.SECONDS).state)
        binding.visibility(Visibility.HIDDEN)
        assertEquals("failed", runtime.diagnostics().state)
        assertEquals(0, runtime.diagnostics().queuedEvents)
        assertEquals(1L, runtime.diagnostics().counters["discarded_initialization"])
        assertTrue(provider.snapshot().isEmpty())
        assertTrue(provider.disposed.await(5, TimeUnit.SECONDS))
        assertEquals(1, provider.disposeCount.get())
        runtime.dispose()
        assertEquals(1, provider.disposeCount.get())
    }

    @Test fun throwingProviderDoesNotBlockFollowingEvent() {
        val provider = WaitingProvider(throwFirst = true)
        val runtime = runtime(provider)
        runtime.start()
        val binding = requireNotNull(runtime.reserve(ContainerKind.PAGE, LoadKind.INITIAL, identity(), Visibility.HIDDEN))
        binding.bytesResolved(byteArrayOf(1, 2, 3))
        provider.awaitEvents = CountDownLatch(2)
        provider.ready.complete(InitResult("ready"))
        assertTrue(provider.awaitEvents.await(5, TimeUnit.SECONDS))
        assertEquals(1L, runtime.diagnostics().counters["handoff.provider_error"])
        assertEquals(1, provider.snapshot().size)
        assertEquals(EventType.LOAD, provider.snapshot().single().eventType)
        runtime.dispose()
    }

    @Test fun diagnosticProviderBoundUsesEncodedBytes() {
        val provider = DiagnosticProvider()
        val payload = JsErrorPayload("200", null, "error", "background", "汉".repeat(1000),
            "😀".repeat(4000), emptyList(), phase = "running")
        val event = MonitorEvent("11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222",
            1, "4.1.0", "42", "33333333-3333-4333-8333-333333333333", null, ContainerKind.PAGE,
            "44444444-4444-4444-8444-444444444444", LoadKind.INITIAL, identity(), Visibility.VISIBLE,
            EventQuality("exact_load"), Sampling("none", 1.0), payload)
        repeat(32) { assertEquals(HandoffResult.RECORDED_LOCALLY, provider.record(event)) }
        assertTrue(provider.snapshot().sumOf { it.wireBytes() } <= MAX_QUEUE_BYTES)
        assertTrue(provider.discardedCount() > 0)
        assertTrue(event.wireBytes() >= event.toJson().toByteArray(Charsets.UTF_8).size)
    }

    @Test fun diagnosticProviderKeepsResourceEventAlongsideJsError() {
        val provider = DiagnosticProvider()
        val resource = MonitorEvent("11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222",
            1, "4.1.0", "42", "33333333-3333-4333-8333-333333333333", null, ContainerKind.PAGE,
            "44444444-4444-4444-8444-444444444444", LoadKind.INITIAL, identity(), Visibility.VISIBLE,
            EventQuality("exact_load"), Sampling("none", 1.0), ResourcePayload("image", "failed", errorCode = "404"))
        val jsError = MonitorEvent("55555555-5555-4555-8555-555555555555", "22222222-2222-4222-8222-222222222222",
            2, "4.1.0", "42", "33333333-3333-4333-8333-333333333333", null, ContainerKind.PAGE,
            "44444444-4444-4444-8444-444444444444", LoadKind.INITIAL, identity(), Visibility.VISIBLE,
            EventQuality("exact_load"), Sampling("none", 1.0),
            JsErrorPayload("200", null, "error", "background", "fixture", "", emptyList(), phase = "running"))

        assertEquals(HandoffResult.RECORDED_LOCALLY, provider.record(resource))
        assertEquals(HandoffResult.RECORDED_LOCALLY, provider.record(jsError))
        assertEquals(listOf(EventType.RESOURCE, EventType.JS_ERROR), provider.snapshot().map { it.eventType })
        val json = JSONObject(provider.snapshot().first().toJson())
        assertEquals("failed", json.getJSONObject("payload").getString("outcome"))
    }

    @Test fun largeDeferredErrorKeepsLateStackAndDebugKeyOffCallerThread() {
        val provider = WaitingProvider()
        val runtime = MonitorRuntime(HostContext("fixture.host", "42", "4.1.0", "22222222-2222-4222-8222-222222222222"),
            MonitorConfig(provider = provider, scriptPositionFormats = ScriptPositionFormats(mapOf("main-key" to ScriptPositionFormat.FUNCTION_PC))))
        runtime.start()
        val envelope = MonitorEvent("11111111-1111-4111-8111-111111111111", runtime.host.processSessionId,
            1234, "4.1.0", "42", "33333333-3333-4333-8333-333333333333", "17", ContainerKind.PAGE,
            "44444444-4444-4444-8444-444444444444", LoadKind.INITIAL, identity(), Visibility.VISIBLE,
            EventQuality("exact_load"), Sampling("none", 1.0), JsErrorPayload("1101", "110100", "error", "main_thread", "", null, emptyList(), phase = "running"))
        val raw = "{\"ignored_wrapper\":\"${"x".repeat(40 * 1024)}\",\"error_stack\":" +
            JSONObject.quote("    at click (file:///main-thread.js:23:13)") + ",\"release\":\"debugmetadata:main-key\"}"
        assertTrue(raw.indexOf("error_stack") > 24 * 1024)
        runtime.enqueueError(envelope, CapturedJsError("1101", "110100", "error", "main_thread", "token=secret", raw, false), "running")
        assertTrue(runtime.diagnostics().queuedBytes > MAX_EVENT_BYTES)
        assertTrue(runtime.diagnostics().queuedBytes <= MAX_QUEUE_BYTES)
        provider.awaitEvents = CountDownLatch(1)
        provider.ready.complete(InitResult("ready"))
        assertTrue(provider.awaitEvents.await(5, TimeUnit.SECONDS))
        val event = provider.snapshot().single()
        assertEquals(envelope.eventId, event.eventId)
        assertEquals(1234L, event.observedAtMs)
        assertEquals(envelope.viewId, event.viewId)
        assertEquals(envelope.loadId, event.loadId)
        val payload = event.payload as JsErrorPayload
        assertFalse(payload.message.contains("secret"))
        assertEquals(ErrorPosition.FunctionPc(23, 13), payload.frames.single().position)
        assertEquals("main-key", payload.frames.single().debugKey)
        assertTrue(event.wireBytes() < MAX_EVENT_BYTES)
        assertFalse(event.toJson().contains("ignored_wrapper"))
        assertTrue(provider.recordThread.startsWith("lynx-monitor-provider"))
        runtime.dispose()
    }

    private fun runtime(provider: WaitingProvider, rate: Double = 1.0) = MonitorRuntime(
        HostContext("fixture.host", "42", "4.1.0", "22222222-2222-4222-8222-222222222222"),
        MonitorConfig(provider = provider, performanceSampleRate = rate),
    )
    private fun identity() = BundleIdentity("direct_asset", null, "fixture.lynx.bundle")
    private fun monitorEvent(identity: BundleIdentity, payload: MonitorPayload = JsErrorPayload(
        "100", null, "error", "background", "fixture", null, emptyList(), phase = "running",
    )) = MonitorEvent(
        "11111111-1111-4111-8111-111111111111",
        "22222222-2222-4222-8222-222222222222",
        1,
        "4.1.0",
        "42",
        "33333333-3333-4333-8333-333333333333",
        null,
        ContainerKind.PAGE,
        "44444444-4444-4444-8444-444444444444",
        LoadKind.INITIAL,
        identity,
        Visibility.VISIBLE,
        EventQuality("exact_load"),
        Sampling("none", 1.0),
        payload,
    )
    private fun pipeline(start: Double) = PipelineEntry(hashMapOf("name" to "pipeline", "entryType" to "pipeline",
        "pipelineStart" to start, "pipelineEnd" to start + 1))

    private class WaitingProvider(private var throwFirst: Boolean = false) : RuntimeProvider {
        override val id = "waiting_fixture"
        override val capabilities = ProviderCapabilities(EventType.values().toSet(), true, true, false, false)
        val ready = CompletableFuture<InitResult>()
        val initialized = CountDownLatch(1)
        val disposed = CountDownLatch(1)
        val disposeCount = java.util.concurrent.atomic.AtomicInteger()
        @Volatile var awaitEvents = CountDownLatch(0)
        @Volatile var recordThread = ""
        private val events = java.util.Collections.synchronizedList(mutableListOf<MonitorEvent>())
        override fun initialize(context: HostContext): CompletionStage<InitResult> { initialized.countDown(); return ready }
        override fun record(event: MonitorEvent): HandoffResult {
            recordThread = Thread.currentThread().name
            if (throwFirst) { throwFirst = false; awaitEvents.countDown(); throw IllegalStateException("fixture") }
            events.add(event); awaitEvents.countDown(); return HandoffResult.RECORDED_LOCALLY
        }
        fun snapshot(): List<MonitorEvent> = synchronized(events) { events.toList() }
        override fun dispose() { disposeCount.incrementAndGet(); disposed.countDown() }
    }
}
