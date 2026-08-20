import CoreGraphics
import Foundation

private func expectNear(
    _ actual: CGFloat,
    _ expected: CGFloat,
    _ message: String,
    tolerance: CGFloat = 0.0001
) {
    guard abs(actual - expected) <= tolerance else {
        fputs("FAIL: \(message), expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

@main
struct ShellBottomSheetMotionTests {
    static func main() {
        expectNear(
            ShellBottomSheetMotion.defaultHeightVH,
            92,
            "default bottom sheet uses iOS page-sheet height"
        )
        let dismissed = ShellBottomSheetMotion.state(progress: 0)
        expectNear(dismissed.sheetTranslationFraction, 1, "dismissed sheet is off screen")
        expectNear(dismissed.backdropScale, 1, "dismissed backdrop is full size")
        expectNear(dismissed.barrierAlpha, 0, "dismissed barrier is transparent")

        let opened = ShellBottomSheetMotion.state(progress: 1)
        expectNear(opened.sheetTranslationFraction, 0, "opened sheet is settled")
        expectNear(opened.backdropScale, 0.94, "opened backdrop is scaled")
        expectNear(opened.backdropTranslationY, 10, "opened backdrop is lowered")
        expectNear(opened.backdropCornerRadius, 18, "opened backdrop keeps continuous radius")
        expectNear(opened.barrierAlpha, 1, "opened barrier is fully visible")

        let state = ShellBottomSheetMotion.state(progress: 0.5)
        expectNear(state.sheetTranslationFraction, 0.5, "half-progress sheet translation")
        expectNear(state.backdropScale, 0.97, "half-progress backdrop scale")
        expectNear(state.backdropTranslationY, 5, "half-progress backdrop translation")
        expectNear(state.backdropCornerRadius, 9, "half-progress backdrop corner radius")
        expectNear(state.barrierAlpha, 0.5, "half-progress barrier alpha")

        expectNear(
            ShellBottomSheetMotion.dragProgress(distance: 300, sheetHeight: 600),
            0.5,
            "vertical drag uses sheet height"
        )
        expectNear(
            ShellBottomSheetMotion.dragProgress(distance: 900, sheetHeight: 600),
            1,
            "vertical drag clamps to one"
        )
        guard ShellBottomSheetMotion.preservesTerminalState(transitionCancelled: false) else {
            fputs("FAIL: completed pop must preserve the off-screen terminal state\n", stderr)
            exit(1)
        }
        guard !ShellBottomSheetMotion.preservesTerminalState(transitionCancelled: true) else {
            fputs("FAIL: cancelled pop must restore the presented Page Sheet state\n", stderr)
            exit(1)
        }

        expectNear(
            ShellHeroSheetMotion.defaultInitialDetentVH,
            56,
            "heroSheet starts at the middle detent"
        )
        let heroDetents = ShellHeroSheetMotion.defaultDetentsVH
        guard heroDetents == [28, 56, 100] else {
            fputs("FAIL: heroSheet default detents are not 28/56/100vh\n", stderr)
            exit(1)
        }
        guard ShellHeroSheetMotion.nearestDetentIndex(
            heightVH: 63,
            detentsVH: heroDetents
        ) == 1 else {
            fputs("FAIL: heroSheet nearest detent selection is incorrect\n", stderr)
            exit(1)
        }
        guard ShellHeroSheetMotion.shouldDismiss(
            rawHeight: 200,
            minimumHeight: 300,
            velocityPointsPerSecond: 0
        ) else {
            fputs("FAIL: heroSheet should dismiss below the lowest detent\n", stderr)
            exit(1)
        }
        guard !ShellHeroSheetMotion.shouldDismiss(
            rawHeight: 300,
            minimumHeight: 300,
            velocityPointsPerSecond: 0
        ) else {
            fputs("FAIL: heroSheet should snap at the lowest detent\n", stderr)
            exit(1)
        }
        guard ShellHeroSheetMotion.shouldExpandToFullscreen(
            rawHeight: 700,
            startHeight: 560,
            containerHeight: 1_000,
            velocityPointsPerSecond: -100
        ) else {
            fputs("FAIL: heroSheet upward drag must reach the fullscreen detent\n", stderr)
            exit(1)
        }

        print("ShellBottomSheetMotionTests PASS")
    }
}
