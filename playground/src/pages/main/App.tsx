import { useState, useEffect } from '@lynx-js/react'
import { open, navigate } from '../../lib/navigation.js'
import { ThemeProvider, useTheme } from '../../lib/theme.js'
import { Navigator, type TabPage } from '../../components/Navigator/index.js'
import { getItem, setItem } from '../../lib/storage.js'

import { parseSchemeInput, buildSchemeInput } from '../../lib/schemeUrl.js'
import { getRecentUrls, addRecentUrl, clearRecentUrls } from '../../lib/recentHistory.js'
import './App.css'

interface DemoItem {
  title: string
  description: string
  bundle: string
  icon: string
}

interface Category {
  name: string
  icon: string
  color: string
  items: DemoItem[]
}

interface BundleRuntimeMeta {
  lynxAppId?: string
  releaseId?: string
  source?: string
  bundleName?: string
  sha256?: string
}

function readBundleRuntimeMeta(): BundleRuntimeMeta {
  const globalProps = ((lynx.__globalProps || {}) as unknown) as Record<string, unknown>
  const raw = globalProps.__lynxBundleMeta
  if (raw && typeof raw === 'object') {
    const value = raw as Record<string, unknown>
    return {
      lynxAppId: typeof value.lynxAppId === 'string' ? value.lynxAppId : undefined,
      releaseId: typeof value.releaseId === 'string' ? value.releaseId : undefined,
      source: typeof value.source === 'string' ? value.source : undefined,
      bundleName: typeof value.bundleName === 'string' ? value.bundleName : undefined,
      sha256: typeof value.sha256 === 'string' ? value.sha256 : undefined,
    }
  }

  const queryItems = globalProps.queryItems
  const query = queryItems && typeof queryItems === 'object'
    ? queryItems as Record<string, unknown>
    : {}
  return {
    lynxAppId: typeof query.lynxAppId === 'string' ? query.lynxAppId : undefined,
    bundleName: typeof query.bundleName === 'string' ? query.bundleName : undefined,
    source: 'direct_asset',
  }
}

function bundleSourceLabel(source: string | undefined): string {
  switch (source) {
    case 'embedded_baseline': return '内置 baseline'
    case 'ota_current': return 'OTA current'
    case 'rollback_fallback': return '回滚 fallback'
    case 'tab_cache': return 'Tab cache-only'
    case 'direct_asset': return 'Direct Asset'
    default: return source || '未提供来源'
  }
}

const CATEGORIES: Category[] = [
  {
    name: '路由与导航',
    icon: '\u{1F9ED}',
    color: '#25f4ee',
    items: [
      { title: '示例总览', description: '按分类搜索并打开全部 Playground 示例', bundle: 'showcase.lynx.bundle', icon: '\u{1F4DA}' },
      { title: '官方 Bundle 示例', description: '搜索并打开 go.lynxjs.org 的 565 个示例', bundle: 'go-bundles.lynx.bundle', icon: '\u{1F9EA}' },
      { title: '导航栈', description: '测试 popTo、清栈、主页与重定向', bundle: 'nav-chain.lynx.bundle', icon: '\u{26D3}' },
      { title: '原生容器转场', description: '共享元素、Open Container、预置路由与跟手返回', bundle: 'transition-gallery.lynx.bundle', icon: '\u{1F3AC}' },
      { title: '原生转场目标页', description: '直接打开转场目标页，查看 ready 与原生状态', bundle: 'transition-detail.lynx.bundle', icon: '\u{1F3AF}' },
      { title: '参数传递', description: '通过 queryItems 传递自定义参数', bundle: 'nav-basic.lynx.bundle', icon: '\u{27A1}' },
      { title: '路由预设', description: '常用 Scheme 配置示例', bundle: 'scheme-presets.lynx.bundle', icon: '\u{1F3A8}' },
      { title: '路由构建器', description: '构建并测试任意 Scheme 配置', bundle: 'scheme-builder.lynx.bundle', icon: '\u{1F527}' },
    ],
  },
  {
    name: '全局参数',
    icon: '\u{1F4F1}',
    color: '#009995',
    items: [
      { title: '设备与系统信息', description: '系统、设备、语言、SDK 与无障碍信息', bundle: 'gp-device.lynx.bundle', icon: '\u{1F4BB}' },
      { title: '屏幕与安全区', description: '屏幕尺寸、安全区和状态栏参数', bundle: 'gp-screen.lynx.bundle', icon: '\u{1F4D0}' },
      { title: '导航目标容器', description: '查看容器 ID、Scheme 参数与自定义参数', bundle: 'gp-container.lynx.bundle', icon: '\u{1F4E6}' },
    ],
  },
  {
    name: '本地存储',
    icon: '\u{1F4BE}',
    color: '#ff9500',
    items: [
      { title: 'setItem / getItem', description: '持久化键值存储与读取', bundle: 'storage-demo.lynx.bundle', icon: '\u{1F5C4}' },
    ],
  },
  {
    name: '媒体能力',
    icon: '\u{1F3AC}',
    color: '#af52de',
    items: [
      { title: '选择媒体', description: '从相册或相机选择图片和视频', bundle: 'media-choose.lynx.bundle', icon: '\u{1F4F7}' },
      { title: '上传文件', description: '向服务器上传文件和图片', bundle: 'media-upload.lynx.bundle', icon: '\u{2B06}' },
      { title: '下载与保存', description: '下载文件并保存 Data URL', bundle: 'media-download.lynx.bundle', icon: '\u{2B07}' },
    ],
  },
]

