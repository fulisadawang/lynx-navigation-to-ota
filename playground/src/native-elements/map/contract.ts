export interface LynxMapCoordinate {
  latitude: number
  longitude: number
}

export interface LynxMapMarkerIcon {
  /** 目前支持 HTTPS 网络图片；图片二进制由 LynxMapKit 缓存和管理。 */
  uri: string
  width?: number
  height?: number
  anchor?: { x: number; y: number }
  cornerRadius?: number
}

export interface LynxMapMarkerView {
  text?: string
  width?: number
  height?: number
  backgroundColor?: string
  foregroundColor?: string
  borderColor?: string
  borderWidth?: number
  cornerRadius?: number
}

export interface LynxMapMarker {
  id: string
  coordinate: LynxMapCoordinate
  title?: string
  subtitle?: string
  icon?: LynxMapMarkerIcon
  /** 序列化的原生 Marker View 样式，不是可跨线程传递的 UIView/LynxView。 */
  view?: LynxMapMarkerView
  visible?: boolean
  selected?: boolean
  draggable?: boolean
  opacity?: number
  zIndex?: number
}

export interface LynxMapPolyline {
  id: string
  points: LynxMapCoordinate[]
  color?: string
  width?: number
  visible?: boolean
  opacity?: number
  zIndex?: number
}

export interface LynxMapMassPoint {
  id: string
  coordinate: LynxMapCoordinate
  title?: string
  subtitle?: string
}

export interface LynxMapClusterOptions {
  enabled?: boolean
  /** 屏幕网格边长，范围 16..256。 */
  gridSize?: number
  /** 网格内达到该数量才折叠成 cluster marker。 */
  minimumClusterSize?: number
}

export interface LynxMapCamera {
  center?: LynxMapCoordinate
  zoom?: number
  /** 0..360，与高德 rotationDegree 对应。 */
  bearing?: number
  /** 0..60，与高德 cameraDegree 对应。 */
  pitch?: number
  /** 0..1 的屏幕锚点。 */
  anchor?: { x: number; y: number }
}

export type LynxMapPadding =
  | number
  | [number, number, number, number]
  | { top?: number; right?: number; bottom?: number; left?: number }

export type LynxMapType = 'standard' | 'satellite' | 'night' | 'navi' | 'bus' | 'navi-night'
export type LynxMapLayerKind = 'base' | 'traffic' | 'marker' | 'polyline'

export const LYNX_MAP_LIMITS = {
  markers: 200,
  identifierLength: 128,
  markerTextLength: 256,
  colorLength: 16,
  polylines: 50,
  massPoints: 5000,
  polylinePointsPerPath: 512,
  polylinePointsTotal: 5000,
  zoomMin: 0,
  zoomMax: 24,
  polylineWidthMax: 128,
  fitBoundsPaddingMax: 4096,
  zIndexMagnitudeMax: 100000,
} as const

export interface LynxMapCapabilities {
  schemaVersion: number
  contractVersion: number
  available: boolean
  provider: string
  reasonCode?: string
  features?: Record<string, boolean | string[]>
  limits?: Record<string, number>
  apiCatalog?: {
    element?: string[]
    service?: string[]
    nativePage?: string[]
  }
}

export interface LynxMapPerformanceSnapshot {
  schemaVersion: number
  applyCount: number
  lastApplyDurationMs: number
  markerCount: number
  polylineCount: number
  massPointCount: number
  pendingRender: boolean
  providerReady: boolean
  fps: number | null
  frameTimeMs: number | null
  note?: string
}

export interface LynxMapErrorDetail {
  code: string
  message: string
}

export interface LynxMapReadyDetail {
  provider: string
}

export interface LynxMapTapDetail {
  coordinate: LynxMapCoordinate
}

export interface LynxMapMarkerTapDetail {
  id: string
  coordinate: LynxMapCoordinate
}

export interface LynxMapMassPointTapDetail {
  id: string
  coordinate: LynxMapCoordinate
}

export interface LynxMapMarkerSelectionDetail {
  id: string
  coordinate: LynxMapCoordinate
  selected: boolean
}

export interface LynxMapMarkerDragDetail {
  id: string
  coordinate: LynxMapCoordinate
  phase: 'start' | 'dragging' | 'end' | 'cancel'
}

export interface LynxMapLongPressDetail {
  coordinate: LynxMapCoordinate
}

