package com.example.lynxshell.transition

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LynxBottomSheetMotionTest {
    @Test
    fun endpointsAreExactSoCancellationCanRestoreTheOpenedSheet() {
        val dismissed = LynxBottomSheetMotion.state(0f)
        assertEquals(1f, dismissed.sheetTranslationFraction, 0.0001f)
        assertEquals(1f, dismissed.backdropScale, 0.0001f)
        assertEquals(0f, dismissed.barrierAlpha, 0.0001f)

        val opened = LynxBottomSheetMotion.state(1f)
        assertEquals(0f, opened.sheetTranslationFraction, 0.0001f)
        assertEquals(0.94f, opened.backdropScale, 0.0001f)
        assertEquals(10f, opened.backdropTranslationYDp, 0.0001f)
        assertEquals(18f, opened.backdropCornerRadiusDp, 0.0001f)
        assertEquals(1f, opened.barrierAlpha, 0.0001f)
    }

    @Test
    fun halfProgressKeepsSheetBackdropAndBarrierOnOneTimeline() {
        val state = LynxBottomSheetMotion.state(0.5f)

        assertEquals(0.5f, state.sheetTranslationFraction, 0.0001f)
        assertEquals(0.97f, state.backdropScale, 0.0001f)
        assertEquals(5f, state.backdropTranslationYDp, 0.0001f)
        assertEquals(9f, state.backdropCornerRadiusDp, 0.0001f)
        assertEquals(0.5f, state.barrierAlpha, 0.0001f)
    }

    @Test
    fun dragProgressUsesSheetHeightAndClampsAtBothEnds() {
        assertEquals(0f, LynxBottomSheetMotion.dragProgress(-10f, 600f), 0.0001f)
        assertEquals(0.5f, LynxBottomSheetMotion.dragProgress(300f, 600f), 0.0001f)
        assertEquals(1f, LynxBottomSheetMotion.dragProgress(900f, 600f), 0.0001f)
    }

    @Test
    fun defaultBottomSheetIsNonOpaqueDismissibleAndVerticallyDraggable() {
        val spec = LynxTransitionSpec.fromOptions(
            JSONObject().put("routeType", "wx://bottom-sheet"),
            animated = true,
        )

        assertFalse(spec.routeConfig.opaque)
        assertTrue(spec.routeConfig.barrierDismissible)
        assertEquals(LynxPopGestureDirection.VERTICAL, spec.popGesture.direction)
        assertTrue(spec.popGesture.fullScreen)
        assertEquals(92f, spec.routeOptions.heightVh, 0.0001f)
        assertTrue(spec.routeOptions.round)
    }

    @Test
    fun heroSheetUsesThreeDetentsAndStartsAtTheMiddleDetent() {
        val spec = LynxTransitionSpec.fromOptions(
            JSONObject().put("routeType", "wx://hero-sheet"),
            animated = true,
        )

        assertEquals(LynxRoutePreset.HERO_SHEET, spec.routePreset)
        assertEquals(listOf(28f, 56f, 100f), spec.routeOptions.detentsVh)
        assertEquals(56f, spec.routeOptions.initialDetentVh, 0.0001f)
        assertEquals(1, spec.routeOptions.initialDetentIndex)
        assertTrue(spec.routeOptions.isMultiDetent)
    }

    @Test
    fun customDetentsRequireTheInitialDetentToBeOneOfTheDeclaredHeights() {
        val spec = LynxTransitionSpec.fromOptions(
            JSONObject()
                .put("routeType", "wx://hero-sheet")
                .put(
                    "routeOptions",
                    JSONObject()
                        .put("detents", org.json.JSONArray(listOf(24, 48, 100)))
                        .put("initialDetent", 48),
                ),
            animated = true,
        )

        assertEquals(listOf(24f, 48f, 100f), spec.routeOptions.detentsVh)
        assertEquals(1, spec.routeOptions.initialDetentIndex)
    }

    @Test
    fun heroSheetProjectsVelocityAndDismissesOnlyPastTheLowestDetent() {
        assertEquals(
            60f,
            LynxHeroSheetMotion.projectedHeightVh(
                currentHeightVh = 56f,
                velocityPxPerSecond = -500f,
                rootHeightPx = 1_000f,
            ),
            0.0001f,
        )
        assertTrue(
            LynxHeroSheetMotion.shouldDismiss(
                rawHeightPx = 200f,
                minimumHeightPx = 300f,
                velocityPxPerSecond = 0f,
            ),
        )
        assertFalse(
            LynxHeroSheetMotion.shouldDismiss(
                rawHeightPx = 300f,
                minimumHeightPx = 300f,
                velocityPxPerSecond = 0f,
            ),
        )
        assertTrue(
            LynxHeroSheetMotion.shouldExpandToFullscreen(
                rawHeightPx = 700f,
                startHeightPx = 560f,
                rootHeightPx = 1_000f,
                velocityPxPerSecond = -100f,
            ),
        )
    }
}