function HomePage(props: { showPage: boolean; topInset: number }) {
  const { resolved } = useTheme()
  const [source, setSource] = useState('')
  const [params, setParams] = useState<Record<string, string>>({})
  const [openResult, setOpenResult] = useState('')
  const [recentUrls, setRecentUrls] = useState<string[]>([])
  const isDark = resolved === 'dark'
  const bundleMeta = readBundleRuntimeMeta()

  useEffect(() => {
    if (props.showPage) {
      getRecentUrls((urls) => setRecentUrls(urls))
    }
  }, [props.showPage])

  if (!props.showPage) return <></>

  const dk = (base: string) => `${base} ${isDark ? `${base}--dark` : `${base}--light`}`

  const displayInput = buildSchemeInput(source, params)
  const isFullscreen = params.hide_nav_bar === '1' && params.trans_status_bar === '1'
  const activeTheme = params.force_theme_style || ''

  const handleInput = (event: { detail: { value: string } }) => {
    'background only'
    const parsed = parseSchemeInput(event.detail.value.trim())
    setSource(parsed.source)
    setParams(parsed.params)
  }

  const handleFullscreenToggle = () => {
    'background only'
    const next = { ...params }
    if (isFullscreen) {
      delete next.hide_nav_bar
      delete next.trans_status_bar
    } else {
      next.hide_nav_bar = '1'
      next.trans_status_bar = '1'
    }
    setParams(next)
  }

  const handleThemeChip = (theme: string) => {
    'background only'
    const next = { ...params }
    if (activeTheme === theme) {
      // Toggle off
      delete next.force_theme_style
      delete next.nav_bar_color
      delete next.title_color
      delete next.container_bg_color
    } else if (theme === 'dark') {
      next.force_theme_style = 'dark'
      next.nav_bar_color = '#000000'
      next.title_color = '#ffffff'
      next.container_bg_color = '#000000'
    } else {
      next.force_theme_style = 'light'
      next.nav_bar_color = '#ffffff'
      next.title_color = '#000000'
      next.container_bg_color = '#f0f2f5'
    }
    setParams(next)
  }

  const handleGo = () => {
    'background only'
    const target = source || 'gp-screen.lynx.bundle'

    const lower = target.toLowerCase()
    const isScheme = lower.startsWith('hybrid://')
    const isHttp = lower.startsWith('http://') || lower.startsWith('https://')
    const isBundle = lower.endsWith('.lynx.bundle')

    if (!isScheme && !isHttp && !isBundle) {
      setOpenResult('请输入 *.lynx.bundle、hybrid://... 或 http(s)://...')
      return
    }

    setOpenResult('正在打开…')
    const displayUrl = buildSchemeInput(target, params)
    addRecentUrl(displayUrl, (urls) => setRecentUrls(urls))

    if (isScheme) {
      open({ scheme: target }, (res) => {
        setOpenResult(`${res.code === 1 ? '已打开' : '打开失败'}${res.msg && res.msg !== 'ok' ? ' — ' + res.msg : ''}`)
      })
    } else if (isHttp) {
      const qs = Object.entries(params).filter(([, v]) => v && v !== '0').map(([k, v]) => `${k}=${encodeURIComponent(v)}`).join('&')
      const scheme = `hybrid://lynxview_page?url=${encodeURIComponent(target)}${qs ? '&' + qs : ''}`
      open({ scheme }, (res) => {
        setOpenResult(`${res.code === 1 ? '已打开' : '打开失败'}${res.msg && res.msg !== 'ok' ? ' — ' + res.msg : ''}`)
      })
    } else {
      navigate({ path: target, options: { params } }, (res) => {
        setOpenResult(`${res.code === 1 ? '已打开' : '打开失败'}${res.msg && res.msg !== 'ok' ? ' — ' + res.msg : ''}`)
      })
    }
  }

  const handleOpenRecent = (url: string) => {
    'background only'
    const parsed = parseSchemeInput(url)
    setSource(parsed.source)
    setParams(parsed.params)
    // Trigger navigation immediately
    addRecentUrl(url, (urls) => setRecentUrls(urls))
    const lower = parsed.source.toLowerCase()
    if (lower.startsWith('hybrid://')) {
      open({ scheme: parsed.source }, () => {})
    } else if (lower.startsWith('http://') || lower.startsWith('https://')) {
      const qs = Object.entries(parsed.params).filter(([, v]) => v && v !== '0').map(([k, v]) => `${k}=${encodeURIComponent(v)}`).join('&')
      open({ scheme: `hybrid://lynxview_page?url=${encodeURIComponent(parsed.source)}${qs ? '&' + qs : ''}` }, () => {})
    } else {
      navigate({ path: parsed.source, options: { params: parsed.params } }, () => {})
    }
  }

  const handleClearRecent = () => {
    'background only'
    clearRecentUrls(() => setRecentUrls([]))
  }

  const handleItemTap = (bundle: string, title: string) => {
    'background only'
    // Pass the current resolved theme so sub-pages inherit the user's choice
    const dark = resolved === 'dark'
    const isNavigationStackDemo = bundle === 'nav-chain.lynx.bundle'
    navigate({
      path: bundle,
      options: {
        routeKey: isNavigationStackDemo ? 'nav-chain-A' : bundle,
        params: {
          title,
          container_bg_color: dark ? '#000000' : '#f0f2f5',
          nav_bar_color: dark ? '#000000' : '#ffffff',
          title_color: dark ? '#FFFFFF' : '#000000',
          loading_bg_color: dark ? '#000000' : '#f0f2f5',
          force_theme_style: resolved,
          ...(isNavigationStackDemo ? { page_id: 'A', depth: '1' } : {}),
        },
      },
    }, () => {})
  }

  return (
    <scroll-view className="tab-content" scroll-orientation="vertical">
      <view className={`page ${isDark ? 'page--dark' : 'page--light'}`} style={{ paddingTop: `${props.topInset + 16}px` }}>
        {/* Header */}
        <view className="home-header">
          <image
            className="logo-image"
            src={require('../../assets/sparkling_icon.png')}
          />
          <view className="home-title-row">
            <text className={dk('home-title')}>Sparkling </text>
            <text className={dk('home-title')} style={{ color: '#F1204A' }}>Go</text>
          </view>
        </view>

        {/* Bundle Runtime Metadata */}
        <view className={dk('bundle-meta-card')}>
          <view className="bundle-meta-header">
            <view className="bundle-meta-status-dot" />
            <text className={dk('bundle-meta-title')}>当前实际加载的 Bundle</text>
          </view>
          <view className="bundle-meta-grid">
            <view className="bundle-meta-item">
              <text className={dk('bundle-meta-label')}>App ID</text>
              <text className={dk('bundle-meta-value')}>{bundleMeta.lynxAppId || '—'}</text>
            </view>
            <view className="bundle-meta-item">
              <text className={dk('bundle-meta-label')}>Release</text>
              <text className={dk('bundle-meta-value')}>{bundleMeta.releaseId || '未提供'}</text>
            </view>
            <view className="bundle-meta-item bundle-meta-item--wide">
              <text className={dk('bundle-meta-label')}>来源</text>
              <text className={dk('bundle-meta-value')}>{bundleSourceLabel(bundleMeta.source)}</text>
            </view>
            <view className="bundle-meta-item bundle-meta-item--wide">
              <text className={dk('bundle-meta-label')}>Bundle</text>
              <text className={dk('bundle-meta-value')}>{bundleMeta.bundleName || 'main.lynx.bundle'}</text>
            </view>
          </view>
          {bundleMeta.sha256 ? (
            <text className={dk('bundle-meta-hash')}>{bundleMeta.sha256}</text>
          ) : (
            <text className={dk('bundle-meta-hint')}>OTA 页面会显示服务端 releaseId；切换版本后重开页面即可核对</text>
          )}
        </view>

        {/* Open Page Card */}
        <view className={dk('card')}>
          <view className="card-header-row">
            <text className="card-header-icon">{'\u{1F310}'}</text>
            <text className={dk('card-label')}>
              打开页面
            </text>
          </view>
          <view className="input-row">
            <input
              className={`url-input ${isDark ? 'url-input--dark' : 'url-input--light'}`}
              value={displayInput}
              bindinput={handleInput}
              bindconfirm={handleGo}
              confirm-type="go"
              placeholder="gp-screen.lynx.bundle"
              style={{ color: isDark ? '#ffffff' : '#000000' }}
            />
            <view
              className="go-button"
              bindtap={handleGo}
              accessibility-element
              accessibility-label="打开页面"
              accessibility-traits="button"
            >
              <text className="go-button-text">打开</text>
            </view>
          </view>
          <view className="toggle-row">
            <view className={`toggle-chip ${isFullscreen ? 'toggle-chip--active' : (isDark ? 'toggle-chip--dark' : 'toggle-chip--light')}`} bindtap={handleFullscreenToggle}>
              <text className={`toggle-chip-text ${isFullscreen ? 'toggle-chip-text--active' : (isDark ? 'toggle-chip-text--dark' : 'toggle-chip-text--light')}`}>全屏</text>
            </view>
            <view className={`toggle-chip ${activeTheme === 'dark' ? 'toggle-chip--active' : (isDark ? 'toggle-chip--dark' : 'toggle-chip--light')}`} bindtap={() => handleThemeChip('dark')}>
              <text className={`toggle-chip-text ${activeTheme === 'dark' ? 'toggle-chip-text--active' : (isDark ? 'toggle-chip-text--dark' : 'toggle-chip-text--light')}`}>深色</text>
            </view>
            <view className={`toggle-chip ${activeTheme === 'light' ? 'toggle-chip--active' : (isDark ? 'toggle-chip--dark' : 'toggle-chip--light')}`} bindtap={() => handleThemeChip('light')}>
              <text className={`toggle-chip-text ${activeTheme === 'light' ? 'toggle-chip-text--active' : (isDark ? 'toggle-chip-text--dark' : 'toggle-chip-text--light')}`}>浅色</text>
            </view>
          </view>
          {openResult && openResult !== '已打开' ? (
            <text className={`result-text ${isDark ? 'result-text--dark' : 'result-text--light'}`}>
              {openResult}
            </text>
          ) : null}
          {recentUrls.length > 0 ? (
            <view className={dk('recent-section')}>
              <view className="recent-header">
                <text className={dk('recent-title')}>最近打开</text>
                <view bindtap={handleClearRecent}>
                  <text className="recent-clear">清空</text>
                </view>
              </view>
              <scroll-view scroll-orientation="vertical" style={{ maxHeight: '140px' }}>
                {recentUrls.map((url) => (
                  <view key={url} className="recent-item" bindtap={() => handleOpenRecent(url)}>
                    <text className={dk('recent-url')}>{url}</text>
                    <text className={dk('recent-arrow')}>{'\u203A'}</text>
                  </view>
                ))}
              </scroll-view>
            </view>
          ) : null}
        </view>

        {/* Demo Categories (merged from Showcase) */}
        {CATEGORIES.map((category) => (
          <view key={category.name} className="category-section">
            <view className="category-header">
              <view className="category-icon-circle" style={{ backgroundColor: `${category.color}18` }}>
                <text className="category-icon">{category.icon}</text>
              </view>
              <text className={dk('category-name')} style={{ color: category.color }}>
                {category.name}
              </text>
              <view className="category-count-badge" style={{ backgroundColor: `${category.color}20` }}>
                <text className="category-count-text" style={{ color: category.color }}>
                  {category.items.length}
                </text>
              </view>
            </view>
            <view className={dk('category-card')}>
              {category.items.map((item, index) => (
                <view key={item.title}>
                  <view
                    className="menu-item"
                    bindtap={() => handleItemTap(item.bundle, item.title)}
                    accessibility-element
                    accessibility-label={item.title}
                    accessibility-traits="button"
                  >
                    <view className="menu-item-icon" style={{ backgroundColor: `${category.color}15` }}>
                      <text className="menu-item-icon-text">{item.icon}</text>
                    </view>
                    <view className="menu-item-content">
                      <text className={dk('menu-item-title')}>{item.title}</text>
                      <text className={dk('menu-item-desc')}>{item.description}</text>
                    </view>
                    <text className={dk('menu-item-arrow')}>{'\u203A'}</text>
                  </view>
                  {index < category.items.length - 1 ? (
                    <view className={dk('menu-item-divider')} />
                  ) : null}
                </view>
              ))}
            </view>
          </view>
        ))}

        {/* Version Footer */}
        <view className="home-footer">
          <text className={dk('home-footer-text')}>
            Sparkling Playground · Lynx 4.0 · {bundleSourceLabel(bundleMeta.source)}
          </text>
        </view>
      </view>
    </scroll-view>
  )
}

