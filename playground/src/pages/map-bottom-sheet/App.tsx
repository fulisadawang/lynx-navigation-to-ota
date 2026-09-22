import { runOnMainThread, useEffect, useMemo, useMainThreadRef, useRef, useState } from '@lynx-js/react'
import type { MainThread } from '@lynx-js/types'

import { MapTopBar } from '../../components/MapTopBar/index.js'
import { getSafeAreaInsetsFromGlobalProps } from '../../utils/safeAreaInsets.js'
import { ThemeProvider, useTheme } from '../../lib/theme.js'
import { LynxMap, type LynxMapRef } from '../../native-elements/map/index.js'
import './App.css'

type SheetSnap = 'peek' | 'half' | 'full'
const SHEET_SNAP_ANIMATION_MS = 240

interface SnapPoint {
  key: SheetSnap
  label: string
  height: number
}

interface SheetTouchEvent {
  touches?: Array<{ pageY?: number }>
}

const routePoints = [
  { latitude: 39.9042, longitude: 116.4074 },
  { latitude: 39.9104, longitude: 116.3981 },
  { latitude: 39.918, longitude: 116.404 },
  { latitude: 39.928, longitude: 116.419 },
  { latitude: 39.9388, longitude: 116.4333 },
]

const routeCenter = { latitude: 39.9215, longitude: 116.4157 }

const origin = routePoints[0]
const destination = routePoints[routePoints.length - 1]

function readViewportMetrics() {
  const globalProps = (lynx.__globalProps || {}) as unknown as Record<string, unknown>
  const insets = getSafeAreaInsetsFromGlobalProps(globalProps)
  const viewportHeight = Number(globalProps.viewportHeight) || 852
  const expandedHeight = Math.max(420, Math.min(700, viewportHeight - insets.top - 48))
  const halfHeight = Math.max(260, Math.min(380, expandedHeight - 100))
  return { insets, viewportHeight, expandedHeight, halfHeight }
}

function offsetForHeight(expandedHeight: number, height: number) {
  return Math.max(0, expandedHeight - height)
}

function sheetHeightForSnap(snap: SheetSnap, points: SnapPoint[]) {
  return points.find((point) => point.key === snap)?.height ?? points[1].height
}

function snapForOffset(offset: number, points: SnapPoint[], expandedHeight: number): SnapPoint {
  const currentHeight = expandedHeight - offset
  return points.reduce((closest, point) => (
    Math.abs(point.height - currentHeight) < Math.abs(closest.height - currentHeight) ? point : closest
  ), points[0])
}

