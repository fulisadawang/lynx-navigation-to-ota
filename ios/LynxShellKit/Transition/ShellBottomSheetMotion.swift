import CoreGraphics

/** iOS-style Sheet 的单一 progress 运动状态；push、pop 与交互取消共享同一模型。 */
struct ShellBottomSheetMotionState {
    let sheetTranslationFraction: CGFloat
    let backdropScale: CGFloat
    let backdropTranslationY: CGFloat
    let backdropCornerRadius: CGFloat
    let barrierAlpha: CGFloat
}

enum ShellBottomSheetMotion {
    static let defaultDurationMilliseconds = 420
    static let defaultHeightVH: CGFloat = 92
    static let sheetCornerRadius: CGFloat = 20
    static let backdropEndScale: CGFloat = 0.94
    static let backdropEndTranslationY: CGFloat = 10
    static let backdropEndCornerRadius: CGFloat = 18

    static func state(progress rawProgress: CGFloat) -> ShellBottomSheetMotionState {
        let progress = min(max(rawProgress, 0), 1)
        return ShellBottomSheetMotionState(
            sheetTranslationFraction: 1 - progress,
            backdropScale: interpolate(from: 1, to: backdropEndScale, progress: progress),
            backdropTranslationY: backdropEndTranslationY * progress,
            backdropCornerRadius: backdropEndCornerRadius * progress,
            barrierAlpha: progress
        )
    }

    static func dragProgress(distance: CGFloat, sheetHeight: CGFloat) -> CGFloat {
        guard sheetHeight > 0 else { return 0 }
        return min(max(distance / sheetHeight, 0), 1)
    }

    /** 完成 pop 后离场 VC 保持末态直到 UIKit 提交；只有取消时才恢复打开态。 */
    static func preservesTerminalState(transitionCancelled: Bool) -> Bool {
        !transitionCancelled
    }

    private static func interpolate(
        from start: CGFloat,
        to end: CGFloat,
        progress: CGFloat
    ) -> CGFloat {
        start + (end - start) * progress
    }
}