declare const __DEV__: boolean

function getOrigin(url: string): string {
  const m = url.match(/^(https?:\/\/[^/]+)/)
  return m ? m[1] : ''
}

function SettingsPage(props: { showPage: boolean; topInset: number }) {
  const { preference, resolved, setPreference } = useTheme()
  const isDark = resolved === 'dark'
  const isDev = typeof __DEV__ !== 'undefined' && __DEV__

  // --- Dev server state ---
  const [devLoading, setDevLoading] = useState(true)
  const [devUrl, setDevUrl] = useState('')       // persisted URL from native
  const [devUrlInput, setDevUrlInput] = useState('')
  const [devStatus, setDevStatus] = useState<'idle' | 'saved' | 'save-error' | 'pipe-error'>('idle')
  const [devErrorMsg, setDevErrorMsg] = useState('')

  // Runtime bundle URL — injected by the native SDK when it loaded this page.
  // Available without any pipe call; tells us where we're ACTUALLY running from.
  const runtimeUrl = ((lynx.__globalProps || {}) as any)?.queryItems?.url as string || ''
  const isConnected = /^https?:\/\//.test(runtimeUrl)
  const runtimeOrigin = getOrigin(runtimeUrl)
  const persistedOrigin = getOrigin(devUrl)

  useEffect(() => {
    if (!props.showPage) {
      setDevLoading(true)
      return
    }
    if (!isDev) return
    setDevStatus('idle')
    setDevErrorMsg('')
    getItem({ key: 'lynx_shell_debug_dev_url' }, (res) => {
      if (res?.code === 1) {
        const url = String(res?.data?.data || '')
        setDevUrl(url)
        setDevUrlInput(url)
      } else if (res?.code != null && res.code < 0) {
        setDevStatus('pipe-error')
        setDevErrorMsg(res?.msg || '')
      }
      setDevLoading(false)
    })
  }, [props.showPage])

  if (!props.showPage) return <></>

  const dk = (base: string) => `${base} ${isDark ? `${base}--dark` : `${base}--light`}`

  // --- Theme picker ---
  const themes: Array<{ label: string; value: 'Auto' | 'Light' | 'Dark'; icon: string }> = [
    { label: '跟随系统', value: 'Auto', icon: '\u2728' },
    { label: '浅色', value: 'Light', icon: '\u2600' },
    { label: '深色', value: 'Dark', icon: '\u{1F319}' },
  ]

  const handleThemeSelect = (value: 'Auto' | 'Light' | 'Dark') => {
    'background only'
    setPreference(value)
  }

  // --- Dev URL validation & handlers ---
  const isValidUrl = /^https?:\/\/.+/.test(devUrlInput)
  const hasChanges = devUrlInput !== devUrl
  const canSave = isValidUrl && hasChanges
  const showValidation = devUrlInput.length > 0 && !isValidUrl
  const hasMismatch = isConnected && !!persistedOrigin && runtimeOrigin !== persistedOrigin && devStatus === 'idle'

  const handleDevUrlInput = (event: { detail: { value: string } }) => {
    'background only'
    setDevUrlInput(event.detail.value.trim())
    // Clear stale feedback when user edits
    if (devStatus === 'saved' || devStatus === 'save-error') {
      setDevStatus('idle')
    }
  }

  const handleDevUrlSave = () => {
    'background only'
    if (!canSave) return
    setItem(
      { key: 'lynx_shell_debug_dev_url', data: devUrlInput },
      (res) => {
        if (res?.code === 1) {
          setDevUrl(devUrlInput)
          setDevStatus('saved')
          setDevErrorMsg('')
        } else {
          setDevStatus('save-error')
          setDevErrorMsg(res?.msg || '保存失败，请检查手工调试桥是否可用。')
        }
      },
    )
  }

  // --- System info ---
  // @ts-ignore - SystemInfo is a Lynx global
  const sysInfo = typeof SystemInfo !== 'undefined' ? SystemInfo : {} as any

  const systemInfo = [
    { label: 'Lynx SDK 版本', value: sysInfo.lynxSdkVersion || sysInfo.engineVersion || 'N/A' },
    { label: '平台', value: sysInfo.platform || 'N/A' },
    { label: '系统版本', value: sysInfo.osVersion || 'N/A' },
    { label: '像素密度', value: sysInfo.pixelRatio != null ? String(sysInfo.pixelRatio) : 'N/A' },
    { label: '屏幕宽度', value: sysInfo.pixelWidth != null ? String(sysInfo.pixelWidth) + 'px' : 'N/A' },
    { label: '屏幕高度', value: sysInfo.pixelHeight != null ? String(sysInfo.pixelHeight) + 'px' : 'N/A' },
  ]

  return (
    <scroll-view className="tab-content" scroll-orientation="vertical">
      <view className={`page ${isDark ? 'page--dark' : 'page--light'}`} style={{ paddingTop: `${props.topInset + 16}px` }}>
        <text className={dk('page-title')}>设置</text>

        {/* Theme Picker */}
        <view className={dk('card')}>
          <text className={dk('card-label')}>外观</text>
          <view className="theme-picker">
            {themes.map((t) => (
              <view
                key={t.value}
                className={`theme-option ${preference === t.value ? (isDark ? 'theme-option--active-dark' : 'theme-option--active-light') : (isDark ? 'theme-option--inactive-dark' : 'theme-option--inactive-light')}`}
                bindtap={() => handleThemeSelect(t.value)}
              >
                <text className="theme-option-icon">{t.icon}</text>
                <text className={`theme-option-label ${preference === t.value ? 'theme-option-label--active' : (isDark ? 'theme-option-label--dark' : 'theme-option-label--light')}`}>
                  {t.label}
                </text>
              </view>
            ))}
          </view>
        </view>

        {/* Dev Server (only in dev mode) */}
        {isDev ? (
          <view className={dk('card')}>
            <view className="card-header-row">
              <text className="card-header-icon">{'\u{1F6E0}'}</text>
              <text className={dk('card-label')}>开发服务器</text>
            </view>

            {/* ── Connection status ── */}
            <view className="dev-status-row">
              <view className={`dev-status-dot ${isConnected ? 'dev-status-dot--connected' : 'dev-status-dot--local'}`} />
              <text className={dk('dev-status-text')}>
                {isConnected ? '已连接开发服务器' : '正在使用本地资源'}
              </text>
            </view>
            {isConnected ? (
              <text className={dk('dev-runtime-url')}>{runtimeOrigin}</text>
            ) : null}

            {/* ── URL editor (or loading / error state) ── */}
            {devLoading ? (
              <text className={dk('dev-hint')}>正在读取配置…</text>
            ) : devStatus === 'pipe-error' ? null
            : (
              <>
                <text className={dk('dev-field-label')}>已配置 URL</text>
                <view className="input-row">
                  <input
                    className={dk('url-input')}
                    defaultValue={devUrlInput}
                    bindinput={handleDevUrlInput}
                    placeholder="http://192.168.1.100:5969/"
                    style={{ color: isDark ? '#ffffff' : '#000000' }}
                  />
                  <view
                    className={`dev-url-save ${canSave ? 'dev-url-save--active' : 'dev-url-save--disabled'}`}
                    bindtap={handleDevUrlSave}
                  >
                    <text className={`dev-url-save-text ${canSave ? '' : 'dev-url-save-text--disabled'}`}>保存</text>
                  </view>
                </view>

                {/* Inline validation */}
                {showValidation ? (
                  <text className="dev-hint dev-hint--error">必须以 http:// 或 https:// 开头</text>
                ) : null}

                {/* Save success */}
                {devStatus === 'saved' ? (
                  <view className="dev-banner dev-banner--success">
                    <text className={dk('dev-banner-text')}>
                      {'\u2713'}  保存成功。
                    </text>
                    <text className={dk('dev-banner-detail')}>
                      重启 App 后将从新服务器加载 Bundle。
                    </text>
                  </view>
                ) : null}

                {/* Save error */}
                {devStatus === 'save-error' ? (
                  <view className="dev-banner dev-banner--error">
                    <text className={dk('dev-banner-text')}>
                      {'\u2717'}  保存失败。
                    </text>
                    <text className={dk('dev-banner-detail')}>
                      {devErrorMsg}
                    </text>
                  </view>
                ) : null}

                {/* Mismatch: configured server ≠ active server */}
                {hasMismatch ? (
                  <view className="dev-banner dev-banner--info">
                    <text className={dk('dev-banner-text')}>
                      已配置服务器（{persistedOrigin}）与当前连接（{runtimeOrigin}）不一致。
                    </text>
                    <text className={dk('dev-banner-detail')}>
                      重启 App 后将连接到已配置服务器。
                    </text>
                  </view>
                ) : null}
              </>
            )}
          </view>
        ) : null}

        {/* System Info */}
        <view className={dk('card')}>
          <text className={dk('card-label')}>系统信息</text>
          {systemInfo.map((item) => (
            <view key={item.label} className="info-row">
              <text className={dk('info-label')}>{item.label}</text>
              <text className={dk('info-value')}>{item.value}</text>
            </view>
          ))}
        </view>

        {/* Footer */}
        <view className="home-footer">
          <text className={dk('home-footer-text')}>
            跨平台 Lynx 调试壳
          </text>
        </view>
      </view>
    </scroll-view>
  )
}

