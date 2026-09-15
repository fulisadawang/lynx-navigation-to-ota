import { createContext, useCallback, useContext, useEffect, useState } from '@lynx-js/react'
import { setI18nLocale, translate } from './i18n.js'

export type SupportedLocale = 'zh-CN' | 'en-US'
export type LocaleSelection = SupportedLocale | 'system' | null

export interface LocaleState {
  schemaVersion: number
  revision: number
  systemLocale: string
  appLocale?: SupportedLocale | null
  appLocaleOverride?: SupportedLocale | null
  locale: SupportedLocale
  effectiveLocale?: SupportedLocale
  language: 'zh' | 'en'
  source: 'system' | 'app' | 'fallback' | string
  status: string
  direction: 'ltr' | string
}

export const LOCALE_CHANGED_EVENT = 'lynxShellLocaleChanged'

const DEFAULT_LOCALE_STATE: LocaleState = {
  schemaVersion: 1,
  revision: 0,
  systemLocale: 'unknown',
  locale: 'zh-CN',
  language: 'zh',
  source: 'fallback',
  status: 'ready',
  direction: 'ltr',
}

function normalizeLocale(value: unknown): SupportedLocale | undefined {
  const normalized = String(value ?? '').trim().replace(/_/g, '-').toLowerCase()
  if (normalized === 'zh' || normalized.startsWith('zh-')) return 'zh-CN'
  if (normalized === 'en' || normalized.startsWith('en-')) return 'en-US'
  return undefined
}

function unwrapPayload(payload: unknown): Record<string, unknown> | undefined {
  let value = payload
  while (Array.isArray(value) && value.length > 0) value = value[0]
  if (!value || typeof value !== 'object' || Array.isArray(value)) return undefined
  return value as Record<string, unknown>
}

/** 兼容三端初始 GlobalProps、Bridge 回调和 GlobalEvent 三种载荷形状。 */
export function parseLocaleState(payload: unknown): LocaleState | undefined {
  if (typeof payload === 'string') {
    const locale = normalizeLocale(payload)
    if (!locale) return undefined
    return {
      ...DEFAULT_LOCALE_STATE,
      locale,
      effectiveLocale: locale,
      language: locale === 'en-US' ? 'en' : 'zh',
      source: 'route',
    }
  }
  const value = unwrapPayload(payload)
  if (!value) return undefined
  let source = value
  for (let depth = 0; depth < 3; depth += 1) {
    const nested = unwrapPayload(source.state) || unwrapPayload(source.data)
    if (!nested) break
    source = nested
  }
  const locale = normalizeLocale(source.locale ?? source.effectiveLocale ?? source.appLocale)
  if (!locale) return undefined
  const language = locale === 'en-US' ? 'en' : 'zh'
  const appLocale = normalizeLocale(source.appLocale)
  const appLocaleOverride = normalizeLocale(source.appLocaleOverride)
  return {
    schemaVersion: Number(source.schemaVersion) || 1,
    revision: Number(source.revision) || 0,
    systemLocale: String(source.systemLocale ?? 'unknown'),
    appLocale: source.appLocale === null ? null : appLocale,
    appLocaleOverride: source.appLocaleOverride === null ? null : appLocaleOverride,
    locale,
    effectiveLocale: locale,
    language,
    source: String(source.source ?? (source.appLocaleOverride || value.source ? 'app' : 'system')),
    status: String(source.status ?? 'ready'),
    direction: String(source.direction ?? 'ltr'),
  }
}

function readInitialLocaleState(): LocaleState {
  const globalProps = (lynx.__globalProps || {}) as unknown as Record<string, unknown>
  return parseLocaleState(
    globalProps.__lynxShellLocale || {
      locale: globalProps.locale ?? globalProps.language,
      appLocale: globalProps.appLocale,
      appLocaleOverride: globalProps.appLocaleOverride,
      language: globalProps.language,
      systemLocale: globalProps.systemLocale,
      source: globalProps.localeSource,
      status: globalProps.localeStatus,
      revision: globalProps.localeRevision,
      direction: globalProps.direction,
    },
  ) || parseLocaleState((globalProps.queryItems as Record<string, unknown> | undefined)?.locale)
    || DEFAULT_LOCALE_STATE
}

interface LocaleContextValue {
  state: LocaleState
  locale: SupportedLocale
  setLocale: (locale: LocaleSelection) => void
  t: (key: string, fallback: string, values?: Record<string, string | number>) => string
}

const LocaleContext = createContext<LocaleContextValue>({
  state: DEFAULT_LOCALE_STATE,
  locale: DEFAULT_LOCALE_STATE.locale,
  setLocale: () => {},
  t: (_key, fallback) => fallback,
})

/**
 * 每个 Lynx Bundle 保持自己的页面资源实例，但语言状态由宿主统一广播。
 * 具体资源由业务 Bundle 注册；这里不内置业务文案，也不伪造资源加载成功。
 */
export function LocaleProvider(props: { children: any }) {
  const [state, setState] = useState<LocaleState>(readInitialLocaleState)

  useEffect(() => {
    const emitter = lynx.getJSModule('GlobalEventEmitter')
    const listener = (payload: unknown) => {
      const next = parseLocaleState(payload)
      if (next) {
        setState((current) => next.revision >= current.revision ? next : current)
      }
    }
    emitter.addListener(LOCALE_CHANGED_EVENT, listener)

    const shell = typeof NativeModules !== 'undefined' ? NativeModules.LynxShellModule : undefined
    shell?.getLocale?.((result: { code: number; data?: unknown }) => {
      const next = parseLocaleState(result?.data)
      if (next) setState((current) => next.revision >= current.revision ? next : current)
    })

    return () => emitter.removeListener(LOCALE_CHANGED_EVENT, listener)
  }, [])

  const setLocale = useCallback((nextLocale: LocaleSelection) => {
    const shell = typeof NativeModules !== 'undefined' ? NativeModules.LynxShellModule : undefined
    if (!shell?.setLocale) return
    shell.setLocale(nextLocale, (result: { code: number; data?: unknown }) => {
      const next = parseLocaleState(result?.data)
      if (next && result?.code === 0) {
        setState((current) => next.revision >= current.revision ? next : current)
      }
    })
  }, [])

  const t = useCallback(
    (key: string, fallback: string, values?: Record<string, string | number>) =>
      translate(state.locale, key, fallback, values),
    [state.locale],
  )

  useEffect(() => {
    setI18nLocale(state.locale)
  }, [state.locale])

  return (
    <LocaleContext.Provider value={{ state, locale: state.locale, setLocale, t }}>
      {props.children}
    </LocaleContext.Provider>
  )
}

export function useLocale() {
  return useContext(LocaleContext)
}

export function localeLabel(locale: SupportedLocale): string {
  return locale === 'en-US' ? 'English (US)' : '简体中文'
}
