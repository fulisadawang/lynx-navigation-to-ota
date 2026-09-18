import { useEffect, useMemo, useRef, useState } from '@lynx-js/react'
import { MapTopBar } from '../../components/MapTopBar/index.js'
import { SafeAreaView } from '../../components/SafeAreaView.js'
import { ThemeProvider, useTheme } from '../../lib/theme.js'
import { LynxMap, type LynxMapRef } from '../../native-elements/map/index.js'
import { normalizeMarkers } from '../../native-elements/map/contract.js'
import './App.css'

type UpdateMode = 'initial' | 'noop' | 'full_replace' | 'full_move' | 'incremental' | 'burst'

const markerCounts = [20, 50, 100, 200]
const rejectCounts = [201, 500, 1000, 5000]

function makeMarkers(count: number, idVersion: number, positionVersion: number, changedCount: number) {
  const columns = Math.max(1, Math.ceil(Math.sqrt(count)))
  const baseLatitude = 39.86
  const baseLongitude = 116.32
  return new Array(count).fill(null).map((_, index) => {
    const row = Math.floor(index / columns)
    const column = index % columns
    const moved = index < changedCount
    return {
      id: `perf-${idVersion}-${String(index).padStart(4, '0')}`,
      coordinate: {
        latitude: baseLatitude + row * 0.0012 + (moved ? (positionVersion % 7) * 0.00025 : 0),
        longitude: baseLongitude + column * 0.0012 + (moved ? (positionVersion % 7) * 0.00025 : 0),
      },
      visible: true,
      opacity: 1,
      zIndex: index,
    }
  })
}

