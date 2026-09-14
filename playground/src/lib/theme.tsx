import { createContext, useContext, useState, useCallback, useEffect } from '@lynx-js/react'
import { LocaleProvider } from './locale.js'

export type ThemePreference = 'Auto' | 'Light' | 'Dark'
export type ResolvedTheme = 'light' | 'dark'

const THEME_CHANGED_EVENT = 'lynxShellThemeChanged'

interface ThemeContextValue {
  preference: ThemePreference
  resolved: ResolvedTheme
  setPreference: (pref: ThemePreference) => void
}

const ThemeContext = createContext<ThemeContextValue>({
  preference: 'Auto',
  resolved: 'dark',
  setPreference: () => {},
})

function readSystemTheme(): ResolvedTheme | undefined {
  const systemTheme = String(lynx.__globalProps?.theme ?? '').toLowerCase()
  if (systemTheme === 'light') return 'light'
  if (systemTheme === 'dark') return 'dark'
  return undefined
}

function resolveTheme(preference: ThemePreference): ResolvedTheme {
  const p = preference.toLowerCase()
  if (p === 'light') return 'light'
  if (p === 'dark') return 'dark'
  // Auto：使用宿主主题；宿主在 LynxView 首次布局后会补发一次完整 GlobalProps。
  return readSystemTheme() ?? 'dark'
}

function getInitialPreference(): ThemePreference {
  const gp = (lynx.__globalProps || {}) as Record<string, any>
  // 只有路由明确传入 force_theme_style 才覆盖宿主主题；SDK 的 preferredTheme 可能是
  // 引擎默认值，不能让两个独立的 Native Tab 实例各自偏离宿主的有效主题。
  const raw = (gp.queryItems as Record<string, any>)?.force_theme_style || 'Auto'
  const lower = String(raw).toLowerCase()
  if (lower === 'light') return 'Light'
  if (lower === 'dark') return 'Dark'
  return 'Auto'
}

function parseThemePreference(payload: unknown): ThemePreference | undefined {
  let value = payload
  if (Array.isArray(value) && value.length === 1) value = value[0]
  if (!value || typeof value !== 'object' || Array.isArray(value)) return undefined
  const raw = String((value as Record<string, unknown>).preference ?? '').toLowerCase()
  if (raw === 'light') return 'Light'
  if (raw === 'dark') return 'Dark'
  if (raw === 'auto') return 'Auto'
  return undefined
}

export function ThemeProvider(props: { children: any }) {
  const [preference, setPreferenceState] = useState<ThemePreference>(getInitialPreference)

  useEffect(() => {
    const emitter = lynx.getJSModule('GlobalEventEmitter')
    const listener = (payload: unknown) => {
      const next = parseThemePreference(payload)
      if (next) setPreferenceState((current) => current === next ? current : next)
    }
    emitter.addListener(THEME_CHANGED_EVENT, listener)
    return () => emitter.removeListener(THEME_CHANGED_EVENT, listener)
  }, [])

  const setPreference = useCallback((pref: ThemePreference) => {
    setPreferenceState(pref)
    const shell = typeof NativeModules !== 'undefined' ? NativeModules.LynxShellModule : undefined
    shell?.broadcast?.(
      THEME_CHANGED_EVENT,
      { preference: pref },
      () => {},
    )
  }, [])

  const resolved = resolveTheme(preference)

  return (
    <LocaleProvider>
      <ThemeContext.Provider value={{ preference, resolved, setPreference }}>
        {props.children}
      </ThemeContext.Provider>
    </LocaleProvider>
  )
}

export function useTheme() {
  return useContext(ThemeContext)
}
