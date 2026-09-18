import { useMemo, useState } from '@lynx-js/react'
import { MapTopBar } from '../../components/MapTopBar/index.js'
import { SafeAreaView } from '../../components/SafeAreaView.js'
import { LynxMap } from '../../native-elements/map/index.js'
import { ThemeProvider, useTheme } from '../../lib/theme.js'
import './App.css'

const counts = [500, 1000, 5000]

function makeMassPoints(count: number) {
  const columns = Math.max(1, Math.ceil(Math.sqrt(count)))
  return new Array(count).fill(null).map((_, index) => {
    const row = Math.floor(index / columns)
    const column = index % columns
    return {
      id: `mass-${index}`,
      coordinate: {
        latitude: 39.84 + row * 0.00055,
        longitude: 116.28 + column * 0.00065,
      },
      title: `海量点 ${index}`,
      subtitle: 'MAMultiPointOverlay',
    }
  })
}

function MassPointsContent() {
  const { resolved } = useTheme()
  const dark = resolved === 'dark'
  const [count, setCount] = useState(500)
  const [status, setStatus] = useState('等待地图 ready')
  const massPoints = useMemo(() => makeMassPoints(count), [count])

  return (
    <SafeAreaView className="mass-points-shell" edges={['top', 'bottom']} style={{ height: '100vh' }}>
      <MapTopBar title="海量点性能实验" subtitle="MAMultiPointOverlay / 5000 点" dark={dark} />
      <scroll-view className="mass-points-scroll" scroll-orientation="vertical">
        <view className={`mass-points-page ${dark ? 'mass-points-page--dark' : ''}`}>
          <text className="mass-points-title">海量点 / Mass Points</text>
          <text className="mass-points-description">使用高德 MAMultiPointOverlay 渲染海量点，和普通 Marker 分开计量。点数据指纹不变时复用 overlay，变化时整体替换，避免逐点 annotation 和无界对象累积。</text>
          <view className="mass-points-count-row">
            {counts.map((next) => (
              <view key={next} className={`mass-points-chip ${count === next ? 'mass-points-chip--active' : ''}`} bindtap={() => { setCount(next); setStatus(`已切换 ${next} 点，等待 native apply`) }} accessibility-label={`${next} 个海量点`} accessibility-traits="button">
                <text className="mass-points-chip-text">{next} 点</text>
              </view>
            ))}
          </view>
          <view className="mass-points-map-stage">
            <LynxMap
              id="ios-amap-mass-points-demo"
              className="mass-points-map"
              center={{ latitude: 39.92, longitude: 116.38 }}
              zoom={11}
              massPoints={massPoints}
              onReady={() => setStatus(`地图 ready · ${count} 点已提交`)}
              onMassPointTap={(detail) => setStatus(`点击海量点：${detail.id}`)}
              onError={(error) => setStatus(`${error.code}：${error.message}`)}
            />
            <view className="mass-points-map-overlay"><text className="mass-points-map-overlay-text">MAMultiPointOverlay · N={count}</text></view>
          </view>
          <view className="mass-points-card">
            <text className="mass-points-card-title">当前状态</text>
            <text className="mass-points-card-copy">{status}</text>
            <text className="mass-points-card-copy">普通 Marker 上限：200 · 海量点上限：5000</text>
          </view>
          <view className="mass-points-card mass-points-card--note">
            <text className="mass-points-card-title">性能验收</text>
            <text className="mass-points-card-copy">重点观察初次创建、5000 → 500 → 5000 替换、页面退出重进和后台恢复。</text>
            <text className="mass-points-card-copy">Animation Hitches、Allocations、Leaks 和 memgraph 结果需要在真机 Instruments 采样后填写，不把 JS 提交耗时当作 FPS。</text>
          </view>
        </view>
      </scroll-view>
    </SafeAreaView>
  )
}

export function App() {
  return <ThemeProvider><MassPointsContent /></ThemeProvider>
}
