import { useMemo, useRef, useState } from '@lynx-js/react'
import { MapTopBar } from '../../components/MapTopBar/index.js'
import { SafeAreaView } from '../../components/SafeAreaView.js'
import { searchRoute, searchTransit, type SearchCoordinate, type SearchPath, type SearchTransit } from '../../native-elements/search/index.js'
import { LynxMap, type LynxMapRef } from '../../native-elements/map/index.js'
import { ThemeProvider, useTheme } from '../../lib/theme.js'
import './App.css'

type NavigationMode = 'driving' | 'transit' | 'riding' | 'walking'
type RouteMode = Exclude<NavigationMode, 'transit'>

const origin: SearchCoordinate = { latitude: 39.9042, longitude: 116.4074 }
const destination: SearchCoordinate = { latitude: 39.9388, longitude: 116.4333 }
const waypoints: SearchCoordinate[] = [
  { latitude: 39.918, longitude: 116.398 },
  { latitude: 39.927, longitude: 116.421 },
]

const routeFixtures: Record<RouteMode, SearchPath[]> = {
  driving: [{ distance: 6200, duration: 1120, tolls: 0, totalTrafficLights: 8, steps: [], polyline: [
    origin, { latitude: 39.912, longitude: 116.391 }, { latitude: 39.924, longitude: 116.409 }, { latitude: 39.933, longitude: 116.425 }, destination,
  ] }],
  riding: [{ distance: 4700, duration: 1420, tolls: 0, totalTrafficLights: 6, steps: [], polyline: [
    origin, { latitude: 39.914, longitude: 116.421 }, { latitude: 39.927, longitude: 116.435 }, { latitude: 39.936, longitude: 116.429 }, destination,
  ] }],
  walking: [{ distance: 3900, duration: 2860, tolls: 0, totalTrafficLights: 5, steps: [], polyline: [
    origin, { latitude: 39.909, longitude: 116.414 }, { latitude: 39.921, longitude: 116.425 }, { latitude: 39.932, longitude: 116.429 }, destination,
  ] }],
}

const routeColors: Record<RouteMode, string> = {
  driving: '#11a768',
  riding: '#147ef5',
  walking: '#147ef5',
}

const modeLabels: Record<NavigationMode, string> = {
  driving: '驾车',
  transit: '公交地铁',
  riding: '骑行',
  walking: '步行',
}

const transitOptions = [
  { duration: '1小时4分', walk: '1.7公里', fare: '6.0元', stops: '15站', boarding: '九龙山上车', color: '#f6bd45', legs: ['步行 21分钟', '地铁 7号线', '步行 4分钟'], tag: '时间短' },
  { duration: '1小时22分', walk: '3.2公里', fare: '5.0元', stops: '12站', boarding: '大望路上车', color: '#d94a3d', legs: ['步行 22分钟', '地铁 1号线 八通线', '步行 25分钟'], tag: '' },
  { duration: '1小时31分', walk: '1.7公里', fare: '6.0元', stops: '19站', boarding: '八王坟东上车', color: '#2d6cf6', legs: ['步行 22分钟', '668路', '步行 2分钟', '通68路 (T68路)', '步行 3分钟'], tag: '' },
  { duration: '1小时41分', walk: '1.7公里', fare: '5.0元', stops: '22站', boarding: '九龙山路口西上车', color: '#2d6cf6', legs: ['步行 20分钟', '669路', '步行 2分钟', '通68路 (T68路)', '步行 3分钟'], tag: '' },
  { duration: '1小时49分', walk: '3.2公里', fare: '6.0元', stops: '22站', boarding: '恒惠路上车', color: '#2d6cf6', legs: ['步行 33分钟', '806路', '步行 14分钟'], tag: '' },
]

function formatDuration(seconds: number) {
  if (seconds < 60) return `${seconds}秒`
  const minutes = Math.round(seconds / 60)
  if (minutes < 60) return `${minutes}分钟`
  return `${Math.floor(minutes / 60)}小时${minutes % 60 ? `${minutes % 60}分` : ''}`
}

function formatDistance(meters: number) {
  return meters >= 10000 ? `${(meters / 1000).toFixed(1)}公里` : `${(meters / 1000).toFixed(1)}公里`
}

