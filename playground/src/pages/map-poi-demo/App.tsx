import { useMemo, useState } from '@lynx-js/react'
import { MapTopBar } from '../../components/MapTopBar/index.js'
import { SafeAreaView } from '../../components/SafeAreaView.js'
import { ThemeProvider, useTheme } from '../../lib/theme.js'
import { geocode, reverseGeocode, searchPOI, type SearchPOI } from '../../native-elements/search/index.js'
import { LynxMap } from '../../native-elements/map/index.js'
import './App.css'

const defaultCoordinate = { latitude: 39.9042, longitude: 116.4074 }

function PoiContent() {
  const { resolved } = useTheme()
  const [keyword, setKeyword] = useState('咖啡')
  const [pois, setPois] = useState<SearchPOI[]>([])
  const [status, setStatus] = useState('输入关键词后执行高德 POI 搜索')
  const dark = resolved === 'dark'
  const markers = useMemo(() => pois.filter((poi) => poi.coordinate).slice(0, 25).map((poi) => ({ id: poi.id || poi.name, coordinate: poi.coordinate!, title: poi.name })), [pois])

  const runPOI = () => {
    'background only'
    setStatus(`搜索 POI：${keyword}…`)
    searchPOI({ keyword, city: '北京', location: defaultCoordinate, cityLimit: true, page: 1, offset: 20 })
      .then((result) => { setPois(result.pois); setStatus(`POI 返回 ${result.count} 条，当前渲染 ${result.pois.length} 个 Marker`) })
      .catch((error) => setStatus(error.message))
  }

  const runReverseGeocode = () => {
    'background only'
    setStatus('请求逆地理编码…')
    reverseGeocode({ coordinate: defaultCoordinate, radius: 1000, requireExtension: true })
      .then((result) => setStatus(`逆地理：${result.reGeocode.formattedAddress || '返回成功'}`))
      .catch((error) => setStatus(error.message))
  }

  const runGeocode = () => {
    'background only'
    setStatus('请求地理编码…')
    geocode({ address: '北京市天安门', city: '北京' })
      .then((result) => setStatus(`地理编码返回 ${result.count} 条`))
      .catch((error) => setStatus(error.message))
  }

  return (
    <SafeAreaView className="poi-shell" edges={['top', 'bottom']} style={{ height: '100vh' }}>
      <MapTopBar title="POI 与地理编码" subtitle="关键词 / 逆地理 / 地理编码" dark={dark} />
      <scroll-view className="poi-scroll" scroll-orientation="vertical">
        <view className={`poi-page ${dark ? 'poi-page--dark' : 'poi-page--light'}`}>
          <text className="poi-title">搜索与地理编码</text>
          <text className="poi-description">这个页面使用 AMapSearchKit 9.8.1，结果会转换成 Lynx 可消费的 JSON，并将 POI 坐标回填到 Marker；网络失败时显示原生错误。</text>
          <view className="poi-search-row">
            <input className="poi-input" value={keyword} bindinput={(event: { detail: { value: string } }) => setKeyword(event.detail.value)} placeholder="输入 POI 关键词" />
            <view className="poi-action" bindtap={runPOI} accessibility-label="搜索 POI" accessibility-traits="button"><text className="poi-action-text">搜索 POI</text></view>
          </view>
          <view className="poi-map-stage">
            <LynxMap
              id="ios-amap-poi-demo"
              className="poi-map"
              center={defaultCoordinate}
              zoom={12}
              markers={markers}
              showsLabels
              onReady={() => setStatus('地图 ready，等待搜索')}
              onError={(error) => setStatus(`${error.code}：${error.message}`)}
            />
            <view className="poi-map-overlay"><text className="poi-map-overlay-text">POI markers：{markers.length}</text></view>
          </view>
          <view className="poi-actions">
            <view className="poi-action" bindtap={runReverseGeocode} accessibility-label="执行逆地理编码" accessibility-traits="button"><text className="poi-action-text">逆地理编码</text></view>
            <view className="poi-action poi-action--secondary" bindtap={runGeocode} accessibility-label="执行地理编码" accessibility-traits="button"><text className="poi-action-text">地理编码</text></view>
          </view>
          <view className="poi-card"><text className="poi-card-title">请求状态</text><text className="poi-card-status">{status}</text></view>
          <view className="poi-results">
            <text className="poi-card-title">POI 结果（{pois.length}）</text>
            {pois.slice(0, 10).map((poi) => <view key={poi.id || poi.name} className="poi-result-row"><text className="poi-result-name">{poi.name}</text><text className="poi-result-copy">{poi.address || poi.district || '无地址'} · {poi.distance || 0}m</text></view>)}
            {pois.length === 0 ? <text className="poi-result-copy">搜索成功后在这里展示名称、地址、距离和坐标。</text> : null}
          </view>
          <view className="poi-card poi-card--notes"><text className="poi-card-title">API 边界</text><text className="poi-card-copy">POI、地理编码和逆地理编码属于 Search Service；页面不会把 AMapPOI 或 response 对象直接交给 Lynx。</text><text className="poi-card-copy">Key、隐私状态和网络请求仍由 iOS 宿主控制。</text></view>
        </view>
      </scroll-view>
    </SafeAreaView>
  )
}

export function App() {
  return <ThemeProvider><PoiContent /></ThemeProvider>
}
