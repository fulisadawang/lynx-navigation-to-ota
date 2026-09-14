import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { i18n } from '@kit.LocalizationKit';
import ShellConstants from './ShellConstants';

export type ShellLocaleTag = 'zh-CN' | 'en-US';
export type ShellLocaleSource = 'system' | 'app' | 'fallback';

export interface ShellLocaleCapabilities {
  systemLocale: string;
  appLocaleOverride: string;
  localeChangeNotification: string;
  rtl: string;
  intlFormatting: string;
}

/**
 * 宿主级语言状态。appLocale 是页面实际使用的有效语言，
 * appLocaleOverride 只表示用户是否保存了 App 覆盖值。
 */
export interface ShellLocaleStateValue {
  schemaVersion: number;
  revision: number;
  timestampMillis: number;
  systemLocale: string;
  appLocale: ShellLocaleTag;
  appLocaleOverride: ShellLocaleTag | null;
  formatLocale: ShellLocaleTag;
  requestedLocale?: string;
  language: string;
  script: string;
  region: string;
  direction: string;
  source: ShellLocaleSource;
  status: string;
  capabilities: ShellLocaleCapabilities;
}

export interface ShellLocaleMutation {
  success: boolean;
  changed: boolean;
  message: string;
  state: ShellLocaleStateValue;
}

/**
 * Harmony 壳的 App Locale Store。
 *
 * 语言选择写入普通 Preferences，不进入 OTA Store、Manifest 或页面路由快照。
 * 该类只维护状态和持久化边界，页面翻译资源由各自 Lynx Bundle 管理。
 */
export default class ShellLocaleState {
  static readonly STORAGE_KEY: string = ShellConstants.STORAGE_LOCALE_OVERRIDE;
  private static state: ShellLocaleStateValue | null = null;
  private static store: preferences.Preferences | null = null;
  private static initialized: boolean = false;
  private static listeners: Array<(state: ShellLocaleStateValue) => void> = [];

  /** 供宿主自己的 ArkUI Chrome（例如 Native Tabs）订阅同一份语言状态。 */
  static subscribe(listener: (state: ShellLocaleStateValue) => void): void {
    if (!ShellLocaleState.listeners.includes(listener)) {
      ShellLocaleState.listeners.push(listener);
    }
  }

  static unsubscribe(listener: (state: ShellLocaleStateValue) => void): void {
    ShellLocaleState.listeners = ShellLocaleState.listeners.filter((item) => item !== listener);
  }

  static notifyChanged(state: ShellLocaleStateValue): void {
    ShellLocaleState.listeners.slice().forEach((listener) => {
      try {
        listener(state);
      } catch (error) {
        console.warn(`[${ShellConstants.TAG}] locale host listener failed: ${error}`);
      }
    });
  }

  static initialize(context: common.UIAbilityContext): void {
    if (ShellLocaleState.initialized) {
      return;
    }
    let override: ShellLocaleTag | null = null;
    try {
      ShellLocaleState.store = preferences.getPreferencesSync(
        context,
        { name: ShellConstants.STORAGE_NAME }
      );
      const stored = ShellLocaleState.store.getSync(ShellLocaleState.STORAGE_KEY, '') as string;
      override = ShellLocaleState.normalizeStoredLocale(stored);
    } catch (error) {
      ShellLocaleState.store = null;
      console.error(`[${ShellConstants.TAG}] locale preferences initialization failed: ${error}`);
    }
    ShellLocaleState.state = ShellLocaleState.makeState(
      ShellLocaleState.readSystemLocale(),
      override,
      0
    );
    ShellLocaleState.initialized = true;
  }

  static current(): ShellLocaleStateValue {
    ShellLocaleState.ensureInitialized();
    return ShellLocaleState.state as ShellLocaleStateValue;
  }

  /** 当前系统语言变化时调用；有 App 覆盖时仍更新 systemLocale 事实字段。 */
  static refreshSystemLocale(): boolean {
    ShellLocaleState.ensureInitialized();
    const current = ShellLocaleState.state as ShellLocaleStateValue;
    const systemLocale = ShellLocaleState.readSystemLocale();
    if (systemLocale === current.systemLocale) {
      return false;
    }
    ShellLocaleState.state = ShellLocaleState.makeState(
      systemLocale,
      current.appLocaleOverride,
      current.revision + 1
    );
    return true;
  }

