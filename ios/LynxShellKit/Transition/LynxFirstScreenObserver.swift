import Foundation
import Lynx

/**
 * 把 Lynx 首屏事件绑定到一次明确的 load generation。
 *
 * LynxView 的 lifecycle client 由容器强持有；旧 Bundle 即使迟到回调，也不会把新页面
 * 错误标记为 ready。
 */
final class LynxFirstScreenObserver: NSObject, LynxViewLifecycle {
    private let generation: UUID
    private let onFirstScreen: (UUID, LynxView) -> Void
    private let onFirstScreenError: (UUID, LynxView, Error) -> Void

    init(
        generation: UUID,
        onFirstScreen: @escaping (UUID, LynxView) -> Void,
        onFirstScreenError: @escaping (UUID, LynxView, Error) -> Void = { _, _, _ in }
    ) {
        self.generation = generation
        self.onFirstScreen = onFirstScreen
        self.onFirstScreenError = onFirstScreenError
        super.init()
    }

    func lynxViewDidFirstScreen(_ view: LynxView) {
        onFirstScreen(generation, view)
    }

    /**
     * 首屏前的模板/JS/Layout 错误交给容器触发一次 OTA 回滚。
     * 普通图片、字体等子资源失败不回滚整个 release，避免弱网造成错误降级。
     */
    func lynxView(_ view: LynxView!, didRecieveError error: (any Error)!) {
        guard let view, let error else { return }
        let nsError = error as NSError
        guard nsError.code != LynxErrorCodeForResourceError else { return }
        onFirstScreenError(generation, view, error)
    }
}
