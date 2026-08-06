/**
 * Entry 模块兼容导出。
 *
 * 实际 Bridge 唯一实现位于 @lynx/lynx-shell-kit HAR；这里不再保留一份会
 * 漂移的旧 Module，避免新增方法只改到 HAR 后 Entry 源码仍显示半套协议。
 */
export { LynxShellModule } from '@lynx/lynx-shell-kit';
