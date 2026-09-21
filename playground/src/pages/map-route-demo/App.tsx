import { useMemo, useRef, useState } from '@lynx-js/react'
import { MapTopBar } from '../../components/MapTopBar/index.js'
import { SafeAreaView } from '../../components/SafeAreaView.js'
import { searchRoute, type SearchCoordinate, type SearchPath } from '../../native-elements/search/index.js'
import { LynxMap, type LynxMapRef } from '../../native-elements/map/index.js'
import { ThemeProvider, useTheme } from '../../lib/theme.js'
import './App.css'

type RouteMode = 'driving' | 'walking' | 'riding'

const origin: SearchCoordinate = { latitude: 39.9042, longitude: 116.4074 }
const destination: SearchCoordinate = { latitude: 39.9388, longitude: 116.4333 }
const waypoints: SearchCoordinate[] = [
  { latitude: 39.918, longitude: 116.398 },
  { latitude: 39.927, longitude: 116.421 },
]

const fixturePaths: Record<RouteMode, SearchPath[]> = {
  driving: [{ distance: 6200, duration: 1120, tolls: 0, totalTrafficLights: 8, steps: [], polyline: [
    origin, { latitude: 39.912, longitude: 116.391 }, { latitude: 39.924, longitude: 116.409 }, { latitude: 39.933, longitude: 116.425 }, destination,
  ] }],
  walking: [{ distance: 3900, duration: 2860, tolls: 0, totalTrafficLights: 5, steps: [], polyline: [
    origin, { latitude: 39.909, longitude: 116.414 }, { latitude: 39.921, longitude: 116.425 }, { latitude: 39.932, longitude: 116.429 }, destination,
  ] }],
  riding: [{ distance: 4700, duration: 1420, tolls: 0, totalTrafficLights: 6, steps: [], polyline: [
    origin, { latitude: 39.914, longitude: 116.421 }, { latitude: 39.927, longitude: 116.435 }, { latitude: 39.936, longitude: 116.429 }, destination,
  ] }],
}

const routeColor: Record<RouteMode, string> = {
  driving: '#087cf9',
  walking: '#18a558',
  riding: '#af52de',
}

function boundsFor(points: SearchCoordinate[]) {
  const latitudes = points.map((point) => point.latitude)
  const longitudes = points.map((point) => point.longitude)
  return {
    southwest: { latitude: Math.min(...latitudes), longitude: Math.min(...longitudes) },
    northeast: { latitude: Math.max(...latitudes), longitude: Math.max(...longitudes) },
  }
}

