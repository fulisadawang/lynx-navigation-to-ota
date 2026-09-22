import { useState } from '@lynx-js/react'
import { SafeAreaView } from '../../components/SafeAreaView.js'
import { MapTopBar } from '../../components/MapTopBar/index.js'
import { ThemeProvider, useTheme } from '../../lib/theme.js'
import { LynxMap } from '../../native-elements/map/index.js'
import './App.css'

const center = { latitude: 39.9042, longitude: 116.4074 }
const markers = [
  { id: 'layout-center', coordinate: center, title: '布局中心', selected: true },
  { id: 'layout-west', coordinate: { latitude: 39.913, longitude: 116.363 }, title: '西侧点位' },
]
const polylines = [{
  id: 'layout-route',
  points: [center, { latitude: 39.913, longitude: 116.363 }, { latitude: 39.91, longitude: 116.43 }],
  color: '#0A7CF9',
  width: 6,
}]

function LayoutContent() {
  const { resolved } = useTheme()
  const [mode, setMode] = useState<'fixed' | 'fullscreen'>('fixed')
  const [logs, setLogs] = useState<string[]>([])
  const isDark = resolved === 'dark'
  const appendLog = (value: string) => setLogs((current) => [value, ...current].slice(0, 4))
  const darkSuffix = isDark ? '--dark' : '--light'

  return (
    <SafeAreaView edges={['top', 'bottom']} style={{ height: '100vh' }}>
      <view className={`map-layout map-layout--${mode} ${isDark ? 'map-layout--dark' : 'map-layout--light'}`}>
        <MapTopBar title="地图布局实验室" subtitle="返回 Playground" dark={isDark} />
        <view className="map-layout-toolbar">
          <view className="map-layout-switcher">
            <view className={`map-layout-chip ${mode === 'fixed' ? 'map-layout-chip--active' : ''}`} bindtap={() => setMode('fixed')} accessibility-label="固定 320px" accessibility-traits="button">
              <text className="map-layout-chip-text">固定 320px</text>
            </view>
            <view className={`map-layout-chip ${mode === 'fullscreen' ? 'map-layout-chip--active' : ''}`} bindtap={() => setMode('fullscreen')} accessibility-label="全屏" accessibility-traits="button">
              <text className="map-layout-chip-text">全屏</text>
            </view>
          </view>
        </view>

        <view className="map-layout-stage">
          <LynxMap
            id="ios-amap-layout"
            className="map-layout-map"
            center={center}
            zoom={12}
            bearing={mode === 'fullscreen' ? 18 : 0}
            pitch={mode === 'fullscreen' ? 12 : 0}
            markers={markers}
            polylines={polylines}
            showsCompass={mode === 'fullscreen'}
            showsScale={mode === 'fullscreen'}
            onReady={(detail) => appendLog(`ready: ${detail.provider}`)}
            onError={(detail) => appendLog(`error: ${detail.code}`)}
            onMapTap={(detail) => appendLog(`tap: ${detail.coordinate.latitude.toFixed(3)}`)}
            onMarkerSelected={(detail) => appendLog(`selected: ${detail.id}`)}
            onLongPress={(detail) => appendLog(`longpress: ${detail.coordinate.latitude.toFixed(3)}`)}
          />
          <view className="map-layout-overlay">
            <text className="map-layout-overlay-title">Lynx Overlay</text>
            <text className="map-layout-overlay-copy">{mode === 'fixed' ? '固定尺寸容器内的 sibling overlay' : '全屏 MapView 上方的 safe-area overlay'}</text>
          </view>
          {mode === 'fullscreen' && <view className="map-layout-bottom-overlay"><text className="map-layout-bottom-text">全屏模式 · bearing 18° · pitch 12°</text></view>}
        </view>

        <view className={`map-layout-footer ${darkSuffix}`}>
          <text className="map-layout-footer-title">布局验收</text>
          <text className="map-layout-footer-copy">当前模式：{mode === 'fixed' ? '固定宽高' : '全屏填充'}；MapView 由 Lynx frame 驱动，overlay 保持在原生地图上方。</text>
          {logs.map((item) => <text key={item} className="map-layout-footer-copy">{item}</text>)}
        </view>
      </view>
    </SafeAreaView>
  )
}

export function App() {
  return (
    <ThemeProvider>
      <LayoutContent />
    </ThemeProvider>
  )
}
