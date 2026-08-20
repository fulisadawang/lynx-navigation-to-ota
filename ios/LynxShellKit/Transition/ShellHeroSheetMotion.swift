import CoreGraphics

/** heroSheet 的纯档位运动工具；系统 Sheet 与 iOS 13/14 fallback 共用同一规则。 */
enum ShellHeroSheetMotion {
    static let maximumDetents = 4
    static let defaultInitialDetentVH: CGFloat = 56
    static let dismissVelocityPointsPerSecond: CGFloat = 900
    static let expandToFullscreenVelocityPointsPerSecond: CGFloat = -700
    static let expandToFullscreenDistanceFraction: CGFloat = 0.08
    static let velocityProjectionSeconds: CGFloat = 0.08
    static let defaultDetentsVH: [CGFloat] = [28, 56, 100]

    static func nearestDetentIndex(
        heightVH: CGFloat,
        detentsVH: [CGFloat]
    ) -> Int {
        guard !detentsVH.isEmpty else { return 0 }
        return detentsVH.indices.min {
            abs(detentsVH[$0] - heightVH) < abs(detentsVH[$1] - heightVH)
        } ?? 0
    }

    static func projectedHeightVH(
        currentHeightVH: CGFloat,
        velocityPointsPerSecond: CGFloat,
        containerHeight: CGFloat
    ) -> CGFloat {
        guard containerHeight > 0 else { return currentHeightVH }
        return currentHeightVH -
            velocityPointsPerSecond * velocityProjectionSeconds / containerHeight * 100
    }

    static func shouldDismiss(
        rawHeight: CGFloat,
        minimumHeight: CGFloat,
        velocityPointsPerSecond: CGFloat
    ) -> Bool {
        rawHeight < minimumHeight * 0.88 ||
            (rawHeight <= minimumHeight + 1 &&
                velocityPointsPerSecond >= dismissVelocityPointsPerSecond)
    }

    static func shouldExpandToFullscreen(
        rawHeight: CGFloat,
        startHeight: CGFloat,
        containerHeight: CGFloat,
        velocityPointsPerSecond: CGFloat
    ) -> Bool {
        velocityPointsPerSecond <= expandToFullscreenVelocityPointsPerSecond ||
            rawHeight >= startHeight + containerHeight * expandToFullscreenDistanceFraction
    }
}