export interface LynxMapRegionChangeDetail {
  center?: LynxMapCoordinate
  zoom?: number
  reason?: string
  source?: 'gesture' | 'api' | string
  phase?: 'begin' | 'end' | string
}

export interface LynxMapEvent<T> {
  detail: T
}

export interface LynxMapNativeElementProps {
  id?: string
  /** 地图必须保留真实原生 View，禁止 Lynx flatten 优化合并或省略节点。 */
  flatten?: boolean
  className?: string
  style?: Record<string, string | number>
  center?: LynxMapCoordinate
  zoom?: number
  bearing?: number
  pitch?: number
  anchor?: { x: number; y: number }
  markers?: LynxMapMarker[]
  polylines?: LynxMapPolyline[]
  'mass-points'?: LynxMapMassPoint[]
  'layer-visible'?: boolean
  'layer-opacity'?: number
  'layer-z-index'?: number
  'map-type'?: LynxMapType
  'traffic-enabled'?: boolean
  'zoom-enabled'?: boolean
  'scroll-enabled'?: boolean
  'rotate-enabled'?: boolean
  'rotate-camera-enabled'?: boolean
  /** BottomSheet 等 Lynx 覆盖层的触摸阻挡顶部比例，0..1；仅用于原生触摸仲裁。 */
  'touch-block-top-ratio'?: number
  'shows-compass'?: boolean
  'shows-scale'?: boolean
  'shows-labels'?: boolean
  'shows-buildings'?: boolean
  'touch-poi-enabled'?: boolean
  bindready?: (event: LynxMapEvent<LynxMapReadyDetail>) => void
  binderror?: (event: LynxMapEvent<LynxMapErrorDetail>) => void
  bindmaptap?: (event: LynxMapEvent<LynxMapTapDetail>) => void
  bindmarkertap?: (event: LynxMapEvent<LynxMapMarkerTapDetail>) => void
  bindmarkerselected?: (event: LynxMapEvent<LynxMapMarkerSelectionDetail>) => void
  bindmarkerdeselected?: (event: LynxMapEvent<LynxMapMarkerSelectionDetail>) => void
  bindmarkerdrag?: (event: LynxMapEvent<LynxMapMarkerDragDetail>) => void
  bindmasspointtap?: (event: LynxMapEvent<LynxMapMassPointTapDetail>) => void
  bindlongpress?: (event: LynxMapEvent<LynxMapLongPressDetail>) => void
  bindregionchange?: (event: LynxMapEvent<LynxMapRegionChangeDetail>) => void
}

declare global {
  namespace JSX {
    interface IntrinsicElements {
      'lynx-map': LynxMapNativeElementProps
    }
  }
}

// `jsxImportSource: @lynx-js/react` 的 jsx-runtime 继承 `@lynx-js/types`，
// 仅扩展 global JSX 不会让 `<lynx-map>` 在 ReactLynx 类型检查中可见。
declare module '@lynx-js/types' {
  interface IntrinsicElements {
    'lynx-map': LynxMapNativeElementProps
  }
}

export function isFiniteCoordinate(value: unknown): value is LynxMapCoordinate {
  if (!value || typeof value !== 'object') return false
  const coordinate = value as Partial<LynxMapCoordinate>
  return Number.isFinite(coordinate.latitude) && Number.isFinite(coordinate.longitude) &&
    coordinate.latitude! >= -90 && coordinate.latitude! <= 90 &&
    coordinate.longitude! >= -180 && coordinate.longitude! <= 180
}

function isFiniteInRange(value: unknown, minimum: number, maximum: number): value is number {
  return typeof value === 'number' && Number.isFinite(value) && value >= minimum && value <= maximum
}

export function normalizeZoom(zoom: number | undefined): number | undefined {
  if (zoom === undefined) return undefined
  if (!isFiniteInRange(zoom, LYNX_MAP_LIMITS.zoomMin, LYNX_MAP_LIMITS.zoomMax)) {
    throw new Error('zoom 必须在 0 到 24 之间')
  }
  return zoom
}

export function normalizeBearing(bearing: number | undefined): number | undefined {
  if (bearing === undefined) return undefined
  if (!isFiniteInRange(bearing, 0, 360) || bearing === 360) {
    throw new Error('bearing 必须在 0 到 360 之间（不含 360）')
  }
  return bearing
}

export function normalizePitch(pitch: number | undefined): number | undefined {
  if (pitch === undefined) return undefined
  if (!isFiniteInRange(pitch, 0, 60)) throw new Error('pitch 必须在 0 到 60 之间')
  return pitch
}

