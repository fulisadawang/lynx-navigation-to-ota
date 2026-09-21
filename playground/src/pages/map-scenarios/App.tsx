import { useRef, useState } from '@lynx-js/react'
import { MapTopBar } from '../../components/MapTopBar/index.js'
import { SafeAreaView } from '../../components/SafeAreaView.js'
import { navigate } from '../../lib/navigation.js'
import { ThemeProvider, useTheme } from '../../lib/theme.js'
import { LynxMap, type LynxMapRef } from '../../native-elements/map/index.js'
import './App.css'

type ScenarioStatus = 'ready' | 'api' | 'service' | 'native'

interface Scenario {
  title: string
  summary: string
  api: string
  status: ScenarioStatus
}

const scenarios: Scenario[] = [
  { title: '地图浏览与手势', summary: '平移、缩放、旋转和俯视角，验证 MapView 与 Lynx 容器协同。', api: 'gestures · bearing · pitch', status: 'ready' },
  { title: '门店 / 车辆 Marker', summary: '默认 Pin、选中、点击、拖拽、网络图标、结构化 View 和网格聚合。', api: 'markers · marker.icon · marker.view · cluster', status: 'ready' },
  { title: '路线与轨迹', summary: 'Polyline 路径、颜色、宽度、显隐、透明度和同层 zIndex。', api: 'polylines · layer-visible · fitBounds', status: 'ready' },
  { title: '底图与实时路况', summary: 'standard/satellite/night、traffic 和覆盖物聚合层切换。', api: 'map-type · traffic-enabled', status: 'ready' },
  { title: '固定尺寸 / 全屏 / Overlay', summary: '切换固定 320px 与全屏填充，确认 Lynx overlay 始终位于原生地图上方。', api: 'layout · safe-area · overlay', status: 'ready' },
  { title: '滴滴式地图 BottomSheet', summary: '全屏地图铺底，Sheet 在 Peek / Half / Full 三档吸附，并用 fitBounds 适配被遮挡的地图区域。', api: 'bottom-sheet · transform · fitBounds.padding', status: 'ready' },
  { title: 'POI 搜索与逆地理编码', summary: '需要 AMapSearchKit 或服务端 LBS，结果以 JSON 返回给页面。', api: 'poi.search · geocode', status: 'service' },
  { title: '当前位置与连续定位', summary: '通过 AMapLocationKit service 获取当前位置，支持 When In Use 权限、单次和连续定位。', api: 'location.getCurrent · location.start/stop', status: 'ready' },
  { title: '驾车 / 步行 / 骑行算路', summary: '使用独立 Map Service；导航引导、语音和重算交给原生导航页。', api: 'route.plan · navigation', status: 'native' },
  { title: '导航产品场景', summary: '驾车总览、公交/地铁真实方案列表、骑行和步行导航产品界面。', api: 'navigation.product · route.cards · searchTransit', status: 'ready' },
  { title: 'Lynx Marker Overlay', summary: '用 projectCoordinate 把 Lynx 卡片叠到地图坐标上，验证移动和缩放跟随。', api: 'projectCoordinate · lynx.overlay · regionchange', status: 'ready' },
  { title: '自定义图标 / 聚合 / 海量点', summary: '图标 View、Lynx 网格聚合、MAMultiPointOverlay 海量点和 5000 点性能预算。', api: 'marker.icon · marker.view · cluster · mass-points', status: 'ready' },
  { title: '截图与坐标转换', summary: '截图需要受控文件/图片协议；坐标转换适合增加 typed point API。', api: 'snapshot · convertCoordinate', status: 'api' },
  { title: '前后台与销毁重建', summary: '验证 renderringDisabled、generation、delegate 和 MapView 释放。', api: 'pause/resume · teardown · memgraph', status: 'ready' },
]

const statusLabel: Record<ScenarioStatus, string> = {
  ready: '当前可测',
  api: '补 API',
  service: 'Map Service',
  native: '原生页面',
}

const previewMarkers = [
  { id: 'scenario-a', coordinate: { latitude: 39.9042, longitude: 116.4074 }, title: '中心点' },
  { id: 'scenario-b', coordinate: { latitude: 39.913, longitude: 116.363 }, title: '候选点' },
]

