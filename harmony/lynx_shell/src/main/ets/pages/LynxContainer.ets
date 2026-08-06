import { LynxContainer as LynxShellKitContainer } from '@lynx/lynx-shell-kit';

/**
 * Demo 页面入口。
 *
 * 具体 Lynx Runtime、Provider、Bridge 和无原生导航容器均来自可复用 HAR Module；
 * Entry 模块只保留页面入口标记，不再复制一套宿主实现。
 */
@Entry
@Component
struct LynxContainer {
  build() {
    Column() {
      LynxShellKitContainer();
    }
    .width('100%')
    .height('100%');
  }
}
