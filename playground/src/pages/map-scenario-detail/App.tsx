import { useMemo, useState } from '@lynx-js/react'
import { MapTopBar } from '../../components/MapTopBar/index.js'
import { SafeAreaView } from '../../components/SafeAreaView.js'
import { navigate } from '../../lib/navigation.js'
import { ThemeProvider, useTheme } from '../../lib/theme.js'
import { LynxMap } from '../../native-elements/map/index.js'
import './App.css'

type ScenarioStatus = 'ready' | 'api' | 'service' | 'native'

const statusLabel: Record<ScenarioStatus, string> = {
  ready: '当前可测',
  api: '补 API',
  service: 'Map Service',
  native: '原生页面',
}

const statusDescription: Record<ScenarioStatus, string> = {
  ready: '这个场景已经有对应的 Lynx / Native Element 验收页面。',
  api: '这个场景需要先补 typed API 和 provider adapter，当前页面只展示边界检查。',
  service: '这个场景需要独立服务、网络和权限协议，不能由地图 Element 直接假装完成。',
  native: '这个场景需要长期持有 SDK 状态的原生页面，当前清单页不会返回假成功。',
}

const defaultScenario = {
  title: '地图场景详情',
  summary: '请选择一个地图场景开始验收。',
  api: 'scenario.detail',
  status: 'api' as ScenarioStatus,
}

function queryItems(): Record<string, string> {
  const globalProps = (lynx.__globalProps || {}) as unknown as Record<string, unknown>
  const value = globalProps.queryItems
  if (!value || typeof value !== 'object') return {}
  return value as Record<string, string>
}

function ScenarioDetailContent() {
  const { resolved } = useTheme()
  const query = useMemo(queryItems, [])
  const scenario = {
    title: query.scenarioTitle || defaultScenario.title,
    summary: query.scenarioSummary || defaultScenario.summary,
    api: query.scenarioApi || defaultScenario.api,
    status: (query.scenarioStatus in statusLabel ? query.scenarioStatus : defaultScenario.status) as ScenarioStatus,
  }
  const [result, setResult] = useState('等待执行场景检查')
  const dark = resolved === 'dark'

  const runCheck = () => {
    'background only'
    if (scenario.status === 'ready') {
      setResult('场景已接通：请进入对应 Native Element Demo 执行具体 API 操作。')
      return
    }
    setResult(`${statusLabel[scenario.status]}：当前只完成边界声明，未向高德 SDK 发送未接通调用。`)
  }

  const openRelatedDemo = () => {
    'background only'
    const target = scenario.title.includes('海量点')
      ? 'map-performance.lynx.bundle'
      : scenario.title.includes('定位')
        ? 'map-location.lynx.bundle'
        : 'map-diagnostic.lynx.bundle'
    navigate({
      path: target,
      options: { routeKey: `map-related-${scenario.title}` },
    }, () => {})
  }

  return (
    <SafeAreaView className="scenario-detail-shell" edges={['top', 'bottom']} style={{ height: '100vh' }}>
      <MapTopBar title={scenario.title} subtitle="地图场景详情" dark={dark} />
      <scroll-view className="scenario-detail-scroll" scroll-orientation="vertical">
        <view className={`scenario-detail-page ${dark ? 'scenario-detail-page--dark' : 'scenario-detail-page--light'}`}>
          <text className="scenario-detail-title">{scenario.title}</text>
          <text className="scenario-detail-description">{scenario.summary}</text>

          <view className="scenario-detail-map-stage">
            <LynxMap
              id="ios-amap-scenario-detail"
              className="scenario-detail-map"
              center={{ latitude: 39.9042, longitude: 116.4074 }}
              zoom={12}
              markers={[{ id: 'scenario-detail-center', coordinate: { latitude: 39.9042, longitude: 116.4074 }, title: scenario.title }]}
              onReady={() => setResult('地图预览 ready')}
              onError={(error) => setResult(`${error.code}：${error.message}`)}
            />
            <view className="scenario-detail-overlay"><text className="scenario-detail-overlay-text">Lynx overlay / Native MapView</text></view>
          </view>

          <view className={`scenario-detail-status scenario-detail-status--${scenario.status}`}>
            <text className="scenario-detail-status-label">{statusLabel[scenario.status]}</text>
            <text className="scenario-detail-status-copy">{statusDescription[scenario.status]}</text>
          </view>

          <view className="scenario-detail-card">
            <text className="scenario-detail-card-title">API 边界</text>
            <text className="scenario-detail-card-copy">{scenario.api}</text>
            <text className="scenario-detail-card-copy">{result}</text>
          </view>

          <view className="scenario-detail-actions">
            <view className="scenario-detail-action" bindtap={runCheck} accessibility-label="执行场景检查" accessibility-traits="button">
              <text className="scenario-detail-action-text">执行场景检查</text>
            </view>
            <view className="scenario-detail-action scenario-detail-action--secondary" bindtap={openRelatedDemo} accessibility-label="打开关联 Demo" accessibility-traits="button">
              <text className="scenario-detail-action-text">打开关联 Demo</text>
            </view>
          </view>

          <view className="scenario-detail-card scenario-detail-card--notes">
            <text className="scenario-detail-card-title">验收说明</text>
            <text className="scenario-detail-card-copy">页面入口、滚动和返回链路已经接通；未接通的高德能力只显示结构化边界，不返回假成功。</text>
            <text className="scenario-detail-card-copy">需要 POI、路线、截图、坐标转换或海量点真实结果时，应在对应 service/native/API lane 中继续实现。</text>
          </view>
        </view>
      </scroll-view>
    </SafeAreaView>
  )
}

export function App() {
  return (
    <ThemeProvider>
      <ScenarioDetailContent />
    </ThemeProvider>
  )
}