const dedicatedPages: Record<string, string> = {
  '地图浏览与手势': 'map-diagnostic.lynx.bundle',
  '门店 / 车辆 Marker': 'map-marker-demo.lynx.bundle',
  '路线与轨迹': 'map-route-demo.lynx.bundle',
  '底图与实时路况': 'map-layer-demo.lynx.bundle',
  '固定尺寸 / 全屏 / Overlay': 'map-layout.lynx.bundle',
  '滴滴式地图 BottomSheet': 'map-bottom-sheet.lynx.bundle',
  '当前位置与连续定位': 'map-location.lynx.bundle',
  'POI 搜索与逆地理编码': 'map-poi-demo.lynx.bundle',
  '驾车 / 步行 / 骑行算路': 'map-route-demo.lynx.bundle',
  '导航产品场景': 'map-navigation-demo.lynx.bundle',
  'Lynx Marker Overlay': 'map-marker-overlay-demo.lynx.bundle',
  '自定义图标 / 聚合 / 海量点': 'map-mass-points-demo.lynx.bundle',
  '前后台与销毁重建': 'map-diagnostic.lynx.bundle',
}

function ScenarioContent() {
  const { resolved } = useTheme()
  const mapRef = useRef<LynxMapRef>(null)
  const [selected, setSelected] = useState('地图浏览与手势')
  const [log, setLog] = useState('等待选择场景')
  const [capabilitySummary, setCapabilitySummary] = useState('未读取 capability snapshot')
  const dark = resolved === 'dark'

  const runScenario = (scenario: Scenario) => {
    'background only'
    setSelected(scenario.title)
    const target = dedicatedPages[scenario.title] || 'map-scenario-detail.lynx.bundle'
    navigate({
      path: target,
      options: {
        routeKey: `map-scenario-${scenario.title}`,
        params: {
          scenarioKey: scenario.title,
          scenarioTitle: scenario.title,
          scenarioStatus: scenario.status,
          scenarioApi: scenario.api,
          scenarioSummary: scenario.summary,
        },
      },
    }, (result) => {
      if (result.code !== 1) {
        setLog(`${scenario.title}：打开页面失败，请检查内置 Bundle`)
      }
    })
  }

  const readCapabilities = () => {
    'background only'
    mapRef.current?.getCapabilities()
      .then((value) => setCapabilitySummary(`contract=${value.contractVersion} · provider=${value.provider} · element API=${value.apiCatalog?.element?.length ?? 0}`))
      .catch(() => setCapabilitySummary('capability snapshot 读取失败'))
  }

  return (
    <SafeAreaView className="scenario-shell" edges={['top', 'bottom']} style={{ height: '100vh' }}>
      <MapTopBar title="地图场景清单" subtitle="常见 App 地图能力" dark={dark} />
      <scroll-view className="scenario-scroll" scroll-orientation="vertical">
        <view className={`scenario-page ${dark ? 'scenario-page--dark' : 'scenario-page--light'}`}>
        <text className="scenario-title">地图 API 场景清单</text>
        <text className="scenario-description">把常见 App 地图场景拆成可运行、补 API、独立服务和原生页面四类，逐项验收。</text>
        <view className="scenario-preview">
          <LynxMap
            ref={mapRef}
            id="ios-amap-scenario-preview"
            className="scenario-map"
            center={{ latitude: 39.9042, longitude: 116.4074 }}
            zoom={12}
            markers={previewMarkers}
            showsLabels
            onReady={() => setLog('preview：ready: amap')}
            onMapTap={() => setLog('preview：maptap 已触发')}
            onLongPress={() => setLog('preview：longpress 已触发')}
          />
          <view className="scenario-overlay"><text className="scenario-overlay-text">Lynx overlay / 原生 MapView</text></view>
        </view>
        <text className="scenario-log">{log}</text>
        <view className="scenario-capability-row">
          <view className="scenario-capability-button" bindtap={readCapabilities} accessibility-label="读取地图能力快照" accessibility-traits="button">
            <text className="scenario-capability-button-text">读取能力快照</text>
          </view>
          <text className="scenario-capability-copy">{capabilitySummary}</text>
        </view>
        <view className="scenario-list">
          {scenarios.map((scenario) => (
            <view
              key={scenario.title}
              className={`scenario-card ${selected === scenario.title ? 'scenario-card--selected' : ''}`}
              bindtap={() => runScenario(scenario)}
              accessibility-label={scenario.title}
              accessibility-traits="button"
            >
              <view className="scenario-card-head">
                <text className="scenario-card-title">{scenario.title}</text>
                <text className={`scenario-status scenario-status--${scenario.status}`}>{statusLabel[scenario.status]}</text>
              </view>
              <text className="scenario-card-summary">{scenario.summary}</text>
              <text className="scenario-card-api">{scenario.api}</text>
            </view>
          ))}
        </view>
        </view>
      </scroll-view>
    </SafeAreaView>
  )
}

export function App() {
  return (
    <ThemeProvider>
      <ScenarioContent />
    </ThemeProvider>
  )
}
