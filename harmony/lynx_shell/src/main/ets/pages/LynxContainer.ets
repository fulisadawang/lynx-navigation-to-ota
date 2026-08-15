import router from '@ohos.router';
import { LynxContainer as LynxShellKitContainer, LynxPageRequest } from '@lynx/lynx-shell-kit';

/**
 * Demo 页面入口。
 *
 * 具体 Lynx Runtime、Provider、Bridge 和无原生导航容器均来自可复用 HAR Module；
 * Entry 模块只保留页面入口标记，不再复制一套宿主实现。
 */
@Entry
@Component
struct LynxContainer {
  private request: LynxPageRequest = LynxPageRequest.fromRouterParams(router.getParams());

  /** Entry 才是 main_pages.json 注册的真实页面，动画开关必须在这里声明。 */
  pageTransition() {
    if (!this.request.animated) {
      PageTransitionEnter({ type: RouteType.None, duration: 0 });
      PageTransitionExit({ type: RouteType.None, duration: 0 });
    }
  }

  build() {
    Column() {
      LynxShellKitContainer();
    }
    .width('100%')
    .height('100%');
  }
}
