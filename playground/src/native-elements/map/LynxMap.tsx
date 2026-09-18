import {
  forwardRef,
  useImperativeHandle,
  useMemo,
} from '@lynx-js/react'
import {
  normalizeMarkers,
  normalizePolylines,
  normalizeMassPoints,
  normalizeClusterOptions,
  clusterMarkers,
  normalizeLayerOpacity,
  normalizeLayerZIndex,
  normalizePadding,
  normalizeBearing,
  normalizePitch,
  normalizeAnchor,
  normalizeZoom,
  type LynxMapCapabilities,
  type LynxMapCoordinate,
  type LynxMapPerformanceSnapshot,
  type LynxMapCamera,
  type LynxMapErrorDetail,
  type LynxMapMarker,
  type LynxMapMarkerIcon,
  type LynxMapMarkerView,
  type LynxMapNativeElementProps,
  type LynxMapPadding,
  type LynxMapPolyline,
  type LynxMapMassPoint,
  type LynxMapClusterOptions,
  type LynxMapReadyDetail,
  type LynxMapTapDetail,
  type LynxMapMarkerTapDetail,
  type LynxMapMarkerSelectionDetail,
  type LynxMapMarkerDragDetail,
  type LynxMapMassPointTapDetail,
  type LynxMapLongPressDetail,
  type LynxMapRegionChangeDetail,
  type LynxMapType,
  type LynxMapEvent,
} from './contract.js'

export interface LynxMapRef {
  moveCamera(camera: LynxMapCamera & { animated?: boolean }): Promise<unknown>
  getCamera(): Promise<LynxMapCamera>
  getCameraState(): Promise<LynxMapCamera>
  projectCoordinate(coordinate: LynxMapCoordinate): Promise<{ x: number; y: number; visible: boolean }>
  selectMarker(id: string, animated?: boolean): Promise<unknown>
  deselectMarker(id: string, animated?: boolean): Promise<unknown>
  showMarkers(ids: string[], padding?: LynxMapPadding, animated?: boolean): Promise<unknown>
  fitBounds(bounds: {
    bounds: {
      southwest: { latitude: number; longitude: number }
      northeast: { latitude: number; longitude: number }
    }
    padding?: LynxMapPadding
    animated?: boolean
  }): Promise<unknown>
  getCapabilities(): Promise<LynxMapCapabilities>
  getPerformanceSnapshot(): Promise<LynxMapPerformanceSnapshot>
}

export interface LynxMapProps {
  id?: string
  className?: string
  style?: Record<string, string | number>
  center?: LynxMapNativeElementProps['center']
  zoom?: number
  bearing?: number
  pitch?: number
  anchor?: { x: number; y: number }
  markers?: LynxMapMarker[]
  polylines?: LynxMapPolyline[]
  massPoints?: LynxMapMassPoint[]
  cluster?: LynxMapClusterOptions
  layerVisible?: boolean
  layerOpacity?: number
  layerZIndex?: number
  mapType?: LynxMapType
  trafficEnabled?: boolean
  zoomEnabled?: boolean
  scrollEnabled?: boolean
  rotateEnabled?: boolean
  rotateCameraEnabled?: boolean
  showsCompass?: boolean
  showsScale?: boolean
  showsLabels?: boolean
  showsBuildings?: boolean
  touchPOIEnabled?: boolean
  onReady?: (detail: LynxMapReadyDetail) => void
  onError?: (detail: LynxMapErrorDetail) => void
  onMapTap?: (detail: LynxMapTapDetail) => void
  onMarkerTap?: (detail: LynxMapMarkerTapDetail) => void
  onMarkerSelected?: (detail: LynxMapMarkerSelectionDetail) => void
  onMarkerDeselected?: (detail: LynxMapMarkerSelectionDetail) => void
  onMarkerDrag?: (detail: LynxMapMarkerDragDetail) => void
  onMassPointTap?: (detail: LynxMapMassPointTapDetail) => void
  onLongPress?: (detail: LynxMapLongPressDetail) => void
  onRegionChange?: (detail: LynxMapRegionChangeDetail) => void
}

export type { LynxMapMarkerIcon, LynxMapMarkerView }

type NativeMethodResult = {
  code?: number
  data?: unknown
  message?: string
  msg?: string
}

function invokeNativeElement(id: string, method: string, params: Record<string, unknown>): Promise<NativeMethodResult> {
  return new Promise((resolve, reject) => {
    lynx.createSelectorQuery().select(`#${id}`).invoke({
      method,
      params,
      success: resolve,
      fail: reject,
    }).exec()
  })
}

function readData<T>(result: NativeMethodResult): T {
  // Lynx 4.1 的 SelectorQuery invoke 在不同 renderer 路径上可能返回
  // { code, data }，也可能直接返回 UI Method 的 data；两种形状都归一化，
  // 但保留非零 code 的明确失败。
  if (result && typeof result === 'object' && ('code' in result || 'data' in result)) {
    if (result.code !== undefined && result.code !== 0) {
      throw new Error(result.message || result.msg || '地图操作失败')
    }
    return ('data' in result ? result.data : result) as T
  }
  return result as T
}