export function normalizeAnchor(anchor: { x: number; y: number } | undefined):
  { x: number; y: number } | undefined {
  if (anchor === undefined) return undefined
  if (!anchor || typeof anchor !== 'object' ||
    !isFiniteInRange(anchor.x, 0, 1) || !isFiniteInRange(anchor.y, 0, 1)) {
    throw new Error('anchor.x 和 anchor.y 必须在 0 到 1 之间')
  }
  return anchor
}

function normalizeOpacity(value: number | undefined, label: string): number | undefined {
  if (value === undefined) return undefined
  if (!isFiniteInRange(value, 0, 1)) throw new Error(`${label} 必须在 0 到 1 之间`)
  return value
}

function normalizeMarkerIcon(value: LynxMapMarkerIcon | undefined, label: string) {
  if (value === undefined) return
  if (!value || typeof value.uri !== 'string' || value.uri.length === 0 || value.uri.length > 2048 || !value.uri.startsWith('https://')) {
    throw new Error(`${label}.uri 必须是 HTTPS URL 且不能超过 2048 个字符`)
  }
  if (value.width !== undefined && (!Number.isFinite(value.width) || value.width < 16 || value.width > 128)) {
    throw new Error(`${label}.width 必须在 16 到 128 之间`)
  }
  if (value.height !== undefined && (!Number.isFinite(value.height) || value.height < 16 || value.height > 128)) {
    throw new Error(`${label}.height 必须在 16 到 128 之间`)
  }
  if (value.cornerRadius !== undefined && (!Number.isFinite(value.cornerRadius) || value.cornerRadius < 0 || value.cornerRadius > 64)) {
    throw new Error(`${label}.cornerRadius 必须在 0 到 64 之间`)
  }
  if (value.anchor !== undefined && (!Number.isFinite(value.anchor.x) || !Number.isFinite(value.anchor.y) || value.anchor.x < 0 || value.anchor.x > 1 || value.anchor.y < 0 || value.anchor.y > 1)) {
    throw new Error(`${label}.anchor.x/y 必须在 0 到 1 之间`)
  }
}

function normalizeMarkerView(value: LynxMapMarkerView | undefined, label: string) {
  if (value === undefined) return
  if (value.text !== undefined && value.text.length > 128) throw new Error(`${label}.text 不能超过 128 个字符`)
  if (value.width !== undefined && (!Number.isFinite(value.width) || value.width < 20 || value.width > 160)) throw new Error(`${label}.width 必须在 20 到 160 之间`)
  if (value.height !== undefined && (!Number.isFinite(value.height) || value.height < 20 || value.height > 160)) throw new Error(`${label}.height 必须在 20 到 160 之间`)
  if (value.borderWidth !== undefined && (!Number.isFinite(value.borderWidth) || value.borderWidth < 0 || value.borderWidth > 8)) throw new Error(`${label}.borderWidth 必须在 0 到 8 之间`)
  if (value.cornerRadius !== undefined && (!Number.isFinite(value.cornerRadius) || value.cornerRadius < 0 || value.cornerRadius > 80)) throw new Error(`${label}.cornerRadius 必须在 0 到 80 之间`)
  for (const color of [value.backgroundColor, value.foregroundColor, value.borderColor]) {
    if (color !== undefined && (typeof color !== 'string' || color.length > 32)) throw new Error(`${label} 颜色字符串无效`)
  }
}

export function normalizeLayerOpacity(value: number | undefined): number | undefined {
  return normalizeOpacity(value, 'layerOpacity')
}

function normalizeZIndex(value: number | undefined, label: string): number | undefined {
  if (value === undefined) return undefined
  if (!Number.isInteger(value) || Math.abs(value) > LYNX_MAP_LIMITS.zIndexMagnitudeMax) {
    throw new Error(`${label} 超出允许范围`)
  }
  return value
}

export function normalizeLayerZIndex(value: number | undefined): number | undefined {
  return normalizeZIndex(value, 'layerZIndex')
}

