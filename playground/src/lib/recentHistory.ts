/**
 * 最近访问记录直接使用 NativeModules.LynxShellModule 的存储方法。
 *
 * Stores up to MAX_ITEMS recently opened URLs as a JSON array.
 * Deduplicates on add (moves existing entry to front).
 */
import { getItem, setItem } from './storage.js'

const STORAGE_KEY = 'sparkling_recent_urls'
const MAX_ITEMS = 20

let memoryCache: string[] | null = null

export function getRecentUrls(callback: (urls: string[]) => void): void {
  if (memoryCache !== null) {
    callback(memoryCache)
    return
  }
  getItem({ key: STORAGE_KEY }, (res) => {
    if (res?.code === 1 && res?.data?.data) {
      try {
        const parsed = JSON.parse(String(res.data.data))
        memoryCache = Array.isArray(parsed) ? parsed : []
      } catch {
        memoryCache = []
      }
    } else {
      memoryCache = []
    }
    callback(memoryCache)
  })
}

export function addRecentUrl(url: string, callback?: (urls: string[]) => void): void {
  const trimmed = url.trim()
  if (!trimmed) return

  const doAdd = (current: string[]) => {
    const filtered = current.filter((u) => u !== trimmed)
    const updated = [trimmed, ...filtered].slice(0, MAX_ITEMS)
    memoryCache = updated
    setItem({ key: STORAGE_KEY, data: JSON.stringify(updated) }, () => {})
    callback?.(updated)
  }

  if (memoryCache !== null) {
    doAdd(memoryCache)
  } else {
    getRecentUrls((urls) => doAdd(urls))
  }
}

export function clearRecentUrls(callback?: () => void): void {
  memoryCache = []
  setItem({ key: STORAGE_KEY, data: JSON.stringify([]) }, () => {
    callback?.()
  })
}