function BottomSheetMapContent() {
  const { resolved } = useTheme()
  const metrics = useMemo(readViewportMetrics, [])
  const snapPoints = useMemo<SnapPoint[]>(() => [
    { key: 'peek', label: '收起', height: 132 },
    { key: 'half', label: '半屏', height: metrics.halfHeight },
    { key: 'full', label: '展开', height: metrics.expandedHeight },
  ], [metrics.expandedHeight, metrics.halfHeight])
  const [snap, setSnap] = useState<SheetSnap>('peek')
  const [mapReady, setMapReady] = useState(false)
  const [status, setStatus] = useState('地图初始化中…')
  const [dragStartY, setDragStartY] = useState<number | null>(null)
  const mapRef = useRef<LynxMapRef>(null)
  const surfaceRef = useMainThreadRef<MainThread.Element>(null)
  const dragStartYRef = useRef<number | null>(null)
  const dragStartOffsetRef = useRef(0)
  const dragOffsetRef = useRef(0)
  const snapTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const snapGenerationRef = useRef(0)
  const dark = resolved === 'dark'
  const selectedHeight = sheetHeightForSnap(snap, snapPoints)
  const selectedOffset = offsetForHeight(metrics.expandedHeight, selectedHeight)
  const touchBlockTopRatio = Math.max(0, Math.min(1, 1 - selectedHeight / metrics.viewportHeight))
  const sheetMarkers = useMemo(() => [
    { id: 'bottom-sheet-origin', coordinate: origin, title: '上车点', selected: true },
    { id: 'bottom-sheet-destination', coordinate: destination, title: '目的地' },
  ], [])
  const sheetPolylines = useMemo(() => [
    { id: 'bottom-sheet-route', points: routePoints, color: '#087cf9', width: 8, zIndex: 2 },
  ], [])

  useEffect(() => {
    dragStartOffsetRef.current = selectedOffset
    dragOffsetRef.current = selectedOffset
  }, [selectedOffset])

  useEffect(() => () => {
    if (snapTimerRef.current !== null) clearTimeout(snapTimerRef.current)
    snapTimerRef.current = null
    snapGenerationRef.current += 1
  }, [])

  const applyMapViewport = (height: number, source: string) => {
    'background only'
    if (!mapReady || !mapRef.current) return
    // 不在每个 Sheet 档位重新 fitBounds：AMap 的 setVisibleMapRect 会触发缩放、
    // 瓦片重排和 camera 动画。固定 zoom，只移动中心点，保持地图纹理稳定。
    const cameraShift = Math.max(0, height - 132) * 0.000014
    const center = {
      latitude: routeCenter.latitude - cameraShift,
      longitude: routeCenter.longitude,
    }
    mapRef.current.moveCamera({ center, zoom: 11.8, animated: false }).then(() => {
      setStatus(`${source}：地图 camera 已上移 ${Math.round(cameraShift * 100000)} 个单位，Sheet 高度 ${Math.round(height)}px`)
    }).catch(() => {
      setStatus(`${source}：地图 camera 调用失败`)
    })
  }

  const commitSnap = (next: SnapPoint) => {
    'background only'
    setSnap(next.key)
    setDragStartY(null)
    setStatus(`${next.label}：Sheet 高度 ${Math.round(next.height)}px，正在适配地图可视区域…`)
    applyMapViewport(next.height, next.label)
  }

  const commitSnapAfterAnimation = (next: SnapPoint) => {
    'background only'
    if (snapTimerRef.current !== null) clearTimeout(snapTimerRef.current)
    const generation = ++snapGenerationRef.current
    // 先让 main-thread transform 完成吸附，再触发 React 重渲染和高德 camera 动画，
    // 避免同一帧同时提交大面积 Lynx surface 与 MapView 的 fitBounds。
    snapTimerRef.current = setTimeout(() => {
      if (generation !== snapGenerationRef.current) return
      snapTimerRef.current = null
      commitSnap(next)
    }, SHEET_SNAP_ANIMATION_MS)
  }

  const handleMapReady = () => {
    'background only'
    setMapReady(true)
    setStatus('地图 ready，正在按 Sheet 高度适配路线')
    applyMapViewport(selectedHeight, '初始化')
  }

  const selectSnap = (next: SnapPoint) => {
    'background only'
    if (snapTimerRef.current !== null) clearTimeout(snapTimerRef.current)
    snapGenerationRef.current += 1
    void runOnMainThread(animateSheetToMainThread)(offsetForHeight(metrics.expandedHeight, next.height))
    commitSnapAfterAnimation(next)
  }

  function setSheetTransformOnMainThread(offset: number) {
    'main thread'
    const surface = surfaceRef.current
    if (!surface) return
    surface.setStyleProperty('transition', 'none')
    surface.setStyleProperty('transform', `translateY(${offset}px)`)
  }

  function animateSheetToMainThread(offset: number) {
    'main thread'
    const surface = surfaceRef.current
    if (!surface) return
    surface.setStyleProperty(
      'transition',
      `transform ${SHEET_SNAP_ANIMATION_MS}ms cubic-bezier(0.22, 0.61, 0.36, 1)`,
    )
    surface.setStyleProperty('transform', `translateY(${offset}px)`)
  }

  function handleTouchStart(event: SheetTouchEvent) {
    const pageY = event.touches?.[0]?.pageY
    if (pageY === undefined) return
    if (snapTimerRef.current !== null) clearTimeout(snapTimerRef.current)
    snapGenerationRef.current += 1
    const startOffset = dragOffsetRef.current
    dragStartYRef.current = pageY
    dragStartOffsetRef.current = startOffset
    dragOffsetRef.current = startOffset
    setDragStartY(pageY)
    void runOnMainThread(setSheetTransformOnMainThread)(startOffset)
  }

  function handleTouchMove(event: SheetTouchEvent) {
    const pageY = event.touches?.[0]?.pageY
    const dragStartYValue = dragStartYRef.current
    if (dragStartYValue === null || dragStartYValue === undefined || pageY === undefined) return
    const maxOffset = metrics.expandedHeight - 132
    const offset = Math.max(0, Math.min(maxOffset, dragStartOffsetRef.current + pageY - dragStartYValue))
    dragOffsetRef.current = offset
    void runOnMainThread(setSheetTransformOnMainThread)(offset)
  }

  function handleTouchEnd() {
    if (dragStartYRef.current === null) return
    const next = snapForOffset(dragOffsetRef.current, snapPoints, metrics.expandedHeight)
    dragStartYRef.current = null
    void runOnMainThread(animateSheetToMainThread)(offsetForHeight(metrics.expandedHeight, next.height))
    commitSnapAfterAnimation(next)
  }

  return (
    <view className={`map-sheet-page ${dark ? 'map-sheet-page--dark' : 'map-sheet-page--light'}`}>
      <LynxMap
        ref={mapRef}
        id="ios-amap-bottom-sheet"
        className="map-sheet-map"
        center={origin}
        zoom={12}
        markers={sheetMarkers}
        polylines={sheetPolylines}
        // Sheet 拖拽期间把地图从触摸链路中摘出，避免同一指针同时改变 Sheet 和 camera。
        zoomEnabled={dragStartY === null}
        scrollEnabled={dragStartY === null}
        rotateEnabled={dragStartY === null}
        rotateCameraEnabled={dragStartY === null}
        touchBlockTopRatio={touchBlockTopRatio}
        showsCompass
        showsScale
        showsLabels
        onReady={handleMapReady}
        onError={(error) => setStatus(`${error.code}：${error.message}`)}
      />

      <view className="map-sheet-topbar" style={{ paddingTop: `${metrics.insets.top}px` }}>
        <MapTopBar title="滴滴式地图 BottomSheet" subtitle="Sheet 高度改变 · 地图视野同步适配" dark={false} />
      </view>
      <view className="map-sheet-map-badge" style={{ top: `${metrics.insets.top + 66}px` }}>
        <text className="map-sheet-map-badge-text">路线总览 · 原生 MapView + Lynx Sheet</text>
      </view>

      <view
        className="map-sheet-surface"
        style={{
          height: `${metrics.expandedHeight}px`,
          transform: `translateY(${selectedOffset}px)`,
          transition: dragStartY === null ? `transform ${SHEET_SNAP_ANIMATION_MS}ms cubic-bezier(0.22, 0.61, 0.36, 1)` : 'none',
        }}
        main-thread:ref={surfaceRef}
      >
        <view className="map-sheet-panel">
          <view
            className="map-sheet-drag-zone"
            bindtouchstart={handleTouchStart}
            bindtouchmove={handleTouchMove}
            bindtouchend={handleTouchEnd}
            bindtouchcancel={handleTouchEnd}
            accessibility-label="拖动底部面板调整地图可视区域"
            accessibility-traits="adjustable"
          >
            <view className="map-sheet-handle" />
            <text className="map-sheet-drag-hint">向上展开路线详情，向下收起面板</text>
          </view>

          <view className="map-sheet-summary">
            <view className="map-sheet-summary-copy">
              <text className="map-sheet-kicker">正在前往</text>
              <text className="map-sheet-title">东直门 · 北京站</text>
              <text className="map-sheet-subtitle">预计 18 分钟 · 6.2 公里 · 路况畅通</text>
            </view>
            <view className="map-sheet-eta"><text className="map-sheet-eta-text">18′</text></view>
          </view>

          <view className="map-sheet-snap-row">
            {snapPoints.map((point) => (
              <view
                key={point.key}
                className={`map-sheet-snap ${snap === point.key ? 'map-sheet-snap--active' : ''}`}
                bindtap={() => selectSnap(point)}
                accessibility-label={`${point.label} Sheet ${Math.round(point.height)} 像素`}
                accessibility-traits="button"
              >
                <text className="map-sheet-snap-text">{point.label}</text>
              </view>
            ))}
          </view>

          <scroll-view className="map-sheet-scroll" scroll-orientation="vertical">
            <view className="map-sheet-scroll-content" style={{ paddingBottom: `${metrics.insets.bottom + 22}px` }}>
              <view className="map-sheet-viewport-card">
                <text className="map-sheet-card-title">地图可视区域</text>
                <text className="map-sheet-card-value">当前目标可视高度 {Math.round(metrics.viewportHeight - selectedHeight - metrics.insets.bottom)}px</text>
                <text className="map-sheet-card-copy">Sheet 只改变 Lynx transform；吸附完成后在后台无动画移动 camera center，避免高德 camera 和瓦片动画追帧。</text>
              </view>
              <view className="map-sheet-order-card">
                <view className="map-sheet-order-row"><text className="map-sheet-order-label">上车点</text><text className="map-sheet-order-value">北京市东城区台基厂头条</text></view>
                <view className="map-sheet-order-line" />
                <view className="map-sheet-order-row"><text className="map-sheet-order-label">目的地</text><text className="map-sheet-order-value">北京站东街</text></view>
              </view>
              <view className="map-sheet-note-card">
                <text className="map-sheet-card-title">验收要点</text>
                <text className="map-sheet-card-copy">1. 拖动顶部手柄，Sheet 在三档高度之间吸附。</text>
                <text className="map-sheet-card-copy">2. 地图仍是全屏原生 View，Lynx 内容位于其上方。</text>
                <text className="map-sheet-card-copy">3. 地图 camera center 随 Sheet 高度上移，避免路线被面板遮住。</text>
                <text className="map-sheet-card-status">{status}</text>
              </view>
            </view>
          </scroll-view>
        </view>
      </view>
    </view>
  )
}

export function App() {
  return (
    <ThemeProvider>
      <BottomSheetMapContent />
    </ThemeProvider>
  )
}