export function normalizePadding(value: LynxMapPadding | undefined): LynxMapPadding | undefined {
  if (value === undefined) return undefined
  const valid = (padding: number) => isFiniteInRange(padding, 0, LYNX_MAP_LIMITS.fitBoundsPaddingMax)
  if (typeof value === 'number') {
    if (!valid(value)) throw new Error('padding 必须在 0 到 4096 之间')
    return value
  }
  if (Array.isArray(value)) {
    if (value.length !== 4 || value.some((padding) => !valid(padding))) {
      throw new Error('padding 四项必须在 0 到 4096 之间')
    }
    return value
  }
  if (!value || typeof value !== 'object') throw new Error('padding 参数无效')
  for (const padding of [value.top, value.right, value.bottom, value.left]) {
    if (padding !== undefined && !valid(padding)) throw new Error('padding 必须在 0 到 4096 之间')
  }
  return value
}

export function normalizeMarkers(markers: LynxMapMarker[] | undefined): LynxMapMarker[] {
  if (markers === undefined) return []
  if (!Array.isArray(markers)) throw new Error('markers 必须是数组')
  if (markers.length > LYNX_MAP_LIMITS.markers) throw new Error('markers 数量不能超过 200')
  const ids = new Set<string>()
  return markers.map((marker, index) => {
    if (!marker || typeof marker.id !== 'string' || marker.id.length === 0 ||
      marker.id.length > LYNX_MAP_LIMITS.identifierLength || ids.has(marker.id)) {
      throw new Error(`markers[${index}].id 无效或重复`)
    }
    if (!isFiniteCoordinate(marker.coordinate)) throw new Error(`markers[${index}].coordinate 无效`)
    if (marker.selected !== undefined && typeof marker.selected !== 'boolean') {
      throw new Error(`markers[${index}].selected 必须是布尔值`)
    }
    if (marker.draggable !== undefined && typeof marker.draggable !== 'boolean') {
      throw new Error(`markers[${index}].draggable 必须是布尔值`)
    }
    if (marker.title !== undefined && marker.title.length > LYNX_MAP_LIMITS.markerTextLength) {
      throw new Error(`markers[${index}].title 超出长度限制`)
    }
    if (marker.subtitle !== undefined && marker.subtitle.length > LYNX_MAP_LIMITS.markerTextLength) {
      throw new Error(`markers[${index}].subtitle 超出长度限制`)
    }
    normalizeMarkerIcon(marker.icon, `markers[${index}].icon`)
    normalizeMarkerView(marker.view, `markers[${index}].view`)
    normalizeOpacity(marker.opacity, `markers[${index}].opacity`)
    normalizeZIndex(marker.zIndex, `markers[${index}].zIndex`)
    ids.add(marker.id)
    return marker
  })
}

export function normalizePolylines(polylines: LynxMapPolyline[] | undefined): LynxMapPolyline[] {
  if (polylines === undefined) return []
  if (!Array.isArray(polylines)) throw new Error('polylines 必须是数组')
  if (polylines.length > LYNX_MAP_LIMITS.polylines) throw new Error('polylines 数量不能超过 50')
  const ids = new Set<string>()
  let totalPoints = 0
  return polylines.map((polyline, index) => {
    if (!polyline || typeof polyline.id !== 'string' || polyline.id.length === 0 ||
      polyline.id.length > LYNX_MAP_LIMITS.identifierLength || ids.has(polyline.id)) {
      throw new Error(`polylines[${index}].id 无效或重复`)
    }
    if (!Array.isArray(polyline.points) || polyline.points.length < 2 ||
      polyline.points.length > LYNX_MAP_LIMITS.polylinePointsPerPath) {
      throw new Error(`polylines[${index}].points 数量无效`)
    }
    totalPoints += polyline.points.length
    if (totalPoints > LYNX_MAP_LIMITS.polylinePointsTotal) throw new Error('polylines 总点数不能超过 5000')
    if (polyline.width !== undefined &&
      (!isFiniteInRange(polyline.width, Number.MIN_VALUE, LYNX_MAP_LIMITS.polylineWidthMax))) {
      throw new Error(`polylines[${index}].width 超出允许范围`)
    }
    if (polyline.color !== undefined && polyline.color.length > LYNX_MAP_LIMITS.colorLength) {
      throw new Error(`polylines[${index}].color 超出长度限制`)
    }
    normalizeOpacity(polyline.opacity, `polylines[${index}].opacity`)
    normalizeZIndex(polyline.zIndex, `polylines[${index}].zIndex`)
    if (polyline.points.some((point) => !isFiniteCoordinate(point))) {
      throw new Error(`polylines[${index}].points 坐标无效`)
    }
    ids.add(polyline.id)
    return polyline
  })
}

