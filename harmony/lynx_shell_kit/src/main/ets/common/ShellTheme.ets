import { ColorScheme } from '@lynx/lynx';

/**
 * 壳层只接受已经解析完成的两态主题。
 *
 * Harmony Configuration 的数值定义与 Lynx ColorScheme 相反，所有映射集中在这里，
 * 避免宿主把 COLOR_MODE_DARK/LIGHT 的原始数字直接传给 Lynx。
 */
export type ShellTheme = 'Light' | 'Dark';

export default class ShellThemeState {
  private static value: ShellTheme = 'Light';

  static current(): ShellTheme {
    return ShellThemeState.value;
  }

  static set(theme: ShellTheme): boolean {
    if (ShellThemeState.value === theme) {
      return false;
    }
    ShellThemeState.value = theme;
    return true;
  }

  static colorScheme(theme: ShellTheme = ShellThemeState.value): ColorScheme {
    return theme === 'Dark' ? ColorScheme.DARK : ColorScheme.LIGHT;
  }

  private constructor() {
  }
}
