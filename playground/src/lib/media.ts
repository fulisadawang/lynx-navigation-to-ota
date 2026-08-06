import { shellModule } from './nativeModules.js'

// 每个演示页会按自己的响应数据结构收窄类型；原生边界统一透传 JSON Object。
type Callback = (result: any) => void

function call(
  method: 'chooseMedia' | 'uploadFile' | 'uploadImage' | 'downloadFile' | 'saveDataURL',
  params: Record<string, unknown>,
  callback: Callback,
): void {
  const module = shellModule()
  const payload = JSON.stringify(params || {})
  module[method](payload, callback)
}

export function chooseMedia(params: Record<string, unknown>, callback: Callback): void {
  call('chooseMedia', params, callback)
}

export function uploadFile(params: Record<string, unknown>, callback: Callback): void {
  call('uploadFile', params, callback)
}

export function uploadImage(params: Record<string, unknown>, callback: Callback): void {
  call('uploadImage', params, callback)
}

export function downloadFile(params: Record<string, unknown>, callback: Callback): void {
  call('downloadFile', params, callback)
}

export function saveDataURL(params: Record<string, unknown>, callback: Callback): void {
  call('saveDataURL', params, callback)
}