export function normalizeMassPoints(points: LynxMapMassPoint[] | undefined): LynxMapMassPoint[] {
  if (points === undefined) return []
  if (!Array.isArray(points)) throw new Error('massPoints 必须是数组')
  if (points.length > LYNX_MAP_LIMITS.massPoints) throw new Error('massPoints 数量不能超过 5000')
  const ids = new Set<string>()
  return points.map((point, index) => {
    if (!point || typeof point.id !== 'string' || point.id.length === 0 ||
      point.id.length > LYNX_MAP_LIMITS.identifierLength || ids.has(point.id)) {
      throw new Error(`massPoints[${index}].id 无效或重复`)
    }
    if (!isFiniteCoordinate(point.coordinate)) throw new Error(`massPoints[${index}].coordinate 无效`)
    if (point.title !== undefined && point.title.length > LYNX_MAP_LIMITS.markerTextLength) {
      throw new Error(`massPoints[${index}].title 超出长度限制`)
    }
    if (point.subtitle !== undefined && point.subtitle.length > LYNX_MAP_LIMITS.markerTextLength) {
      throw new Error(`massPoints[${index}].subtitle 超出长度限制`)
    }
    ids.add(point.id)
    return point
  })
}

export function normalizeClusterOptions(options: LynxMapClusterOptions | undefined): LynxMapClusterOptions | undefined {
  if (options === undefined) return undefined
  if (!options || typeof options !== 'object') throw new Error('cluster 参数无效')
  if (options.enabled !== undefined && typeof options.enabled !== 'boolean') throw new Error('cluster.enabled 必须是布尔值')
  if (options.gridSize !== undefined && (!Number.isFinite(options.gridSize) || options.gridSize < 16 || options.gridSize > 256)) {
    throw new Error('cluster.gridSize 必须在 16 到 256 之间')
  }
  if (options.minimumClusterSize !== undefined && (!Number.isInteger(options.minimumClusterSize) || options.minimumClusterSize < 2 || options.minimumClusterSize > 50)) {
    throw new Error('cluster.minimumClusterSize 必须在 2 到 50 之间')
  }
  return options
}

/**
 * Lynx 层的确定性网格聚合。聚合结果仍然是普通 Marker，点击 detail.id 以 cluster- 开头；
 * 5000 点海量场景不要走这里，应使用原生 mass-points lane。
 */
export function clusterMarkers(
  markers: LynxMapMarker[],
  options: LynxMapClusterOptions | undefined,
  zoom = 12,
): LynxMapMarker[] {
  if (!options?.enabled || markers.length < 2) return markers
  const gridSize = options.gridSize ?? 48
  const minimumClusterSize = options.minimumClusterSize ?? 3
  const safeZoom = Math.max(0, Math.min(24, zoom))
  const latitudeCell = (360 / (256 * Math.pow(2, safeZoom))) * gridSize
  const buckets = new Map<string, LynxMapMarker[]>()
  for (const marker of markers) {
    const cosine = Math.max(.2, Math.cos(marker.coordinate.latitude * Math.PI / 180))
    const longitudeCell = latitudeCell / cosine
    const row = Math.floor(marker.coordinate.latitude / latitudeCell)
    const column = Math.floor(marker.coordinate.longitude / longitudeCell)
    const key = `${row}:${column}`
    const bucket = buckets.get(key)
    if (bucket) bucket.push(marker)
    else buckets.set(key, [marker])
  }
  const result: LynxMapMarker[] = []
  for (const [key, bucket] of buckets) {
    if (bucket.length < minimumClusterSize) {
      result.push(...bucket)
      continue
    }
    const latitude = bucket.reduce((sum, marker) => sum + marker.coordinate.latitude, 0) / bucket.length
    const longitude = bucket.reduce((sum, marker) => sum + marker.coordinate.longitude, 0) / bucket.length
    result.push({
      id: `cluster-${key.replace(':', '-')}`,
      coordinate: { latitude, longitude },
      title: `${bucket.length} 个点`,
      subtitle: bucket.map((marker) => marker.id).slice(0, 12).join(','),
      view: {
        text: String(bucket.length),
        width: 44,
        height: 44,
        backgroundColor: '#147ef5',
        foregroundColor: '#ffffff',
        borderColor: '#ffffff',
        borderWidth: 2,
        cornerRadius: 22,
      },
      zIndex: 1000,
    })
  }
  return result
}
