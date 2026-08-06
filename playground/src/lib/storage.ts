import { shellModule, type NativeResult } from './nativeModules.js'

export interface StorageRequest {
  key: string
  data?: unknown
  biz?: string
  validDuration?: number
}

export interface StorageResponse extends NativeResult<{ data?: unknown }> {}

function scopedKey(key: string, biz?: string): string {
  const namespace = biz?.trim()
  return namespace ? `${namespace}.${key.trim()}` : key.trim()
}

export function setItem(
  params: StorageRequest,
  callback: (result: StorageResponse) => void,
): void {
  if (!params?.key?.trim() || params.data === undefined) {
    callback({ code: -1, msg: 'key 和 data 不能为空' })
    return
  }

  try {
    const value = typeof params.data === 'string'
      ? params.data
      : JSON.stringify(params.data)
    shellModule().setStorageItem(scopedKey(params.key, params.biz), value)
    callback({ code: 1, msg: 'ok' })
  } catch (error) {
    callback({ code: 0, msg: String(error) })
  }
}

export function getItem(
  params: Pick<StorageRequest, 'key' | 'biz'>,
  callback: (result: StorageResponse) => void,
): void {
  if (!params?.key?.trim()) {
    callback({ code: -1, msg: 'key 不能为空' })
    return
  }

  shellModule().getStorageItem(
    scopedKey(params.key, params.biz),
    (value: string) => callback({
      code: 1,
      msg: 'ok',
      data: { data: value || undefined },
    }),
  )
}

export function removeItem(key: string): void {
  shellModule().removeStorageItem(key)
}

export function clearStorage(): void {
  shellModule().clearStorage()
}