export const LynxMap = forwardRef<LynxMapRef, LynxMapProps>((props, ref) => {
  const id = useMemo(() => props.id || `lynx-map-${Math.random().toString(36).slice(2)}`, [props.id])
  const zoom = normalizeZoom(props.zoom)
  const cluster = normalizeClusterOptions(props.cluster)
  const markers = useMemo(() => clusterMarkers(normalizeMarkers(props.markers), cluster, zoom), [props.markers, cluster, zoom])
  const polylines = useMemo(() => normalizePolylines(props.polylines), [props.polylines])
  const massPoints = useMemo(() => normalizeMassPoints(props.massPoints), [props.massPoints])
  const bearing = normalizeBearing(props.bearing)
  const pitch = normalizePitch(props.pitch)
  const anchor = normalizeAnchor(props.anchor)
  const layerOpacity = normalizeLayerOpacity(props.layerOpacity)
  const layerZIndex = normalizeLayerZIndex(props.layerZIndex)

  useImperativeHandle(ref, () => ({
    moveCamera: (camera) => invokeNativeElement(id, 'moveCamera', camera as Record<string, unknown>).then(readData),
    getCamera: () => invokeNativeElement(id, 'getCamera', {}).then((result) => readData<LynxMapCamera>(result)),
    getCameraState: () => invokeNativeElement(id, 'getCameraState', {}).then((result) => readData<LynxMapCamera>(result)),
    projectCoordinate: (coordinate) => invokeNativeElement(id, 'projectCoordinate', { coordinate }).then((result) => readData<{ x: number; y: number; visible: boolean }>(result)),
    fitBounds: (bounds) => invokeNativeElement(id, 'fitBounds', {
      ...bounds,
      padding: normalizePadding(bounds.padding),
    } as unknown as Record<string, unknown>).then(readData),
    getCapabilities: () => invokeNativeElement(id, 'getCapabilities', {}).then((result) => readData<LynxMapCapabilities>(result)),
    getPerformanceSnapshot: () => invokeNativeElement(id, 'getPerformanceSnapshot', {}).then((result) => readData<LynxMapPerformanceSnapshot>(result)),
    selectMarker: (markerId, animated = true) => invokeNativeElement(id, 'selectMarker', { id: markerId, animated }).then(readData),
    deselectMarker: (markerId, animated = true) => invokeNativeElement(id, 'deselectMarker', { id: markerId, animated }).then(readData),
    showMarkers: (markerIds, padding, animated = true) => invokeNativeElement(id, 'showMarkers', {
      ids: markerIds,
      padding: normalizePadding(padding),
      animated,
    }).then(readData),
  }), [id])

  return (
    <lynx-map
      flatten={false}
      id={id}
      className={props.className}
      style={props.style}
      center={props.center}
      zoom={zoom}
      bearing={bearing}
      pitch={pitch}
      anchor={anchor}
      markers={markers}
      polylines={polylines}
      mass-points={massPoints}
      layer-visible={props.layerVisible}
      layer-opacity={layerOpacity}
      layer-z-index={layerZIndex}
      map-type={props.mapType}
      traffic-enabled={props.trafficEnabled}
      zoom-enabled={props.zoomEnabled}
      scroll-enabled={props.scrollEnabled}
      rotate-enabled={props.rotateEnabled}
      rotate-camera-enabled={props.rotateCameraEnabled}
      shows-compass={props.showsCompass}
      shows-scale={props.showsScale}
      shows-labels={props.showsLabels}
      shows-buildings={props.showsBuildings}
      touch-poi-enabled={props.touchPOIEnabled}
      bindready={(event: LynxMapEvent<LynxMapReadyDetail>) => props.onReady?.(event.detail)}
      binderror={(event: LynxMapEvent<LynxMapErrorDetail>) => props.onError?.(event.detail)}
      bindmaptap={(event: LynxMapEvent<LynxMapTapDetail>) => props.onMapTap?.(event.detail)}
      bindmarkertap={(event: LynxMapEvent<LynxMapMarkerTapDetail>) => props.onMarkerTap?.(event.detail)}
      bindmarkerselected={(event: LynxMapEvent<LynxMapMarkerSelectionDetail>) => props.onMarkerSelected?.(event.detail)}
      bindmarkerdeselected={(event: LynxMapEvent<LynxMapMarkerSelectionDetail>) => props.onMarkerDeselected?.(event.detail)}
      bindmarkerdrag={(event: LynxMapEvent<LynxMapMarkerDragDetail>) => props.onMarkerDrag?.(event.detail)}
      bindmasspointtap={(event: LynxMapEvent<LynxMapMassPointTapDetail>) => props.onMassPointTap?.(event.detail)}
      bindlongpress={(event: LynxMapEvent<LynxMapLongPressDetail>) => props.onLongPress?.(event.detail)}
      bindregionchange={(event: LynxMapEvent<LynxMapRegionChangeDetail>) => props.onRegionChange?.(event.detail)}
    />
  )
})
