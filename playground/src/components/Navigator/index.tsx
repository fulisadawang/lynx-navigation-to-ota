import { useLocale } from '../../lib/locale.js'
import { useTheme } from '../../lib/theme.js'
import './index.css'

export type TabPage = 'home' | 'settings'

interface NavigatorProps {
  activePage: TabPage
  onNavigate: (page: TabPage) => void
}

export function Navigator(props: NavigatorProps) {
  const { resolved } = useTheme()
  const { t } = useLocale()
  const isDark = resolved === 'dark'

  return (
    <view className={`navigator ${isDark ? 'navigator--dark' : 'navigator--light'}`}>
      <view
        className="nav-button"
        bindtap={() => props.onNavigate('home')}
        accessibility-element
        accessibility-label={t('nav.home', '首页')}
        accessibility-traits="button"
      >
        <text
          className={`nav-icon ${props.activePage === 'home' ? 'nav-icon--active' : ''}`}
        >
          {'\u{1F3E0}'}
        </text>
        <text
          className={`nav-label ${props.activePage === 'home' ? 'nav-label--active' : ''}`}
        >
          {t('nav.home', '首页')}
        </text>
      </view>
      <view
        className="nav-button"
        bindtap={() => props.onNavigate('settings')}
        accessibility-element
        accessibility-label={t('nav.settings', '设置')}
        accessibility-traits="button"
      >
        <text
          className={`nav-icon ${props.activePage === 'settings' ? 'nav-icon--active' : ''}`}
        >
          {'\u2699'}
        </text>
        <text
          className={`nav-label ${props.activePage === 'settings' ? 'nav-label--active' : ''}`}
        >
          {t('nav.settings', '设置')}
        </text>
      </view>
    </view>
  )
}
