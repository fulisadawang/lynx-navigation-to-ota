import { useRef, useState } from '@lynx-js/react'
import { MapTopBar } from '../../components/MapTopBar/index.js'
import { SafeAreaView } from '../../components/SafeAreaView.js'
import { ThemeProvider, useTheme } from '../../lib/theme.js'
import { LynxMap, type LynxMapCapabilities, type LynxMapRef } from '../../native-elements/map/index.js'
import './App.css'

const center = { latitude: 39.9042, longitude: 116.4074 }

const initialMarkers = [
  { id: 'beijing', coordinate: center, title: '北京中心' },
  { id: 'west', coordinate: { latitude: 39.913, longitude: 116.363 }, title: '西侧点位' },
]

const initialPolylines = [{
  id: 'demo-route',
  points: [center, { latitude: 39.913, longitude: 116.363 }, { latitude: 39.91, longitude: 116.43 }],
  color: '#0A7CF9',
  width: 6,
}]

function MapDiagnosticContent() {
  const { resolved } = useTheme()
  const mapRef = useRef<LynxMapRef>(null)
  const [mapType, setMapType] = useState<'standard' | 'satellite'>('standard')
  const [trafficEnabled, setTrafficEnabled] = useState(false)
  const [layerVisible, setLayerVisible] = useState(true)
  const [bearing, setBearing] = useState(0)
  const [pitch, setPitch] = useState(0)
  const [log, setLog] = useState<string[]>([])
  const [capabilities, setCapabilities] = useState<LynxMapCapabilities | null>(null)
  const isDark = resolved === 'dark'
  const dk = (base: string) => `${base} ${isDark ? `${base}--dark` : `${base}--light`}`

  const appendLog = (value: string) => setLog((current) => [value, ...current].slice(0, 8))
  const moveCamera = () => {
    'background only'
    mapRef.current?.moveCamera({ center, zoom: 14, animated: true })
      .then(() => appendLog('moveCamera: ok'))
      .catch(() => appendLog('moveCamera: fail'))
  }
  const readCamera = () => {
    'background only'
    mapRef.current?.getCamera()
      .then((value) => appendLog(`getCamera: ${value.zoom?.toFixed(2) || 'n/a'}`))
      .catch(() => appendLog('getCamera: fail'))
  }
  const readCameraState = () => {
    'background only'
    mapRef.current?.getCameraState()
      .then((value) => appendLog(`cameraState: b${value.bearing?.toFixed(0) || '0'} p${value.pitch?.toFixed(0) || '0'}`))
      .catch(() => appendLog('cameraState: fail'))
  }
  const fitBounds = () => {
    'background only'
    mapRef.current?.fitBounds({ bounds: { southwest: { latitude: 39.89, longitude: 116.34 }, northeast: { latitude: 39.93, longitude: 116.45 } }, padding: 24, animated: true })
      .then(() => appendLog('fitBounds: ok'))
      .catch(() => appendLog('fitBounds: fail'))
  }
  const readCapabilities = () => {
    'background only'
    mapRef.current?.getCapabilities()
      .then((value) => { setCapabilities(value); appendLog(`capability: ${String(value.available)}`) })
      .catch(() => appendLog('capability: fail'))
  }
  const selectMarker = () => {
    'background only'
    mapRef.current?.selectMarker('beijing')
      .then(() => appendLog('selectMarker: ok'))
      .catch(() => appendLog('selectMarker: fail'))
  }
  const showMarkers = () => {
    'background only'
    mapRef.current?.showMarkers(['beijing', 'west'], 24)
      .then(() => appendLog('showMarkers: ok'))
      .catch(() => appendLog('showMarkers: fail'))
  }
  const readPerformance = () => {
    'background only'
    mapRef.current?.getPerformanceSnapshot()
      .then((value) => appendLog(`native apply: ${value.lastApplyDurationMs.toFixed(2)}ms`))
      .catch(() => appendLog('performance: fail'))
  }

  return (
    <SafeAreaView className="map-diagnostic-shell" edges={['top', 'bottom']} style={{ height: '100vh' }}>
      <MapTopBar title="高德地图 Native Element" subtitle="地图 API 诊断" dark={isDark} />
      <scroll-view className="map-diagnostic-scroll" scroll-orientation="vertical">
        <view className={dk('map-page')}>
        <text className={dk('map-title')}>高德地图 Native Element</text>
        <text className={dk('map-description')}>
          验证固定尺寸、Lynx 覆盖层、图层状态、相机方法和生命周期事件。
        </text>

        <view className="map-stage">
          <LynxMap
            ref={mapRef}
            id="ios-amap-diagnostic"
            className="map-fixed"
            center={center}
            zoom={12}
            bearing={bearing}
            pitch={pitch}
            markers={initialMarkers}
            polylines={initialPolylines}
            mapType={mapType}
            trafficEnabled={trafficEnabled}
            layerVisible={layerVisible}
            onReady={(detail) => appendLog(`ready: ${detail.provider}`)}
            onError={(detail) => appendLog(`error: ${detail.code}`)}
            onMapTap={(detail) => appendLog(`maptap: ${detail.coordinate.latitude.toFixed(3)}`)}
            onMarkerTap={(detail) => appendLog(`markertap: ${detail.id}`)}
            onMarkerSelected={(detail) => appendLog(`selected: ${detail.id}`)}
            onMarkerDeselected={(detail) => appendLog(`deselected: ${detail.id}`)}
            onMarkerDrag={(detail) => appendLog(`drag: ${detail.id}:${detail.phase}`)}
            onLongPress={(detail) => appendLog(`longpress: ${detail.coordinate.latitude.toFixed(3)}`)}
            onRegionChange={(detail) => appendLog(`region: ${detail.source || 'unknown'}:${detail.phase || detail.reason || 'unknown'}`)}
          />
          <view className={dk('map-overlay')}>
            <text className={dk('map-overlay-title')}>LynxView Overlay</text>
            <text className={dk('map-overlay-copy')}>此内容位于地图原生 View 上方</text>
          </view>
        </view>

        <view className="map-actions">
          <view className="map-action" bindtap={() => setMapType(mapType === 'standard' ? 'satellite' : 'standard')}>
            <text className="map-action-text">切换底图</text>
          </view>
          <view className="map-action" bindtap={() => setTrafficEnabled(!trafficEnabled)}>
            <text className="map-action-text">路况：{trafficEnabled ? '开' : '关'}</text>
          </view>
          <view className="map-action" bindtap={() => setLayerVisible(!layerVisible)}>
            <text className="map-action-text">覆盖物：{layerVisible ? '显示' : '隐藏'}</text>
          </view>
          <view className="map-action" bindtap={() => { setBearing(bearing === 0 ? 24 : 0); setPitch(pitch === 0 ? 18 : 0) }}>
            <text className="map-action-text">3D 相机</text>
          </view>
          <view className="map-action" bindtap={moveCamera}>
            <text className="map-action-text">移动相机</text>
          </view>
          <view className="map-action" bindtap={readCamera}>
            <text className="map-action-text">读取相机</text>
          </view>
          <view className="map-action" bindtap={readCameraState}>
            <text className="map-action-text">读取 3D 相机</text>
          </view>
          <view className="map-action" bindtap={fitBounds}>
            <text className="map-action-text">适配范围</text>
          </view>
          <view className="map-action" bindtap={readCapabilities}>
            <text className="map-action-text">读取能力</text>
          </view>
          <view className="map-action" bindtap={selectMarker}>
            <text className="map-action-text">选中 Marker</text>
          </view>
          <view className="map-action" bindtap={showMarkers}>
            <text className="map-action-text">显示 Marker</text>
          </view>
          <view className="map-action" bindtap={readPerformance}>
            <text className="map-action-text">读取性能</text>
          </view>
        </view>

        <view className={dk('map-status')}>
          <text className={dk('map-status-title')}>事件与能力</text>
          {capabilities && <text className={dk('map-status-copy')}>provider={capabilities.provider} available={String(capabilities.available)} reason={capabilities.reasonCode || 'NONE'}</text>}
          {log.map((item) => <text key={item} className={dk('map-status-copy')}>{item}</text>)}
          {log.length === 0 && <text className={dk('map-status-copy')}>等待地图事件；缺少 SDK/Key 时会显示明确 error。</text>}
        </view>
        </view>
      </scroll-view>
    </SafeAreaView>
  )
}

export function App() {
  return (
    <ThemeProvider>
      <MapDiagnosticContent />
    </ThemeProvider>
  )
}