  /**
   * 设置 App 语言。传入 null 或 system 清除覆盖并恢复系统语言。
   * 持久化失败时不改变内存状态，避免出现下次启动语言回退的假成功。
   */
  static setAppLocale(locale: string | null): ShellLocaleMutation {
    ShellLocaleState.ensureInitialized();
    const current = ShellLocaleState.state as ShellLocaleStateValue;
    const raw = locale === null ? '' : locale.trim();
    const clearOverride = locale === null || raw.toLowerCase() === 'system';
    const nextOverride = clearOverride ? null : ShellLocaleState.normalizeLocale(raw);
    if (!clearOverride && nextOverride === null) {
      return {
        success: false,
        changed: false,
        message: '仅支持 zh-CN、en-US 或 system',
        state: current
      };
    }
    if (nextOverride === current.appLocaleOverride) {
      return {
        success: true,
        changed: false,
        message: '语言设置未变化',
        state: current
      };
    }
    if (!ShellLocaleState.persistOverride(nextOverride)) {
      return {
        success: false,
        changed: false,
        message: '语言设置无法持久化',
        state: current
      };
    }
    ShellLocaleState.state = ShellLocaleState.makeState(
      current.systemLocale,
      nextOverride,
      current.revision + 1
    );
    return {
      success: true,
      changed: true,
      message: clearOverride ? '已恢复跟随系统语言' : `App 语言已切换为 ${nextOverride}`,
      state: ShellLocaleState.state
    };
  }

  private static ensureInitialized(): void {
    if (ShellLocaleState.state !== null) {
      return;
    }
    ShellLocaleState.state = ShellLocaleState.makeState(
      ShellLocaleState.readSystemLocale(),
      null,
      0
    );
  }

  private static persistOverride(locale: ShellLocaleTag | null): boolean {
    if (ShellLocaleState.store === null) {
      // Router.install 会在页面创建前初始化 Preferences；未初始化时不宣称已持久化。
      return false;
    }
    try {
      if (locale === null) {
        ShellLocaleState.store.deleteSync(ShellLocaleState.STORAGE_KEY);
      } else {
        ShellLocaleState.store.putSync(ShellLocaleState.STORAGE_KEY, locale);
      }
      ShellLocaleState.store.flushSync();
      return true;
    } catch (error) {
      console.error(`[${ShellConstants.TAG}] locale preference update failed: ${error}`);
      return false;
    }
  }

  private static makeState(
    systemLocale: string,
    override: ShellLocaleTag | null,
    revision: number
  ): ShellLocaleStateValue {
    const systemSupported = ShellLocaleState.normalizeLocale(systemLocale);
    const effective = override ?? systemSupported ?? 'zh-CN';
    const source: ShellLocaleSource = override !== null ? 'app' :
      systemSupported !== null ? 'system' : 'fallback';
    const state: ShellLocaleStateValue = {
      schemaVersion: 1,
      revision: revision,
      timestampMillis: new Date().getTime(),
      systemLocale: systemLocale,
      appLocale: effective,
      appLocaleOverride: override,
      formatLocale: effective,
      language: effective === 'en-US' ? 'en' : 'zh',
      script: effective === 'zh-CN' ? 'Hans' : 'Latn',
      region: effective === 'zh-CN' ? 'CN' : 'US',
      direction: 'ltr',
      source: source,
      status: 'ready',
      capabilities: {
        systemLocale: 'supported',
        appLocaleOverride: 'supported',
        localeChangeNotification: 'supported',
        rtl: 'unsupported',
        intlFormatting: 'unavailable'
      }
    };
    if (source === 'fallback' && systemLocale.length > 0 && systemLocale !== 'unknown') {
      state.requestedLocale = systemLocale;
    }
    return state;
  }

  private static readSystemLocale(): string {
    try {
      const locale = String(i18n.System.getSystemLocale()).trim().replace(/_/g, '-');
      if (locale.length > 0) {
        return locale;
      }
    } catch (error) {
      console.warn(`[${ShellConstants.TAG}] read system locale failed: ${error}`);
    }
    try {
      const language = String(i18n.System.getSystemLanguage()).trim().replace(/_/g, '-');
      if (language.length > 0) {
        return language;
      }
    } catch (error) {
      console.warn(`[${ShellConstants.TAG}] read system language failed: ${error}`);
    }
    return 'unknown';
  }

  private static normalizeStoredLocale(value: string): ShellLocaleTag | null {
    return ShellLocaleState.normalizeLocale(value.trim());
  }

  private static normalizeLocale(value: string): ShellLocaleTag | null {
    const normalized = value.trim().replace(/_/g, '-').toLowerCase();
    if (normalized === 'zh' || normalized.startsWith('zh-')) {
      return 'zh-CN';
    }
    if (normalized === 'en' || normalized.startsWith('en-')) {
      return 'en-US';
    }
    return null;
  }

  private constructor() {
  }
}