function boundsFor(points: SearchCoordinate[]) {
  const latitudes = points.map((point) => point.latitude)
  const longitudes = points.map((point) => point.longitude)
  return {
    southwest: { latitude: Math.min(...latitudes), longitude: Math.min(...longitudes) },
    northeast: { latitude: Math.max(...latitudes), longitude: Math.max(...longitudes) },
  }
}

function RouteModeTabs(props: { mode: NavigationMode; onChange: (mode: NavigationMode) => void; dark: boolean }) {
  return (
    <view className={`navigation-mode-tabs ${props.dark ? 'navigation-mode-tabs--dark' : ''}`}>
      {(['driving', 'transit', 'riding', 'walking'] as NavigationMode[]).map((mode) => (
        <view
          key={mode}
          className={`navigation-mode-tab ${props.mode === mode ? 'navigation-mode-tab--active' : ''}`}
          bindtap={() => props.onChange(mode)}
          accessibility-label={`切换${modeLabels[mode]}导航`}
          accessibility-traits="button"
        >
          <text className="navigation-mode-label">{modeLabels[mode]}</text>
          <text className="navigation-mode-time">{mode === 'driving' ? '33分钟' : mode === 'transit' ? '1小时4分' : mode === 'riding' ? '1小时37分' : '4小时54分'}</text>
        </view>
      ))}
    </view>
  )
}

function RouteInputPanel(props: { mode: NavigationMode; onChange: (mode: NavigationMode) => void; dark: boolean }) {
  return (
    <view className={`navigation-input-panel ${props.dark ? 'navigation-input-panel--dark' : ''}`}>
      <view className="navigation-input-row">
        <text className="navigation-back">‹</text>
        <view className="navigation-input-points">
          <view className="navigation-point-row"><view className="navigation-point-dot navigation-point-dot--start" /><text className="navigation-point-text">我的位置</text></view>
          <view className="navigation-point-line" />
          <view className="navigation-point-row"><view className="navigation-point-dot navigation-point-dot--end" /><text className="navigation-point-text">高楼金第</text></view>
        </view>
        <text className="navigation-swap">⇅</text>
      </view>
      <RouteModeTabs mode={props.mode} onChange={props.onChange} dark={props.dark} />
    </view>
  )
}

function MapControls() {
  return (
    <view className="navigation-map-controls">
      <view className="navigation-map-control"><text className="navigation-map-control-text">⟳</text></view>
      <view className="navigation-map-control"><text className="navigation-map-control-text">◎</text></view>
    </view>
  )
}

function NavigationMap(props: {
  mode: RouteMode
  paths: SearchPath[]
  mapRef: { current: LynxMapRef | null }
  trafficEnabled: boolean
  onStatus: (message: string) => void
}) {
  const markers = [
    { id: 'navigation-origin', coordinate: origin, title: '我的位置', selected: true },
    ...waypoints.map((coordinate, index) => ({ id: `navigation-waypoint-${index}`, coordinate, title: `途经点 ${index + 1}` })),
    { id: 'navigation-destination', coordinate: destination, title: '高楼金第' },
  ]

  return (
    <view className="navigation-map-stage">
      <LynxMap
        ref={props.mapRef}
        id="ios-amap-navigation-product"
        className="navigation-map"
        center={origin}
        zoom={12}
        trafficEnabled={props.trafficEnabled}
        markers={markers}
        polylines={props.paths.map((path, index) => ({ id: `navigation-${props.mode}-${index}`, points: path.polyline, color: index === 0 ? routeColors[props.mode] : '#a5b4fc', width: index === 0 ? 9 : 5, opacity: index === 0 ? 1 : .55, zIndex: index === 0 ? 2 : 1 }))}
        onReady={() => props.onStatus('地图已 ready，当前路线可交互')}
        onError={(error) => props.onStatus(`${error.code}：${error.message}`)}
      />
      <MapControls />
      <view className="navigation-map-filter"><text className="navigation-map-filter-text">综合推荐⌄</text></view>
    </view>
  )
}

