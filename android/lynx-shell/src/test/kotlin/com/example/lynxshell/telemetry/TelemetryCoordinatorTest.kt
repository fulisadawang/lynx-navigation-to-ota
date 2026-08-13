package com.example.lynxshell.telemetry

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TelemetryCoordinatorTest {
    @Test
    fun pageOpenUsesAttemptSnapshotAndIsDeduplicated() {
        val sink = RecordingSink()
        val coordinator = coordinator(sink)
        coordinator.onNavigationAccepted()
        val generation = coordinator.beginRenderAttempt(
            attemptedSnapshot(candidateReleaseId = "release-a", expectedSha256 = "expected-a"),
        )
        coordinator.resolveBundle(
            generation,
            resolvedSnapshot(releaseId = "release-a", sha256 = "resolved-a", localPath = "/private/path/a"),
        )

        assertTrue(coordinator.onFirstScreen(generation))
        assertFalse(coordinator.onFirstScreen(generation))
        assertEquals(1, sink.events.count { it.eventName == "ota.page_open" })

        val open = sink.events.single { it.eventName == "ota.page_open" }
        assertEquals("release-a", open.resolvedBundle?.releaseId)
        assertEquals("resolved-a", open.resolvedBundle?.sha256)
        assertFalse(open.toWireMap().toString().contains("/private/path/a"))
    }

    @Test
    fun newRenderAttemptCreatesNewPageOpenKeyForSamePageView() {
        val sink = RecordingSink()
        val coordinator = coordinator(sink)
        coordinator.onNavigationAccepted()
        val first = coordinator.beginRenderAttempt(attemptedSnapshot("release-a", "sha-a"))
        coordinator.resolveBundle(first, resolvedSnapshot("release-a", "sha-a"))
        assertTrue(coordinator.onFirstScreen(first))

        val second = coordinator.beginRenderAttempt(attemptedSnapshot("release-b", "sha-b"))
        coordinator.resolveBundle(second, resolvedSnapshot("release-b", "sha-b"))
        assertTrue(coordinator.onFirstScreen(second))

        assertEquals(2, sink.events.count { it.eventName == "ota.page_open" })
        assertEquals(2, sink.events.mapNotNull { it.identity.renderAttemptId }.distinct().size)
    }

    @Test
    fun prepareFailureIsAttributedToAttemptedSnapshotOnly() {
        val sink = RecordingSink()
        val coordinator = coordinator(sink)
        val generation = coordinator.beginRenderAttempt(
            attemptedSnapshot(candidateReleaseId = "candidate-1", expectedSha256 = "expected-1"),
        )
        assertTrue(coordinator.failPrepare(generation, "sha_mismatch"))

        val failed = sink.events.single { it.eventName == "lynx.page.failed" }
        assertEquals("candidate-1", failed.attemptedBundle?.releaseId)
        assertEquals("expected-1", failed.attemptedBundle?.sha256)
        assertNull(failed.resolvedBundle)
        assertEquals("prepare", failed.attributes["failureStage"])
    }

    @Test
    fun staleRenderCallbackCannotReplaceResolvedBundle() {
        val sink = RecordingSink()
        val coordinator = coordinator(sink)
        val first = coordinator.beginRenderAttempt(attemptedSnapshot("release-a", "sha-a"))
        val second = coordinator.beginRenderAttempt(attemptedSnapshot("release-b", "sha-b"))

        assertFalse(coordinator.resolveBundle(first, resolvedSnapshot("release-a", "sha-a")))
        assertNull(coordinator.currentResolvedSnapshot())
        assertTrue(coordinator.resolveBundle(second, resolvedSnapshot("release-b", "sha-b")))
        assertEquals("release-b", coordinator.currentResolvedSnapshot()?.releaseId)
        assertTrue(sink.events.any { it.eventName == "telemetry.stale_callback_dropped" })
    }

    @Test
    fun navigationAdmissionAndTransitionTerminalRemainSeparate() {
        val sink = RecordingSink()
        val coordinator = coordinator(sink)
        coordinator.onNavigationRequested()
        coordinator.onNavigationAccepted()
        assertTrue(coordinator.onTransitionTerminal(TransitionTerminal.COMPLETED, durationMs = 120L))
        assertFalse(coordinator.onTransitionTerminal(TransitionTerminal.FAILED))

        assertEquals(
            listOf(
                "lynx.navigation.requested",
                "lynx.navigation.accepted",
                "lynx.transition.terminal",
            ),
            sink.events.map { it.eventName },
        )
        assertEquals("completed", sink.events.last().attributes["terminal"])
    }

    @Test
    fun samplingDecisionCarriesDenominatorForPageAndOpenEvents() {
        val sink = RecordingSink()
        val config = TelemetryConfig(
            samplingPolicy = SamplingPolicy(
                sampleRate = 0.5,
                samplingGroup = "page_quality",
                samplingRuleVersion = "v2",
                decisionOverride = { _, _ -> true },
            ),
        )
        val coordinator = coordinator(sink, config)
        val generation = coordinator.beginRenderAttempt(attemptedSnapshot("release-a", "sha-a"))
        coordinator.resolveBundle(generation, resolvedSnapshot("release-a", "sha-a"))
        coordinator.onFirstScreen(generation)

        val events = sink.events.filter { it.eventName in setOf("lynx.page.first_screen", "ota.page_open", "sampled_page_view") }
        assertEquals(3, events.size)
        assertTrue(events.all { it.sampling.sampleRate == 0.5 })
        assertTrue(events.all { it.sampling.samplingGroup == "page_quality" })
        assertTrue(events.all { it.sampling.samplingRuleVersion == "v2" })
    }

    @Test
    fun killSwitchDisablesOnlySelectedFeatureWithoutBlockingState() {
        val sink = RecordingSink()
        val coordinator = coordinator(
            sink,
            TelemetryConfig(killSwitches = setOf("page_open")),
        )
        coordinator.onApplicationLifecycle(AppLifecycleState.FOREGROUND)
        val generation = coordinator.beginRenderAttempt(attemptedSnapshot("release-a", "sha-a"))
        coordinator.resolveBundle(generation, resolvedSnapshot("release-a", "sha-a"))
        assertTrue(coordinator.onFirstScreen(generation))

        assertEquals(0, sink.events.count { it.eventName == "ota.page_open" })
        assertTrue(coordinator.activeEligible())
        assertTrue(sink.events.any { it.eventName == "lynx.page.first_screen" })
    }

    @Test
    fun exposureResumeRejectsOldObserverGeneration() {
        val sink = RecordingSink()
        val coordinator = coordinator(sink)
        val firstGeneration = coordinator.requestExposureResume()
        val secondGeneration = coordinator.requestExposureResume()

        assertFalse(coordinator.acceptExposureCallback(firstGeneration))
        assertTrue(coordinator.acceptExposureCallback(secondGeneration))
        assertTrue(sink.events.any { it.eventName == "lynx.exposure.resume_requested" })
        assertNotNull(sink.events.firstOrNull { it.eventName == "telemetry.stale_callback_dropped" })
    }

    @Test
    fun exposureTrackerResetsObserverAndDoesNotSynthesizeEnded() {
        val tracker = ExposureSessionTracker(
            exposureKey = "mall.product_card",
            contentId = "sku-1",
            reportOnce = false,
            idFactory = sequenceOf("session-1", "session-2").iterator()::next,
        )
        assertTrue(
            tracker.begin(
                callbackGeneration = 0L,
                initialRatio = 0.8,
                threshold = 0.5,
                minDurationMs = 1_000L,
                ruleVersion = "v1",
                nowMonotonicMs = 0L,
            ),
        )
        assertNotNull(tracker.qualifyIfDue(1_000L))
        val nextGeneration = tracker.resumeObserver()
        assertNull(tracker.end(ExposureEndReason.BACKGROUND, nowMonotonicMs = 2_000L))
        assertFalse(
            tracker.begin(
                callbackGeneration = 0L,
                initialRatio = 0.8,
                threshold = 0.5,
                minDurationMs = 1_000L,
                ruleVersion = "v1",
                nowMonotonicMs = 2_000L,
            ),
        )
        assertTrue(
            tracker.begin(
                callbackGeneration = nextGeneration,
                initialRatio = 0.8,
                threshold = 0.5,
                minDurationMs = 1_000L,
                ruleVersion = "v1",
                nowMonotonicMs = 2_000L,
            ),
        )
    }

    @Test
    fun sinkFailureIsFailOpen() {
        val coordinator = coordinator(TelemetrySink { error("debug sink failed") })
        coordinator.onNavigationRequested()
        val generation = coordinator.beginRenderAttempt(attemptedSnapshot("release-a", "sha-a"))
        assertTrue(coordinator.resolveBundle(generation, resolvedSnapshot("release-a", "sha-a")))
    }

    private fun coordinator(
        sink: RecordingSink,
        config: TelemetryConfig = TelemetryConfig(),
    ): TelemetryCoordinator = TelemetryCoordinator(
        pageIdentity = TelemetryIdentity.forPage(
            entryId = "entry-1",
            navigationId = "navigation-1",
            navigationSessionId = "session-1",
            pageViewId = "page-view-1",
        ),
        hostContext = TelemetryHostContext(
            telemetryRouteKey = "10000001/home.lynx.bundle",
            hostMode = "activity",
            platform = "android",
            lynxSdkVersion = "4.0.0",
        ),
        sink = sink,
        config = config,
        clock = FixedClock(),
        idFactory = sequenceOf(
            "attempt-1",
            "activation-1",
            "attempt-2",
            "activation-2",
        ).iterator()::next,
    )

    private fun attemptedSnapshot(
        candidateReleaseId: String? = "release-a",
        expectedSha256: String? = "sha-a",
    ) = AttemptedBundleSnapshot(
        bundleSource = TelemetryBundleSource.OTA,
        lynxAppId = "10000001",
        bundleName = "home.lynx.bundle",
        telemetryRouteKey = "10000001/home.lynx.bundle",
        candidateReleaseId = candidateReleaseId,
        expectedSha256 = expectedSha256,
        prepareStartedAtUnixMs = 1_000L,
        attemptGeneration = 0L,
    )

    private fun resolvedSnapshot(
        releaseId: String? = "release-a",
        sha256: String? = "sha-a",
        localPath: String? = null,
    ) = ResolvedBundleSnapshot(
        bundleSource = TelemetryBundleSource.OTA,
        lynxAppId = "10000001",
        bundleName = "home.lynx.bundle",
        telemetryRouteKey = "10000001/home.lynx.bundle",
        releaseId = releaseId,
        bundleSha256 = sha256,
        resolvedAtUnixMs = 1_100L,
        internalLocalPath = localPath,
    )

    private class RecordingSink : TelemetrySink {
        val events = mutableListOf<TelemetryEvent>()

        override fun emit(event: TelemetryEvent) {
            events += event
        }
    }

    private class FixedClock : TelemetryClock {
        override fun nowUnixMillis(): Long = 1_000L

        override fun nowMonotonicMillis(): Long = 10L
    }
}
