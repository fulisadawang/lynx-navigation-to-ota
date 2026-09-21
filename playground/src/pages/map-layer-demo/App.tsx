import { useState } from '@lynx-js/react'
import { MapTopBar } from '../../components/MapTopBar/index.js'
import { SafeAreaView } from '../../components/SafeAreaView.js'
import { ThemeProvider, useTheme } from '../../lib/theme.js'
import { LynxMap } from '../../native-elements/map/index.js'
import './App.css'

type LayerMapType = 'standard' | 'satellite' | 'night' | 'navi'

const mapTypes: LayerMapType[] = ['standard', 'satellite', 'night', 'navi']
const layerMarkers = [
  { id: 'layer-a', coordinate: { latitude: 39.9042, longitude: 116.4074 }, title: '图层点 A' },
  { id: 'layer-b', coordinate: { latitude: 39.925, longitude: 116.43 }, title: '图层点 B' },
]
const layerPolyline = [{ id: 'layer-route', points: [{ latitude: 39.89, longitude: 116.36 }, { latitude: 39.92, longitude: 116.4 }, { latitude: 39.95, longitude: 116.45 }], color: '#087cf9', width: 7 }]

function LayerContent() {
  const { resolved } = useTheme()
  const [mapType, setMapType] = useState<LayerMapType>('standard')
  const [traffic, setTraffic] = useState(false)
  const [overlayVisible, setOverlayVisible] = useState(true)
  const [overlayOpacity, setOverlayOpacity] = useState(1)
  const [labels, setLabels] = useState(true)
  const [buildings, setBuildings] = useState(true)
  const [status, setStatus] = useState('等待图层操作')
  const dark = resolved === 'dark'

  const cycleType = () => {
    'background only'
    const next = mapTypes[(mapTypes.indexOf(mapType) + 1) % mapTypes.length]
    setMapType(next)
    setStatus(`map-type：${next}`)
  }

  return (
    <SafeAreaView className="layer-shell" edges={['top', 'bottom']} style={{ height: '100vh' }}>
      <MapTopBar title="图层与地图样式" subtitle="底图 / 路况 / overlay 控制" dark={dark} />
      <scroll-view className="layer-scroll" scroll-orientation="vertical">
        <view className={`layer-page ${dark ? 'layer-page--dark' : 'layer-page--light'}`}>
          <text className="layer-title">图层控制实验室</text>
          <text className="layer-description">把底图、实时路况、Marker/Polyline overlay、文字和建筑显示拆成独立控制项，观察每次 props 更新的实际结果。</text>
          <view className="layer-map-stage">
            <LynxMap
              id="ios-amap-layer-demo"
              className="layer-map"
              center={{ latitude: 39.92, longitude: 116.4 }}
              zoom={11}
              mapType={mapType}
              trafficEnabled={traffic}
              layerVisible={overlayVisible}
              layerOpacity={overlayOpacity}
              markers={layerMarkers}
              polylines={layerPolyline}
              showsLabels={labels}
              showsBuildings={buildings}
              showsCompass
              showsScale
              onReady={() => setStatus('地图 ready')}
              onError={(error) => setStatus(`${error.code}：${error.message}`)}
            />
            <view className="layer-overlay"><text className="layer-overlay-text">{mapType} · traffic {traffic ? 'on' : 'off'}</text></view>
          </view>
          <view className="layer-actions">
            <view className="layer-action" bindtap={cycleType} accessibility-label="切换底图类型" accessibility-traits="button"><text className="layer-action-text">底图：{mapType}</text></view>
            <view className="layer-action" bindtap={() => setTraffic((value) => !value)} accessibility-label="切换实时路况" accessibility-traits="button"><text className="layer-action-text">路况：{traffic ? '开' : '关'}</text></view>
            <view className="layer-action" bindtap={() => setOverlayVisible((value) => !value)} accessibility-label="切换覆盖物图层" accessibility-traits="button"><text className="layer-action-text">覆盖物：{overlayVisible ? '显示' : '隐藏'}</text></view>
            <view className="layer-action" bindtap={() => setOverlayOpacity((value) => value === 1 ? .35 : 1)} accessibility-label="切换覆盖物透明度" accessibility-traits="button"><text className="layer-action-text">透明度：{overlayOpacity}</text></view>
            <view className="layer-action layer-action--secondary" bindtap={() => setLabels((value) => !value)} accessibility-label="切换地图文字" accessibility-traits="button"><text className="layer-action-text">文字：{labels ? '开' : '关'}</text></view>
            <view className="layer-action layer-action--secondary" bindtap={() => setBuildings((value) => !value)} accessibility-label="切换建筑物" accessibility-traits="button"><text className="layer-action-text">建筑：{buildings ? '开' : '关'}</text></view>
          </view>
          <view className="layer-card"><text className="layer-card-title">当前状态</text><text className="layer-card-copy">{status}</text><text className="layer-card-copy">base={mapType} · traffic={String(traffic)} · overlay={String(overlayVisible)} · opacity={overlayOpacity}</text></view>
          <view className="layer-card layer-card--notes"><text className="layer-card-title">层级边界</text><text className="layer-card-copy">layer-visible、layer-opacity 和 layer-z-index 作用于当前 Element 管理的 overlay 层；底图与路况通过独立 props 控制。</text><text className="layer-card-copy">高德 overlay 的同层 zIndex 不等于跨底图、路况和文字层的全局排序。</text></view>
        </view>
      </scroll-view>
    </SafeAreaView>
  )
}

export function App() {
  return <ThemeProvider><LayerContent /></ThemeProvider>
}
