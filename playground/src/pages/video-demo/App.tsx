import { useState } from '@lynx-js/react'
import { useLocale } from '../../lib/locale.js'
import { configureLocaleResources } from '../../lib/i18n.js'
import { ThemeProvider, useTheme } from '../../lib/theme.js'
import { DemoPage } from '../../components/DemoPage/index.js'

import './App.css'

const DEFAULT_VIDEO_URL = 'https://interactive-examples.mdn.mozilla.net/media/cc0-videos/flower.mp4'
type VideoMethod = 'play' | 'pause' | 'stop' | 'seek'

configureLocaleResources({
  'zh-CN': {
    'video.title': 'Video 组件测试',
    'video.description': '验证 Lynx 4.1 Video 的首帧、播放控制、seek 和错误事件。',
    'video.status': '状态：{{status}} · locale：{{locale}}',
    'video.source': '测试源：官方文档要求的在线 URL；网络不可用时会显示 error。',
  },
  'en-US': {
    'video.title': 'Video component test',
    'video.description': 'Verify Lynx 4.1 Video first frame, playback controls, seek and error events.',
    'video.status': 'Status: {{status}} · locale: {{locale}}',
    'video.source': 'Source: an online URL required by the official docs; offline playback reports error.',
  },
})

function VideoDemoContent() {
  const { resolved } = useTheme()
  const { locale, t } = useLocale()
  const [status, setStatus] = useState('idle')
  const isDark = resolved === 'dark'
  const dk = (base: string) => `${base} ${isDark ? `${base}--dark` : `${base}--light`}`

  const invokeVideo = (method: VideoMethod) => {
    'background only'
    lynx.createSelectorQuery().select('#lynx-41-video').invoke({
      method,
      params: method === 'seek' ? { position: 2 } : {},
      success: () => setStatus(method),
      fail: (result: unknown) => setStatus(`${method}: ${String(result)}`),
    }).exec()
  }

  return (
    <DemoPage title={t('video.title', 'Video 组件测试')}>
      <view className={dk('video-card')}>
        <text className={dk('video-title')}>{t('video.title', 'Video 组件测试')}</text>
        <text className={dk('video-description')}>
          {t('video.description', '验证 Lynx 4.1 Video 的首帧、播放控制、seek 和错误事件。')}
        </text>
        <video
          id="lynx-41-video"
          className={dk('video-player')}
          src={DEFAULT_VIDEO_URL}
          muted
          object-fit="contain"
          bindfirstframe={() => setStatus('firstframe')}
          bindplaying={() => setStatus('playing')}
          bindpaused={() => setStatus('paused')}
          bindstopped={() => setStatus('stopped')}
          bindended={() => setStatus('ended')}
          binderror={() => setStatus('error')}
        />
        <text className={dk('video-status')}>
          {t('video.status', '状态：{{status}} · locale：{{locale}}', { status, locale })}
        </text>
        <text className={dk('video-source')}>
          {t('video.source', '测试源：官方文档要求的在线 URL；网络不可用时会显示 error。')}
        </text>
        <view className="video-actions">
          {(['play', 'pause', 'stop', 'seek'] as VideoMethod[]).map((method) => (
            <view
              key={method}
              className={dk('video-action')}
              bindtap={() => invokeVideo(method)}
              accessibility-element
              accessibility-traits="button"
              accessibility-label={method}
            >
              <text className="video-action-text">{method}</text>
            </view>
          ))}
        </view>
      </view>
    </DemoPage>
  )
}

export function App() {
  return (
    <ThemeProvider>
      <VideoDemoContent />
    </ThemeProvider>
  )
}