function RouteSummary(props: { mode: RouteMode; paths: SearchPath[]; status: string; onRequest: () => void; onFit: () => void }) {
  const first = props.paths[0]
  return (
    <view className="navigation-route-sheet">
      <view className="navigation-route-options">
        {props.paths.slice(0, 3).map((path, index) => (
          <view key={`${props.mode}-${index}`} className={`navigation-route-option ${index === 0 ? 'navigation-route-option--selected' : ''}`}>
            <text className="navigation-route-option-title">{index === 0 ? '推荐方案' : `方案${index + 1}`}</text>
            <text className="navigation-route-option-time">{formatDuration(path.duration)}</text>
            <text className="navigation-route-option-meta">{formatDistance(path.distance)} · 🚦{path.totalTrafficLights}</text>
          </view>
        ))}
      </view>
      <view className="navigation-route-actions">
        <view className="navigation-secondary-action" bindtap={props.onFit} accessibility-label="适配路线范围" accessibility-traits="button"><text className="navigation-secondary-action-text">适配路线</text></view>
        <view className="navigation-primary-action" bindtap={props.onRequest} accessibility-label="请求高德算路" accessibility-traits="button"><text className="navigation-primary-action-text">请求高德算路</text></view>
      </view>
      <text className="navigation-route-status">{props.status}</text>
      <text className="navigation-route-hint">{first ? `当前 ${modeLabels[props.mode]}：${first.polyline.length} 个坐标点，支持起终点、备选方案和 Polyline 回填` : '暂无路线'}</text>
    </view>
  )
}

function transitOptionFromResult(transit: SearchTransit) {
  const legs = transit.segments.flatMap((segment) => {
    const walking = segment.walking ? [`步行 ${formatDuration(segment.walking.duration)}`] : []
    const lines = segment.lines.map((line) => line.name || line.type || '公交线路')
    return [...walking, ...lines]
  })
  return {
    duration: formatDuration(transit.duration),
    walk: formatDistance(transit.walkingDistance),
    fare: `${transit.cost.toFixed(1)}元`,
    stops: `${transit.segments.reduce((count, segment) => count + segment.lines.length, 0)}段`,
    boarding: transit.segments.find((segment) => segment.enterName)?.enterName || '按高德方案上车',
    color: '#f6bd45',
    legs: legs.length > 0 ? legs : ['公交/地铁方案'],
    tag: '',
  }
}

function TransitResults(props: { options: typeof transitOptions; status: string; onRequest: () => void }) {
  return (
    <view className="navigation-transit-page">
      <view className="navigation-transit-filter-row">
        <text className="navigation-transit-filter-active">现在出发⌄</text>
        <text className="navigation-transit-filter-active">综合推荐</text>
        <text className="navigation-transit-filter">时间最短</text>
        <text className="navigation-transit-filter">步行少</text>
        <text className="navigation-transit-filter">换乘少</text>
        <text className="navigation-transit-filter">不坐地铁</text>
      </view>
      {props.options.map((option, index) => (
        <view key={`${option.duration}-${index}`} className="navigation-transit-card">
          <view className="navigation-transit-card-head">
            <text className="navigation-transit-duration">{option.duration}</text>
            <text className="navigation-transit-walk">♟ {option.walk}</text>
            {option.tag && <text className="navigation-transit-tag">{option.tag}</text>}
          </view>
          <view className="navigation-transit-legs">
            {option.legs.map((leg, legIndex) => <view key={`${leg}-${legIndex}`} className="navigation-transit-leg" style={{ backgroundColor: leg.includes('地铁') || leg.includes('路') ? option.color : '#f0f1f3' }}><text className={`navigation-transit-leg-text ${leg.includes('地铁') || leg.includes('路') ? 'navigation-transit-leg-text--colored' : ''}`}>{leg}</text></view>)}
          </view>
          <text className="navigation-transit-meta">{option.stops} · {option.fare} · {option.boarding}</text>
        </view>
      ))}
      <view className="navigation-transit-request" bindtap={props.onRequest} accessibility-label="请求高德公交地铁方案" accessibility-traits="button"><text className="navigation-transit-request-text">请求高德公交 / 地铁方案</text></view>
      <view className="navigation-fixture-note"><text className="navigation-fixture-note-text">{props.status}</text></view>
    </view>
  )
}

