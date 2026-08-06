/**
 * 当前 Playground 唯一的原生边界。
 *
 * 所有调用都直接进入 Lynx 官方全局对象 NativeModules，不经过
 * sparkling-method、spkPipe、codegen 或 autolink。
 */
export interface NativeResult<T = unknown> {
  code: number
  /** wrapper 归一化前的宿主错误码；直接 Module 返回时通常不存在该字段。 */
  nativeCode?: number
  msg?: string
  message?: string
  data?: T
}

export function shellModule() {
  return NativeModules.LynxShellModule
}

export function normalizeShellResult<T = unknown>(result: NativeResult<T>): NativeResult<T> {
  return {
    ...result,
    nativeCode: result.code,
    // 现有 LynxShellModule 沿用壳协议：0 成功；页面导航 API 沿用 1 成功。
    code: result.code === 0 ? 1 : 0,
    msg: result.msg || result.message || (result.code === 0 ? 'ok' : '原生调用失败'),
  }
}