function MainContent() {
  const [activePage, setActivePage] = useState<TabPage>('home')
  const { resolved } = useTheme()
  const isDark = resolved === 'dark'

  // Read safe area insets directly from globalProps.
  // Only apply top padding when we're the root page (hide_nav_bar=1, no native nav bar).
  // When loaded as a sub-page with native nav bar, the native SPKViewController
  // already offsets the LynxView below the nav bar — applying topHeight again
  // would create double padding.
  const gp = (lynx.__globalProps || {}) as Record<string, any>
  const queryItems = (gp.queryItems || {}) as Record<string, string>
  const hasNativeNavBar = queryItems.hide_nav_bar !== '1'
  const topInset = hasNativeNavBar ? 0 : (Number(gp.topHeight) || 0)
  const bottomInset = Number(gp.bottomHeight) || 0

  // Native Tab Host mode: the host owns tab selection and bottom chrome. Lynx only
  // renders the requested tab content, so an Android Fragment/iOS UIViewController/
  // Harmony Container can keep this page alive without duplicating a Lynx TabBar.
  const nativeTabId = String(queryItems.native_tab_id || '').toLowerCase()
  if (nativeTabId === 'home' || nativeTabId === 'settings') {
    return (
      <view
        className={`app-root ${isDark ? 'app-root--dark' : 'app-root--light'}`}
      >
        <HomePage showPage={nativeTabId === 'home'} topInset={topInset} />
        <SettingsPage showPage={nativeTabId === 'settings'} topInset={topInset} />
      </view>
    )
  }

  return (
    <view
      className={`app-root ${isDark ? 'app-root--dark' : 'app-root--light'}`}
    >
      <HomePage showPage={activePage === 'home'} topInset={topInset} />
      <SettingsPage showPage={activePage === 'settings'} topInset={topInset} />
      <view style={{ paddingBottom: `${bottomInset}px`, backgroundColor: isDark ? '#1c1c1e' : '#ffffff' }}>
        <Navigator activePage={activePage} onNavigate={setActivePage} />
      </view>
    </view>
  )
}

export function App() {
  return (
    <ThemeProvider>
      <MainContent />
    </ThemeProvider>
  )
}
