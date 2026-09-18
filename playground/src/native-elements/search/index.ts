export interface SearchCoordinate {
  latitude: number
  longitude: number
}

export interface SearchPOI {
  id: string
  name: string
  type: string
  typecode: string
  address: string
  tel: string
  distance: number
  city: string
  district: string
  coordinate?: SearchCoordinate
}

export interface SearchPath {
  distance: number
  duration: number
  tolls: number
  totalTrafficLights: number
  polyline: SearchCoordinate[]
  steps: Array<{
    instruction: string
    road: string
    distance: number
    duration: number
    polyline: SearchCoordinate[]
  }>
}

export interface SearchRouteResult {
  count: number
  paths: SearchPath[]
}

export interface SearchTransitLine {
  id?: string
  name?: string
  type?: string
  distance: number
  duration: number
  totalPrice: number
  departureStop?: string
  arrivalStop?: string
  polyline: SearchCoordinate[]
}

export interface SearchTransitSegment {
  walking?: { distance: number; duration: number; polyline: SearchCoordinate[] }
  lines: SearchTransitLine[]
  enterName?: string
  exitName?: string
}

export interface SearchTransit {
  cost: number
  duration: number
  distance: number
  walkingDistance: number
  nightflag: boolean
  segments: SearchTransitSegment[]
}

export interface SearchTransitResult {
  count: number
  distance: number
  transits: SearchTransit[]
}

export interface SearchGeocodeResult {
  count: number
  geocodes: Array<{
    formattedAddress: string
    province: string
    city: string
    district: string
    adcode: string
    level: string
    coordinate?: SearchCoordinate
  }>
}

export interface SearchReverseGeocodeResult {
  reGeocode: {
    formattedAddress?: string
    province?: string
    city?: string
    district?: string
    township?: string
    street?: string
    number?: string
    adcode?: string
    nearestPOI?: { id: string; name: string; coordinate: SearchCoordinate }
  }
}

type NativeResponse<T> = { code: number; message?: string; data?: T }

function module() {
  return NativeModules.LynxMapSearchModule
}

function call<T>(method: string, options: Record<string, unknown> = {}): Promise<T> {
  return new Promise((resolve, reject) => {
    const target = module() as Record<string, unknown>
    const invoke = target[method] as (
      optionsJSON: string,
      callback: (result: NativeResponse<T>) => void,
    ) => void
    invoke(JSON.stringify(options), (result) => {
      if (result.code === 0 && result.data !== undefined) {
        resolve(result.data)
        return
      }
      reject(new Error(result.message || `高德搜索调用失败：${result.code}`))
    })
  })
}

export function searchPOI(options: {
  keyword: string
  city?: string
  location?: SearchCoordinate
  types?: string
  cityLimit?: boolean
  page?: number
  offset?: number
}): Promise<{ count: number; pois: SearchPOI[] }> {
  return call('searchPOI', options)
}

export function reverseGeocode(options: {
  coordinate: SearchCoordinate
  radius?: number
  requireExtension?: boolean
}): Promise<SearchReverseGeocodeResult> {
  return call('reverseGeocode', options)
}

export function geocode(options: { address: string; city?: string }): Promise<SearchGeocodeResult> {
  return call('geocode', options)
}

export function searchRoute(options: {
  mode: 'driving' | 'walking' | 'riding'
  origin: SearchCoordinate
  destination: SearchCoordinate
  waypoints?: SearchCoordinate[]
  strategy?: number
}): Promise<SearchRouteResult> {
  return call('searchRoute', options)
}

export function searchTransit(options: {
  origin: SearchCoordinate
  destination: SearchCoordinate
  city: string
  destinationCity?: string
  strategy?: number
  date?: string
  time?: string
  maxTrans?: number
  alternativeRoute?: number
}): Promise<SearchTransitResult> {
  return call('searchTransit', options)
}

export function cancelSearch(): Promise<{ status?: string }> {
  return new Promise((resolve, reject) => {
    module().cancelSearch((result: NativeResponse<{ status?: string }>) => {
      if (result.code === 0) resolve(result.data || {})
      else reject(new Error(result.message || `取消搜索失败：${result.code}`))
    })
  })
}
