import { useLocale } from '../../lib/locale.js'
import { configureLocaleResources } from '../../lib/i18n.js'
import { ThemeProvider, useTheme } from '../../lib/theme.js'
import { DemoPage } from '../../components/DemoPage/index.js'

import './App.css'

configureLocaleResources({
  'zh-CN': {
    'i18n.title': '国际化 Bundle 测试',
    'i18n.description': '这个页面验证宿主语言状态、资源切换和后续页面的 locale 参数。',
    'i18n.currentLocale': '当前语言：{{locale}}',
    'i18n.source': '状态来源：{{source}} · revision：{{revision}}',
    'i18n.routeLocale': '打开参数 locale：{{locale}}',
    'i18n.switchChinese': '切换到简体中文',
    'i18n.switchEnglish': '切换到 English (US)',
    'i18n.expectation': '点击语言按钮后，本页应原位更新；返回 Settings 或切换 Tab 时状态保持。',
  },
  'en-US': {
    'i18n.title': 'Internationalization Bundle Test',
    'i18n.description': 'This page verifies the host locale state, resource switching, and the locale marker passed to new pages.',
    'i18n.currentLocale': 'Current locale: {{locale}}',
    'i18n.source': 'Source: {{source}} · revision: {{revision}}',
    'i18n.routeLocale': 'Route locale marker: {{locale}}',
    'i18n.switchChinese': 'Switch to Simplified Chinese',
    'i18n.switchEnglish': 'Switch to English (US)',
    'i18n.expectation': 'After tapping a language button, this page should update in place; the state remains when returning to Settings or switching Tabs.',
  },
})

function I18nDemoContent() {
  const { resolved } = useTheme()
  const { state, locale, setLocale, t } = useLocale()
  const isDark = resolved === 'dark'
  const globalProps = (lynx.__globalProps || {}) as Record<string, any>
  const queryItems = (globalProps.queryItems || {}) as Record<string, unknown>
  const routeLocale = String(queryItems.locale || '未提供')
  const dk = (base: string) => `${base} ${isDark ? `${base}--dark` : `${base}--light`}`

  return (
    <DemoPage title={t('i18n.title', '国际化 Bundle 测试')}>
      <view className={dk('i18n-card')}>
        <text className={dk('i18n-title')}>{t('i18n.title', '国际化 Bundle 测试')}</text>
        <text className={dk('i18n-description')}>
          {t('i18n.description', '这个页面验证宿主语言状态、资源切换和后续页面的 locale 参数。')}
        </text>
        <view className={dk('i18n-state')}>
          <text className={dk('i18n-state-label')}>
            {t('i18n.currentLocale', '当前语言：{{locale}}', { locale })}
          </text>
          <text className={dk('i18n-state-label')}>
            {t('i18n.source', '状态来源：{{source}} · revision：{{revision}}', {
              source: state.source,
              revision: state.revision,
            })}
          </text>
          <text className={dk('i18n-state-label')}>
            {t('i18n.routeLocale', '打开参数 locale：{{locale}}', { locale: routeLocale })}
          </text>
        </view>
        <text className={dk('i18n-hint')}>
          {t('i18n.expectation', '点击语言按钮后，本页应原位更新；返回 Settings 或切换 Tab 时状态保持。')}
        </text>
        <view
          className={dk('i18n-button')}
          bindtap={() => setLocale('zh-CN')}
          accessibility-element
          accessibility-label={t('i18n.switchChinese', '切换到简体中文')}
          accessibility-traits="button"
        >
          <text className="i18n-button-text">{t('i18n.switchChinese', '切换到简体中文')}</text>
        </view>
        <view
          className={dk('i18n-button')}
          bindtap={() => setLocale('en-US')}
          accessibility-element
          accessibility-label={t('i18n.switchEnglish', '切换到 English (US)')}
          accessibility-traits="button"
        >
          <text className="i18n-button-text">{t('i18n.switchEnglish', '切换到 English (US)')}</text>
        </view>
      </view>
    </DemoPage>
  )
}

export function App() {
  return (
    <ThemeProvider>
      <I18nDemoContent />
    </ThemeProvider>
  )
}
