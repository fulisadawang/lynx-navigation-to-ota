import { useMemo, useRef, useState } from '@lynx-js/react'
import { MapTopBar } from '../../components/MapTopBar/index.js'
import { SafeAreaView } from '../../components/SafeAreaView.js'
import { ThemeProvider, useTheme } from '../../lib/theme.js'
import { LynxMap, type LynxMapRef } from '../../native-elements/map/index.js'
import './App.css'

const markerSeed = Array.from({ length: 12 }, (_, index) => ({
  id: `marker-lab-${String(index).padStart(2, '0')}`,
  coordinate: { latitude: 39.89 + (index % 4) * 0.014, longitude: 116.34 + Math.floor(index / 4) * 0.018 },
  title: index % 3 === 0 ? '门店' : index % 3 === 1 ? '车辆' : '候选点',
  draggable: index < 4,
  view: index === 0 ? {
    text: '店',
    width: 44,
    height: 44,
    backgroundColor: '#ff6a3d',
    foregroundColor: '#ffffff',
    borderColor: '#ffffff',
    borderWidth: 2,
    cornerRadius: 22,
  } : undefined,
  icon: index === 1 ? {
    uri: 'https://webapi.amap.com/theme/v1.3/markers/n/mark_b.png',
    width: 40,
    height: 40,
    anchor: { x: .5, y: 1 },
    cornerRadius: 20,
  } : undefined,
}))

const clusterSeed = Array.from({ length: 80 }, (_, index) => ({
  id: `cluster-marker-${String(index).padStart(2, '0')}`,
  coordinate: {
    latitude: 39.89 + (index % 10) * 0.0022,
    longitude: 116.34 + Math.floor(index / 10) * 0.0028,
  },
  title: '聚合候选点',
}))

function MarkerContent() {
  const { resolved } = useTheme()
  const mapRef = useRef<LynxMapRef>(null)
  const [selectedID, setSelectedID] = useState(markerSeed[0].id)
  const [visible, setVisible] = useState(true)
  const [clusterEnabled, setClusterEnabled] = useState(false)
  const [events, setEvents] = useState<string[]>([])
  const dark = resolved === 'dark'
  const markers = useMemo(() => {
    const source = clusterEnabled ? clusterSeed : markerSeed
    return source.map((marker) => ({ ...marker, selected: marker.id === selectedID, visible }))
  }, [clusterEnabled, selectedID, visible])
  const append = (value: string) => setEvents((current) => [value, ...current].slice(0, 6))

  const selectNext = () => {
    'background only'
    if (clusterEnabled) {
      append('selectMarker：聚合模式请点击 cluster Marker')
      return
    }
    const next = markerSeed[(markerSeed.findIndex((marker) => marker.id === selectedID) + 1) % markerSeed.length]
    mapRef.current?.selectMarker(next.id).then(() => setSelectedID(next.id)).then(() => append(`selectMarker：${next.id}`)).catch(() => append('selectMarker：失败'))
  }

  const fitAll = () => {
    'background only'
    if (clusterEnabled) {
      append('showMarkers：聚合模式由网格自动适配')
      return
    }
    mapRef.current?.showMarkers(markers.map((marker) => marker.id), 28).then(() => append(`showMarkers：${markers.length} 个点已适配`)).catch(() => append('showMarkers：失败'))
  }

  return (
    <SafeAreaView className="marker-shell" edges={['top', 'bottom']} style={{ height: '100vh' }}>
      <MapTopBar title="Marker 交互实验室" subtitle="选中 / 点击 / 拖拽 / 显隐" dark={dark} />
      <scroll-view className="marker-scroll" scroll-orientation="vertical">
        <view className={`marker-page ${dark ? 'marker-page--dark' : 'marker-page--light'}`}>
          <text className="marker-title">门店 / 车辆 Marker</text>
          <text className="marker-description">独立验证 Marker 的 selected、draggable、tap、drag、显隐、自定义 View、网络图片和 Lynx 网格聚合。聚合结果仍回到受控 Marker 事件，不把聚合对象传给原生。</text>
          <view className="marker-map-stage">
            <LynxMap
              ref={mapRef}
              id="ios-amap-marker-demo"
              className="marker-map"
              center={{ latitude: 39.92, longitude: 116.39 }}
              zoom={11}
              markers={markers}
              cluster={clusterEnabled ? { enabled: true, gridSize: 56, minimumClusterSize: 3 } : undefined}
              onReady={() => append('ready：amap')}
              onError={(error) => append(`error：${error.code}`)}
              onMarkerTap={(detail) => { setSelectedID(detail.id); append(`markertap：${detail.id}`) }}
              onMarkerSelected={(detail) => { setSelectedID(detail.id); append(`markerselected：${detail.id}`) }}
              onMarkerDeselected={(detail) => append(`markerdeselected：${detail.id}`)}
              onMarkerDrag={(detail) => append(`markerdrag：${detail.id}:${detail.phase}`)}
            />
            <view className="marker-overlay"><text className="marker-overlay-text">selected: {selectedID} · {visible ? 'visible' : 'hidden'}</text></view>
          </view>
          <view className="marker-actions">
            <view className="marker-action" bindtap={selectNext} accessibility-label="选中下一个 Marker" accessibility-traits="button"><text className="marker-action-text">选中下一个</text></view>
            <view className="marker-action" bindtap={fitAll} accessibility-label="显示全部 Marker" accessibility-traits="button"><text className="marker-action-text">显示全部</text></view>
            <view className="marker-action marker-action--secondary" bindtap={() => setVisible((value) => !value)} accessibility-label="切换 Marker 显隐" accessibility-traits="button"><text className="marker-action-text">覆盖物：{visible ? '显示' : '隐藏'}</text></view>
            <view className="marker-action marker-action--cluster" bindtap={() => { setClusterEnabled((value) => !value); append(`cluster：${clusterEnabled ? '关闭' : '开启'}`) }} accessibility-label="切换 Marker 聚合" accessibility-traits="button"><text className="marker-action-text">聚合：{clusterEnabled ? '开' : '关'}</text></view>
          </view>
          <view className="marker-card">
            <text className="marker-card-title">事件流</text>
            {events.map((event) => <text key={event} className="marker-card-copy">{event}</text>)}
            {events.length === 0 ? <text className="marker-card-copy">点击或拖拽地图上的 Marker 查看事件。</text> : null}
          </view>
          <view className="marker-card marker-card--notes">
            <text className="marker-card-title">性能边界</text>
            <text className="marker-card-copy">普通 Marker 的 20/50/100/200 数量档位在 Marker 性能页单独压测；此页专注交互语义和事件顺序。</text>
            <text className="marker-card-copy">第一个点使用原生 View 样式配置，第二个点使用 HTTPS 图片；图片由 LynxMapKit 缓存、取消和复用。</text>
          </view>
        </view>
      </scroll-view>
    </SafeAreaView>
  )
}

export function App() {
  return <ThemeProvider><MarkerContent /></ThemeProvider>
}
