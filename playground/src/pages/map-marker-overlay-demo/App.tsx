import { useRef, useState } from '@lynx-js/react'
import { MapTopBar } from '../../components/MapTopBar/index.js'
import { SafeAreaView } from '../../components/SafeAreaView.js'
import { LynxMap, type LynxMapRef } from '../../native-elements/map/index.js'
import { ThemeProvider, useTheme } from '../../lib/theme.js'
import './App.css'

const overlayCoordinate = { latitude: 39.918, longitude: 116.421 }

function OverlayContent() {
  const { resolved } = useTheme()
  const dark = resolved === 'dark'
  const mapRef = useRef<LynxMapRef>(null)
  const [overlay, setOverlay] = useState({ x: 0, y: 0, visible: false })
  const [status, setStatus] = useState('等待地图 ready')

  const projectOverlay = () => {
    'background only'
    mapRef.current?.projectCoordinate(overlayCoordinate)
      .then((point) => {
        setOverlay({ x: point.x - 72, y: point.y - 76, visible: point.visible })
        setStatus(`projectCoordinate：x=${Math.round(point.x)} y=${Math.round(point.y)} visible=${String(point.visible)}`)
      })
      .catch((error) => setStatus(`投影失败：${error.message}`))
  }

  return (
    <SafeAreaView className="overlay-demo-shell" edges={['top', 'bottom']} style={{ height: '100vh' }}>
      <MapTopBar title="Lynx Marker Overlay" subtitle="地图坐标投影 / Lynx 内容叠加" dark={dark} />
      <scroll-view className="overlay-demo-scroll" scroll-orientation="vertical">
        <view className={`overlay-demo-page ${dark ? 'overlay-demo-page--dark' : ''}`}>
          <text className="overlay-demo-title">Lynx 内容跟随地图 Marker</text>
          <text className="overlay-demo-description">这个卡片是 Lynx view，不是 AMapAnnotationView。地图平移、缩放和旋转后，页面通过 projectCoordinate 更新卡片位置。</text>
          <view className="overlay-demo-stage">
            <LynxMap
              ref={mapRef}
              id="ios-amap-marker-overlay-demo"
              className="overlay-demo-map"
              center={{ latitude: 39.92, longitude: 116.4 }}
              zoom={12}
              markers={[{ id: 'overlay-anchor', coordinate: overlayCoordinate, title: 'Overlay 锚点', visible: true }]}
              onReady={() => { setStatus('地图 ready'); projectOverlay() }}
              onRegionChange={projectOverlay}
              onError={(error) => setStatus(`${error.code}：${error.message}`)}
            />
            <view className="overlay-demo-card" style={{ left: overlay.x, top: overlay.y, display: overlay.visible ? 'flex' : 'none' }}>
              <text className="overlay-demo-card-title">北京门店</text>
              <text className="overlay-demo-card-copy">LynxView Overlay</text>
              <text className="overlay-demo-card-action">查看详情</text>
            </view>
          </view>
          <view className="overlay-demo-actions">
            <view className="overlay-demo-action" bindtap={projectOverlay} accessibility-label="重新投影 Marker Overlay" accessibility-traits="button"><text className="overlay-demo-action-text">重新投影</text></view>
          </view>
          <view className="overlay-demo-card-panel">
            <text className="overlay-demo-panel-title">当前状态</text>
            <text className="overlay-demo-panel-copy">{status}</text>
            <text className="overlay-demo-panel-copy">Overlay 由 Lynx 页面创建和销毁，MapKit 只提供坐标投影，不持有页面 View。</text>
          </view>
          <view className="overlay-demo-card-panel overlay-demo-card-panel--note">
            <text className="overlay-demo-panel-title">边界</text>
            <text className="overlay-demo-panel-copy">地图快速移动期间使用最新坐标覆盖旧结果，页面退出时 Overlay 随 LynxView 一起释放。</text>
          </view>
        </view>
      </scroll-view>
    </SafeAreaView>
  )
}

export function App() {
  return <ThemeProvider><OverlayContent /></ThemeProvider>
}
