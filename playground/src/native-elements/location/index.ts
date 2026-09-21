import 'background-only'

export interface LynxLocationOptions {
  withReGeocode?: boolean
  desiredAccuracy?: number
  distanceFilter?: number
  locationTimeout?: number
  reGeocodeTimeout?: number
}

export interface LynxLocationReGeocode {
  formattedAddress?: string
}

export interface LynxLocation {
  latitude: number
  longitude: number
  accuracy?: number
  altitude?: number
  speed?: number
  course?: number
  timestamp: number
  reGeocode?: LynxLocationReGeocode
}

export interface LynxLocationAuthorization {
  status: 'notDetermined' | 'restricted' | 'denied' | 'authorizedAlways' | 'authorizedWhenInUse' | string
  accuracy: 'full' | 'reduced' | 'unknown' | string
  servicesEnabled: boolean
}

export interface LynxLocationResult<T = unknown> {
  code: number
  message?: string
  data?: T
}

export class LynxLocationError extends Error {
  readonly code: number

  constructor(code: number, message: string) {
    super(message)
    this.name = 'LynxLocationError'
    this.code = code
  }
}

function locationModule() {
  if (typeof NativeModules === 'undefined' || !NativeModules.LynxMapLocationModule) {
    throw new LynxLocationError(1206, 'LynxMapLocationModule 不可用')
  }
  return NativeModules.LynxMapLocationModule
}

function invoke<T>(
  call: (callback: (result: LynxLocationResult<T>) => void) => void,
): Promise<T> {
  return new Promise((resolve, reject) => {
    call((result) => {
      if (!result || result.code !== 0) {
        reject(new LynxLocationError(result?.code ?? 1206, result?.message || '定位调用失败'))
        return
      }
      resolve((result.data ?? {}) as T)
    })
  })
}

function unwrapEvent(payload: unknown): Record<string, unknown> | undefined {
  let value = payload
  while (Array.isArray(value) && value.length > 0) value = value[0]
  if (!value || typeof value !== 'object' || Array.isArray(value)) return undefined
  return value as Record<string, unknown>
}

function normalizeLocation(payload: unknown): LynxLocation | undefined {
  const value = unwrapEvent(payload)
  if (!value || !Number.isFinite(Number(value.latitude)) || !Number.isFinite(Number(value.longitude))) {
    return undefined
  }
  return {
    latitude: Number(value.latitude),
    longitude: Number(value.longitude),
    accuracy: Number.isFinite(Number(value.accuracy)) ? Number(value.accuracy) : undefined,
    altitude: Number.isFinite(Number(value.altitude)) ? Number(value.altitude) : undefined,
    speed: Number.isFinite(Number(value.speed)) ? Number(value.speed) : undefined,
    course: Number.isFinite(Number(value.course)) ? Number(value.course) : undefined,
    timestamp: Number(value.timestamp) || 0,
    reGeocode: value.reGeocode && typeof value.reGeocode === 'object'
      ? { formattedAddress: String((value.reGeocode as Record<string, unknown>).formattedAddress || '') }
      : undefined,
  }
}

export function getCurrentLocation(options: LynxLocationOptions = {}): Promise<LynxLocation> {
  return invoke<LynxLocation>((callback) => {
    locationModule().getCurrentLocation(JSON.stringify(options), callback)
  })
}

export function startLocation(options: LynxLocationOptions = {}): Promise<{ status: string }> {
  return invoke<{ status: string }>((callback) => {
    locationModule().startLocation(JSON.stringify(options), callback)
  })
}

export function stopLocation(): Promise<{ status: string }> {
  return invoke<{ status: string }>((callback) => {
    locationModule().stopLocation(callback)
  })
}

export function getAuthorizationStatus(): Promise<LynxLocationAuthorization> {
  return invoke<LynxLocationAuthorization>((callback) => {
    locationModule().getAuthorizationStatus(callback)
  })
}

export function onLocation(listener: (location: LynxLocation) => void): () => void {
  const emitter = lynx.getJSModule('GlobalEventEmitter')
  const nativeListener = (payload: unknown) => {
    const location = normalizeLocation(payload)
    if (location) listener(location)
  }
  emitter.addListener('lynxMapLocation', nativeListener)
  return () => emitter.removeListener('lynxMapLocation', nativeListener)
}

export function onLocationError(listener: (error: { code: string; message: string; providerCode?: number }) => void): () => void {
  const emitter = lynx.getJSModule('GlobalEventEmitter')
  const nativeListener = (payload: unknown) => {
    const value = unwrapEvent(payload)
    if (!value) return
    listener({
      code: String(value.code || 'LOCATION_PROVIDER_ERROR'),
      message: String(value.message || '连续定位失败'),
      providerCode: Number.isFinite(Number(value.providerCode)) ? Number(value.providerCode) : undefined,
    })
  }
  emitter.addListener('lynxMapLocationError', nativeListener)
  return () => emitter.removeListener('lynxMapLocationError', nativeListener)
}

export function onLocationAuthorization(listener: (value: Pick<LynxLocationAuthorization, 'status' | 'accuracy'>) => void): () => void {
  const emitter = lynx.getJSModule('GlobalEventEmitter')
  const nativeListener = (payload: unknown) => {
    const value = unwrapEvent(payload)
    if (!value) return
    listener({
      status: String(value.status || 'unknown'),
      accuracy: String(value.accuracy || 'unknown'),
    })
  }
  emitter.addListener('lynxMapLocationAuthorization', nativeListener)
  return () => emitter.removeListener('lynxMapLocationAuthorization', nativeListener)
}