function RouteContent() {
  const { resolved } = useTheme()
  const mapRef = useRef<LynxMapRef>(null)
  const [mode, setMode] = useState<RouteMode>('driving')
  const [remotePaths, setRemotePaths] = useState<Partial<Record<RouteMode, SearchPath[]>>>({})
  const [trafficEnabled, setTrafficEnabled] = useState(true)
  const [status, setStatus] = useState('使用固定路线 fixture，点击“请求高德算路”替换为真实结果')
  const dark = resolved === 'dark'
  const paths = remotePaths[mode] || fixturePaths[mode]
  const activePath = paths[0]
  const routePoints = useMemo(() => activePath.polyline, [activePath])
  const markers = useMemo(() => [
    { id: 'route-origin', coordinate: origin, title: '起点', selected: true },
    ...waypoints.map((coordinate, index) => ({ id: `route-waypoint-${index}`, coordinate, title: `途经点 ${index + 1}` })),
    { id: 'route-destination', coordinate: destination, title: '终点' },
  ], [])
  const renderedPolylines = useMemo(() => paths.map((path, index) => ({
    id: `route-${mode}-${index}`,
    points: path.polyline,
    color: index === 0 ? routeColor[mode] : '#9ca3af',
    width: index === 0 ? 8 : 4,
    opacity: index === 0 ? 1 : .58,
    zIndex: index === 0 ? 2 : 1,
  })), [mode, paths])

  const selectMode = (next: RouteMode) => {
    'background only'
    setMode(next)
    setStatus(`${next} 路线已切换；当前显示 ${remotePaths[next] ? '高德返回' : 'fixture'} 路线`)
  }

  const fitRoute = () => {
    'background only'
    mapRef.current?.fitBounds({ bounds: boundsFor([...routePoints, origin, destination]), padding: 40, animated: true })
      .then(() => setStatus('fitBounds：路线已适配视野'))
      .catch(() => setStatus('fitBounds：调用失败'))
  }

  const requestAMapRoute = () => {
    'background only'
    setStatus(`请求高德 ${mode} 路线…`)
    searchRoute({ mode, origin, destination, waypoints: mode === 'driving' ? waypoints : undefined, strategy: 32 })
      .then((result) => {
        const next = (result.paths || []).filter((path) => Array.isArray(path?.polyline) && path.polyline.length >= 2)
        if (next.length === 0) {
          setStatus(`高德 ${mode} 未返回可渲染路线，保留 fixture polyline`)
          return
        }
        setRemotePaths((current) => ({ ...current, [mode]: next }))
        setStatus(`高德 ${mode} 返回 ${next.length} 条路线，已回填 polyline`)
      })
      .catch((error) => setStatus(`${mode}：${error.message}`))
  }

  return (
    <SafeAreaView className="route-shell" edges={['top', 'bottom']} style={{ height: '100vh' }}>
      <MapTopBar title="路线渲染实验室" subtitle="驾车 / 步行 / 骑行 · Polyline" dark={dark} />
      <scroll-view className="route-scroll" scroll-orientation="vertical">
        <view className={`route-page ${dark ? 'route-page--dark' : 'route-page--light'}`}>
          <text className="route-title">路线规划与渲染</text>
          <text className="route-description">每种出行方式都有独立的路线颜色、起终点、途经点、距离、耗时和 polyline；可以先用固定 fixture 验收渲染，再请求 AMapSearchKit 真实算路。</text>

          <view className="route-mode-row">
            {(['driving', 'walking', 'riding'] as RouteMode[]).map((item) => (
              <view key={item} className={`route-mode ${mode === item ? 'route-mode--active' : ''}`} bindtap={() => selectMode(item)} accessibility-label={`切换${item}路线`} accessibility-traits="button">
                <text className="route-mode-text">{item === 'driving' ? '驾车' : item === 'walking' ? '步行' : '骑行'}</text>
              </view>
            ))}
          </view>

          <view className="route-map-stage">
            <LynxMap
              ref={mapRef}
              id="ios-amap-route-demo"
              className="route-map"
              center={origin}
              zoom={12}
              trafficEnabled={trafficEnabled}
              markers={markers}
              polylines={renderedPolylines}
              onReady={() => setStatus('地图 ready，路线 fixture 已渲染')}
              onError={(error) => setStatus(`${error.code}：${error.message}`)}
              onMapTap={() => setStatus('maptap：路线地图点击已触发')}
            />
            <view className="route-map-overlay"><text className="route-map-overlay-text">{mode} · {remotePaths[mode] ? 'AMap result' : 'fixture'} · {paths.length} route</text></view>
          </view>

          <view className="route-actions">
            <view className="route-action" bindtap={requestAMapRoute} accessibility-label="请求高德算路" accessibility-traits="button"><text className="route-action-text">请求高德算路</text></view>
            <view className="route-action" bindtap={fitRoute} accessibility-label="适配路线范围" accessibility-traits="button"><text className="route-action-text">适配路线范围</text></view>
            <view className="route-action route-action--secondary" bindtap={() => setTrafficEnabled((value) => !value)} accessibility-label="切换路线实时路况" accessibility-traits="button"><text className="route-action-text">路况：{trafficEnabled ? '开' : '关'}</text></view>
          </view>

          <view className="route-card">
            <text className="route-card-title">{mode} 路线数据</text>
            <text className="route-card-copy">distance：{activePath.distance} m · duration：{activePath.duration} s</text>
            <text className="route-card-copy">traffic lights：{activePath.totalTrafficLights} · tolls：¥{activePath.tolls}</text>
            <text className="route-card-copy">polyline points：{activePath.polyline.length} · waypoints：{waypoints.length}</text>
            <text className="route-card-status">{status}</text>
          </view>

          <view className="route-card route-card--notes">
            <text className="route-card-title">渲染验收点</text>
            <text className="route-card-copy">主路线、备选路线、起终点 Marker、途经点 Marker、路况开关和 fitBounds 分开验证。</text>
            <text className="route-card-copy">高德网络算路失败时保留 fixture 路线并展示错误，不把直线连点伪装成道路结果。</text>
          </view>
        </view>
      </scroll-view>
    </SafeAreaView>
  )
}

export function App() {
  return <ThemeProvider><RouteContent /></ThemeProvider>
}