function PerformanceContent() {
  const { resolved } = useTheme()
  const [markerCount, setMarkerCount] = useState(20)
  const [idVersion, setIdVersion] = useState(0)
  const [positionVersion, setPositionVersion] = useState(0)
  const [changedCount, setChangedCount] = useState(0)
  const [updateMode, setUpdateMode] = useState<UpdateMode>('initial')
  const [measurement, setMeasurement] = useState('等待运行一轮可重复 fixture')
  const [mapReady, setMapReady] = useState(false)
  const [errorCount, setErrorCount] = useState(0)
  const [guardResult, setGuardResult] = useState('未运行越界 guard')
  const [nativeSnapshot, setNativeSnapshot] = useState('native snapshot：未读取')
  const mapRef = useRef<LynxMapRef>(null)
  const burstTimers = useRef<Array<ReturnType<typeof setTimeout>>>([])
  const dark = resolved === 'dark'

  useEffect(() => () => {
    burstTimers.current.forEach((timer) => clearTimeout(timer))
    burstTimers.current = []
  }, [])

  const markers = useMemo(
    () => makeMarkers(markerCount, idVersion, positionVersion, changedCount),
    [markerCount, idVersion, positionVersion, changedCount],
  )

  const clearBurst = () => {
    burstTimers.current.forEach((timer) => clearTimeout(timer))
    burstTimers.current = []
  }

  const chooseCount = (count: number) => {
    clearBurst()
    setMarkerCount(count)
    setIdVersion(0)
    setPositionVersion(0)
    setChangedCount(0)
    setUpdateMode('initial')
    setMeasurement(`已选择 ${count} 个 marker；点击“首次批量创建”开始采样`)
  }

  const testRejectedCount = (count: number) => {
    try {
      // 只在 Lynx 合约层验证越界，不把越界数组传给原生 adapter。
      normalizeMarkers(makeMarkers(count, 0, 0, 0))
      setGuardResult(`${count}：未拒绝（guard 回归失败）`)
      setErrorCount((current) => current + 1)
    } catch (error) {
      const message = error instanceof Error ? error.message : 'markers 数量非法'
      setGuardResult(`${count}：已拒绝 · ${message}`)
    }
  }

  const runUpdate = (mode: UpdateMode) => {
    clearBurst()
    const startedAt = Date.now()
    setUpdateMode(mode)
    setMeasurement(`${mode}：已提交，等待 Lynx layout 稳定（native apply/FPS 需要 Instruments）`)

    if (mode === 'full_replace') {
      setChangedCount(markerCount)
      setIdVersion((current) => current + 1)
      setPositionVersion((current) => current + 1)
    } else if (mode === 'full_move') {
      setChangedCount(markerCount)
      setPositionVersion((current) => current + 1)
    } else if (mode === 'incremental') {
      setChangedCount(Math.max(1, Math.ceil(markerCount * 0.01)))
      setPositionVersion((current) => current + 1)
    } else if (mode === 'burst') {
      for (let index = 1; index <= 10; index += 1) {
        const timer = setTimeout(() => {
          setChangedCount(Math.max(1, Math.ceil(markerCount * 0.01)))
          setPositionVersion((current) => current + 1)
        }, index * 50)
        burstTimers.current.push(timer)
      }
    } else if (mode === 'initial') {
      setChangedCount(markerCount)
      setPositionVersion((current) => current + 1)
    } else if (mode === 'noop') {
      setChangedCount(0)
    }

    const timer = setTimeout(() => {
      setMeasurement(`${mode}：JS 提交窗口 ${Date.now() - startedAt}ms；N=${markerCount}，K=${mode === 'incremental' ? Math.max(1, Math.ceil(markerCount * 0.01)) : markerCount}`)
    }, mode === 'burst' ? 800 : 450)
    burstTimers.current.push(timer)
  }

  const readNativeSnapshot = () => {
    'background only'
    mapRef.current?.getPerformanceSnapshot()
      .then((snapshot) => setNativeSnapshot(`native apply=${snapshot.applyCount} · ${snapshot.lastApplyDurationMs.toFixed(2)}ms · marker=${snapshot.markerCount} · mass=${snapshot.massPointCount} · pending=${String(snapshot.pendingRender)}`))
      .catch((error) => setNativeSnapshot(`native snapshot 读取失败：${error.message}`))
  }

  return (
    <SafeAreaView className="performance-shell" edges={['top', 'bottom']} style={{ height: '100vh' }}>
      <MapTopBar title="Marker 性能与大场景" subtitle="可重复 fixture / 200 点上限" dark={dark} />
      <scroll-view className="performance-scroll" scroll-orientation="vertical">
        <view className={`performance-page ${dark ? 'performance-page--dark' : 'performance-page--light'}`}>
        <text className="performance-title">Marker 性能与大场景</text>
        <text className="performance-description">普通 marker 的合法上限是 200。页面用固定 seed 生成密集网格，分别测试首次创建、全量替换、全量移动、局部变化和 burst 合并。</text>

        <view className="performance-section">
          <text className="performance-section-title">数量档位</text>
          <view className="performance-row">
            {markerCounts.map((count) => (
              <view key={count} className={`performance-chip ${markerCount === count ? 'performance-chip--active' : ''}`} bindtap={() => chooseCount(count)} accessibility-label={`${count} 个 marker`} accessibility-traits="button">
                <text className="performance-chip-text">{count} 点</text>
              </view>
            ))}
          </view>
          <view className="performance-row performance-row--reject">
            {rejectCounts.map((count) => <view key={count} className="performance-reject" bindtap={() => testRejectedCount(count)} accessibility-label={`测试 ${count} marker 拒绝`} accessibility-traits="button"><text className="performance-reject-text">{count}：测试拒绝</text></view>)}
          </view>
          <text className="performance-guard-result">{guardResult}</text>
        </view>

        <view className="performance-map-stage">
          <LynxMap
            ref={mapRef}
            id="ios-amap-performance"
            className="performance-map"
            center={{ latitude: 39.92, longitude: 116.38 }}
            zoom={11}
            markers={markers}
            onReady={() => setMapReady(true)}
            onError={() => setErrorCount((count) => count + 1)}
          />
          <view className="performance-map-overlay"><text className="performance-map-overlay-text">N={markerCount} · {mapReady ? 'ready' : 'loading'}</text></view>
        </view>

        <view className="performance-section">
          <text className="performance-section-title">更新路径</text>
          <view className="performance-actions">
            <view className="performance-action" bindtap={() => runUpdate('initial')} accessibility-label="首次批量创建" accessibility-traits="button"><text className="performance-action-text">首次批量创建</text></view>
            <view className="performance-action" bindtap={() => runUpdate('noop')} accessibility-label="No-op 更新" accessibility-traits="button"><text className="performance-action-text">No-op</text></view>
            <view className="performance-action" bindtap={() => runUpdate('full_replace')} accessibility-label="全量替换" accessibility-traits="button"><text className="performance-action-text">全量替换</text></view>
            <view className="performance-action" bindtap={() => runUpdate('full_move')} accessibility-label="全量移动" accessibility-traits="button"><text className="performance-action-text">全量移动</text></view>
            <view className="performance-action" bindtap={() => runUpdate('incremental')} accessibility-label="局部百分之一" accessibility-traits="button"><text className="performance-action-text">局部 1%</text></view>
            <view className="performance-action" bindtap={() => runUpdate('burst')} accessibility-label="十次 burst" accessibility-traits="button"><text className="performance-action-text">10 次 burst</text></view>
          </view>
        </view>

        <view className="performance-metrics">
          <text className="performance-section-title">本轮结果</text>
          <text className="performance-metric">mode={updateMode} · N={markerCount} · error={errorCount}</text>
          <text className="performance-metric">{measurement}</text>
          <view className="performance-action" bindtap={readNativeSnapshot} accessibility-label="读取原生性能快照" accessibility-traits="button"><text className="performance-action-text">读取 native snapshot</text></view>
          <text className="performance-metric">{nativeSnapshot}</text>
          <text className="performance-metric">native apply：NOT_MEASURED · FPS/hitch：NOT_MEASURED</text>
          <text className="performance-metric">绝对 FPS、GPU、RSS 和 app-owned leaks 使用 CADisplayLink / Instruments / memgraph 分层采样。</text>
        </view>

        <view className="performance-section performance-section--notes">
          <text className="performance-section-title">验收口径</text>
          <text className="performance-note">20 / 50 / 100 / 200：当前普通 marker 合法性能档位。</text>
          <text className="performance-note">201 / 500 / 1000 / 5000：只验证 fail-closed，不绕过上限压测。</text>
          <text className="performance-note">需要海量点时单独接入 MAMultiPointOverlay，不与普通 annotation 混测。</text>
        </view>
        </view>
      </scroll-view>
    </SafeAreaView>
  )
}

export function App() {
  return (
    <ThemeProvider>
      <PerformanceContent />
    </ThemeProvider>
  )
}