function NavigationProductContent() {
  const { resolved } = useTheme()
  const dark = resolved === 'dark'
  const mapRef = useRef<LynxMapRef>(null)
  const [mode, setMode] = useState<NavigationMode>('driving')
  const [remotePaths, setRemotePaths] = useState<Partial<Record<RouteMode, SearchPath[]>>>({})
  const [remoteTransits, setRemoteTransits] = useState<SearchTransit[] | null>(null)
  const [trafficEnabled, setTrafficEnabled] = useState(true)
  const [status, setStatus] = useState('使用 fixture 预览，点击下方按钮请求高德真实路线')
  const routeMode = mode === 'transit' ? null : mode
  const paths = routeMode ? (remotePaths[routeMode] || routeFixtures[routeMode]) : []
  const routePoints = useMemo(() => paths.flatMap((path) => path.polyline), [paths])

  const selectMode = (next: NavigationMode) => {
    'background only'
    setMode(next)
    setStatus(next === 'transit' ? (remoteTransits ? `高德返回 ${remoteTransits.length} 个公交/地铁方案` : '公交/地铁当前显示 fixture，点击按钮请求高德') : `${modeLabels[next]} 已切换；可以请求高德真实算路`)
  }

  const requestTransit = () => {
    'background only'
    setStatus('请求高德公交 / 地铁方案…')
    searchTransit({ origin, destination, city: '北京', destinationCity: '北京', strategy: 0, maxTrans: 4, alternativeRoute: 5 })
      .then((result) => {
        if (result.transits.length === 0) {
          setStatus('高德未返回公交/地铁方案，保留 fixture')
          return
        }
        setRemoteTransits(result.transits)
        setStatus(`高德公交 / 地铁返回 ${result.transits.length} 个方案`)
      })
      .catch((error) => setStatus(`公交 / 地铁：${error.message}`))
  }

  const requestRoute = () => {
    'background only'
    if (!routeMode) {
      setStatus('公交/地铁当前没有接入原生 Transit Search，保留 fixture 方案')
      return
    }
    setStatus(`请求高德 ${routeMode} 路线…`)
    searchRoute({ mode: routeMode, origin, destination, waypoints: routeMode === 'driving' ? waypoints : undefined, strategy: 32 })
      .then((result) => {
        const next = (result.paths || []).filter((path) => Array.isArray(path?.polyline) && path.polyline.length >= 2)
        if (next.length === 0) {
          setStatus(`高德 ${routeMode} 未返回可渲染路线，保留 fixture polyline`)
          return
        }
        setRemotePaths((current) => ({ ...current, [routeMode]: next }))
        setStatus(`高德 ${routeMode} 返回 ${next.length} 条路线，已回填 polyline`)
      })
      .catch((error) => setStatus(`${routeMode}：${error.message}`))
  }

  const fitRoute = () => {
    'background only'
    if (routePoints.length === 0) return
    mapRef.current?.fitBounds({ bounds: boundsFor(routePoints), padding: 48, animated: true })
      .then(() => setStatus('路线已适配视野'))
      .catch(() => setStatus('路线适配失败'))
  }

  return (
    <SafeAreaView className="navigation-shell" edges={['top', 'bottom']} style={{ height: '100vh' }}>
      <MapTopBar title="导航产品场景" subtitle="驾车 / 公交地铁 / 骑行 / 步行" dark={dark} />
      <scroll-view className="navigation-scroll" scroll-orientation="vertical">
        <view className={`navigation-page ${dark ? 'navigation-page--dark' : ''}`}>
          {mode === 'transit' ? (
            <view className="navigation-transit-shell">
              <RouteInputPanel mode={mode} onChange={selectMode} dark={dark} />
              <TransitResults options={(remoteTransits || []).length > 0 ? remoteTransits!.map(transitOptionFromResult) : transitOptions} status={status} onRequest={requestTransit} />
            </view>
          ) : (
            <view className="navigation-route-shell">
              <view className="navigation-map-wrapper">
                <NavigationMap mode={routeMode!} paths={paths} mapRef={mapRef} trafficEnabled={trafficEnabled} onStatus={setStatus} />
                <RouteInputPanel mode={mode} onChange={selectMode} dark={dark} />
              </view>
              <view className="navigation-switch-row">
                <view className={`navigation-switch ${trafficEnabled ? 'navigation-switch--active' : ''}`} bindtap={() => setTrafficEnabled((value) => !value)} accessibility-label="切换实时路况" accessibility-traits="button"><text className="navigation-switch-text">路况：{trafficEnabled ? '开' : '关'}</text></view>
                <text className="navigation-switch-note">{modeLabels[mode]}路线总览</text>
              </view>
              <RouteSummary mode={routeMode!} paths={paths} status={status} onRequest={requestRoute} onFit={fitRoute} />
            </view>
          )}
        </view>
      </scroll-view>
    </SafeAreaView>
  )
}

export function App() {
  return <ThemeProvider><NavigationProductContent /></ThemeProvider>
}
