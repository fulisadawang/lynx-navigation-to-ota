import type { SupportedLocale } from './locale.js'

export type LocaleMessages = Record<string, string>
export type LocaleResources = Partial<Record<SupportedLocale, LocaleMessages>>

/** 与 i18next 实例兼容的最小接口；Bundle 可直接注册自己的 i18next@23 实例。 */
export interface I18nInstanceLike {
  changeLanguage?: (locale: string) => Promise<unknown> | unknown
  t?: (key: string, options?: Record<string, unknown>) => string
}

let resources: LocaleResources = {
  // 只放壳层 Tab/Settings 的最小文案；业务 Bundle 可以继续覆盖或扩展。
  'zh-CN': {
    'nav.home': '首页',
    'nav.settings': '设置',
    'settings.title': '设置',
    'settings.appearance': '外观',
    'settings.themeSystem': '跟随系统',
    'settings.themeLight': '浅色',
    'settings.themeDark': '深色',
    'settings.language': '语言',
    'settings.systemDefault': '跟随系统',
    'settings.currentLocale': '当前生效：{{locale}} · 切换会同步已打开的 Tab 和后续页面',
    'settings.systemInfo': '系统信息',
    'settings.sdkVersion': 'Lynx SDK 版本',
    'settings.platform': '平台',
    'settings.osVersion': '系统版本',
    'settings.pixelRatio': '像素密度',
    'settings.screenWidth': '屏幕宽度',
    'settings.screenHeight': '屏幕高度',
    'settings.footer': '跨平台 Lynx 调试壳',
    'home.loadedBundle': '当前实际加载的 Bundle',
    'home.openPage': '打开页面',
    'home.open': '打开',
    'home.fullscreen': '全屏',
    'home.dark': '深色',
    'home.light': '浅色',
    'home.i18nDemoTitle': '国际化测试',
    'home.i18nDemoDescription': '验证 App 语言、资源切换和新页面 locale 参数',
  },
  'en-US': {
    'nav.home': 'Home',
    'nav.settings': 'Settings',
    'settings.title': 'Settings',
    'settings.appearance': 'Appearance',
    'settings.themeSystem': 'System default',
    'settings.themeLight': 'Light',
    'settings.themeDark': 'Dark',
    'settings.language': 'Language',
    'settings.systemDefault': 'System default',
    'settings.currentLocale': 'Active locale: {{locale}} · Existing and future Tabs follow this setting',
    'settings.systemInfo': 'System info',
    'settings.sdkVersion': 'Lynx SDK version',
    'settings.platform': 'Platform',
    'settings.osVersion': 'System version',
    'settings.pixelRatio': 'Pixel ratio',
    'settings.screenWidth': 'Screen width',
    'settings.screenHeight': 'Screen height',
    'settings.footer': 'Cross-platform Lynx debug shell',
    'home.loadedBundle': 'Loaded Bundle',
    'home.openPage': 'Open page',
    'home.open': 'Open',
    'home.fullscreen': 'Fullscreen',
    'home.dark': 'Dark',
    'home.light': 'Light',
    'home.i18nDemoTitle': 'i18n Bundle test',
    'home.i18nDemoDescription': 'Verify App language, resource switching and the new page locale marker',
  },
}
let i18nInstance: I18nInstanceLike | undefined

/** 供业务 Bundle 在启动时注入自己的静态资源，避免壳层猜测业务文案。 */
export function configureLocaleResources(next: LocaleResources): void {
  resources = {
    'zh-CN': { ...resources['zh-CN'], ...(next['zh-CN'] || {}) },
    'en-US': { ...resources['en-US'], ...(next['en-US'] || {}) },
  }
}

/** 注册 Bundle 自己创建的 i18next 实例，并立即同步当前宿主语言。 */
export function registerI18nInstance(instance: I18nInstanceLike | undefined): void {
  i18nInstance = instance
}

export function setI18nLocale(locale: SupportedLocale): void {
  void i18nInstance?.changeLanguage?.(locale)
}

/**
 * 与 i18next 的 key/fallback 语义对齐的轻量边界。
 * Bundle 如果使用 i18next，可把翻译函数包在这里，页面只依赖相同的 key 契约。
 */
export function translate(
  locale: SupportedLocale,
  key: string,
  fallback: string,
  values: Record<string, string | number> = {},
): string {
  const translated = i18nInstance?.t?.(key, { defaultValue: fallback, ...values })
  if (translated) return translated
  const raw = resources[locale]?.[key] || fallback
  return raw.replace(/\{\{\s*([\w.-]+)\s*\}\}/g, (_, name: string) => {
    const value = values[name]
    return value === undefined ? `{{${name}}}` : String(value)
  })
}
