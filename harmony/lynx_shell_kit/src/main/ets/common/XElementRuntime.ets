import { Behavior, BehaviorRegistryMap } from '@lynx/lynx';
import { XElementMarkdown } from '@lynx/xelement_markdown';
import { UISVG } from '@lynx/xelement_svg';
import { UIWebView } from '@lynx/xelement_webview';

/**
 * HarmonyOS release/4.0 的 XElement 全量接入点。
 *
 * 与 Android/iOS 不同，HarmonyOS 的 XElement 分为两类：
 * 1. @lynx/lynx 原生 Registry 内置：BlurView、Input/TextArea、Overlay、Refresh、
 *    ScrollCoordinator、ViewPager；随 LynxEnv 初始化生效。
 * 2. 独立 OHPM 包：Markdown 需要 initialize，SVG/WebView 需要注入 behaviors。
 */
export default class XElementRuntime {
  static readonly SUPPORTED_XELEMENTS: string[] = [
    'BlurView',
    'Input/TextArea',
    'Overlay',
    'Refresh',
    'ScrollCoordinator',
    'ViewPager',
    'Markdown',
    'SVG',
    'WebView'
  ];

  private static initialized: boolean = false;

  static initialize(): void {
    if (XElementRuntime.initialized) {
      return;
    }
    XElementMarkdown.initialize();
    XElementRuntime.initialized = true;
  }

  static createBehaviors(): BehaviorRegistryMap {
    return new Map([
      ['svg', new Behavior(UISVG, undefined)],
      ['webview', new Behavior(UIWebView, undefined)]
    ]);
  }

  private constructor() {
  }
}
