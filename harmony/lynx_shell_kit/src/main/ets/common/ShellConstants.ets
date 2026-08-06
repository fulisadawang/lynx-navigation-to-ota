/**
 * 壳工程统一常量。
 *
 * 业务接入时优先修改这里的默认 Bundle 和 App 信息，
 * 不要把同一配置散落在 Ability、页面和 Provider 中。
 */
export default class ShellConstants {
  static readonly TAG: string = 'LynxHarmonyShell';

  static readonly HOME_PAGE: string = 'pages/Index';
  static readonly LYNX_PAGE: string = 'pages/LynxContainer';

  static readonly DEFAULT_LOCAL_BUNDLE: string = 'bundles/main.lynx.bundle';
  static readonly DEFAULT_ROUTE: string = 'assets://bundles/main.lynx.bundle';

  static readonly APP_NAME: string = 'LynxHarmonyShell';
  static readonly APP_VERSION: string = '1.0.0';
  static readonly BUILD_NUMBER: string = '1';

  static readonly STORAGE_NAME: string = 'lynx_shell_storage';
  static readonly MAX_BUNDLE_BYTES: number = 20 * 1024 * 1024;

  static readonly STORAGE_INITIAL_URI: string = 'lynx_initial_uri';
  static readonly STORAGE_INITIAL_URI_VERSION: string = 'lynx_initial_uri_version';
  static readonly STORAGE_WINDOW_STAGE: string = 'lynx_window_stage';
  static readonly STORAGE_COLOR_MODE: string = 'lynx_color_mode';

  private constructor() {
  }
}
