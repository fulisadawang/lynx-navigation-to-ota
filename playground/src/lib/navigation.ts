import { normalizeShellResult, shellModule, type NativeResult } from './nativeModules.js'

/** 页面 wrapper 统一后的结果：code=1 成功，code=0 失败。 */
export interface NavigateResponse<T = unknown> {
  code: number
  /** 宿主原始错误码；code 已归一化为 1 成功、0 失败。 */
  nativeCode?: number
  msg?: string
  data?: T
}

/** Android/iOS 一致的页面复用策略。 */
export type LaunchMode = 'push' | 'singleTop' | 'clearTop' | 'singleTask'

/** 原生容器真正执行的转场类型；页面只声明意图，不逐帧驱动。 */
export type TransitionStyle =
  | 'default'
  | 'fade'
  | 'slide'
  | 'slideUp'
  | 'zoom'
  | 'sharedElement'
  | 'openContainer'
  | 'none'

/** 与微信 Skyline preset-route 对齐的公开名称。 */
export type SkylineRouteType =
  | 'wx://bottom-sheet'
  | 'wx://hero-sheet'
  | 'wx://upwards'
  | 'wx://zoom'
  | 'wx://cupertino-modal'
  | 'wx://cupertino-modal-inside'
  | 'wx://modal-navigation'
  | 'wx://modal'

export interface ShellRectStyle {
  backgroundColor?: string
  cornerRadius?: number
  elevation?: number
}

export type SharedElementShuttle = 'from' | 'to'

/** Skyline 公开的矩形插值类型；cubic-bezier 由原生解析并校验。 */
export type SharedElementRectTween =
  | 'materialRectArc'
  | 'materialRectCenterArc'
  | 'linear'
  | 'elasticIn'
  | 'elasticOut'
  | 'elasticInOut'
  | 'bounceIn'
  | 'bounceOut'
  | 'bounceInOut'
  | `cubic-bezier(${string})`

export interface SharedElementSpec {
  /** 两页相同 key 的元素属于同一个飞跃关系；同一页面内必须唯一。 */
  key: string
  /** Lynx 元素 id；可写 hero 或 #hero，最终几何由原生重新测量。 */
  sourceSelector: string
  targetSelector: string
  /** 与 Skyline 一致，底层默认 false；便捷 helper 会默认开启反向跟手。 */
  transitionOnGesture?: boolean
  /** push/pop 分别选择 from 或 to 页快照作为飞跃物，默认均为 to。 */
  shuttleOnPush?: SharedElementShuttle
  shuttleOnPop?: SharedElementShuttle
  /** 默认 materialRectArc。 */
  rectTweenType?: SharedElementRectTween
  sourceStyle?: ShellRectStyle
  targetStyle?: ShellRectStyle
}

export interface OpenContainerSpec {
  /** 关闭态卡片的 Lynx 元素 id；打开态是目标原生页面的可见区域。 */
  sourceSelector: string
  closedColor?: string
  middleColor?: string
  openColor?: string
  closedCornerRadius?: number
  openCornerRadius?: number
  closedElevation?: number
  openElevation?: number
  /** Skyline 正式字段；默认 fade。 */
  transitionType?: 'fade' | 'fadeThrough'
  /** 默认 300ms；页面侧通常不需要设置。 */
  transitionDuration?: number
  /** 旧壳字段，保留兼容；新代码使用 transitionType。 */
  contentTransition?: 'fade' | 'fadeThrough'
}

export interface PopGestureSpec {
  enabled?: boolean
  direction?: 'horizontal' | 'vertical' | 'multi'
  /** 全屏手势必须显式开启；发生滚动冲突时原生会降级为 edge。 */
  fullScreen?: boolean
  edgeWidth?: number
}

export interface NativeTransitionSpec {
  style?: TransitionStyle
  fallbackStyle?: 'fade' | 'slide' | 'none'
  durationMs?: number
  readyTimeoutMs?: number
  /** 旧单元素协议。 */
  sharedElement?: SharedElementSpec
  /** Skyline 多共享元素协议；后声明的元素位于更高 overlay 层。 */
  sharedElements?: SharedElementSpec[]
  openContainer?: OpenContainerSpec
  popGesture?: PopGestureSpec
}

/** Skyline routeConfig 的公开页面转场配置。 */
export interface SkylineRouteConfig {
  opaque?: boolean
  maintainState?: boolean
  transitionDuration?: number
  reverseTransitionDuration?: number
  barrierColor?: string
  barrierDismissible?: boolean
  barrierLabel?: string
  canTransitionTo?: boolean
  canTransitionFrom?: boolean
  allowEnterRouteSnapshotting?: boolean
  allowExitRouteSnapshotting?: boolean
  fullscreenDrag?: boolean
  popGestureDirection?: 'horizontal' | 'vertical' | 'multi'
}

/** Sheet 动态选项；height/detents/initialDetent 单位均为 vh。 */
export interface SkylineRouteOptions {
  round?: boolean
  height?: number
  /** 严格递增的 Sheet 高度档位；最多 4 个。 */
  detents?: number[]
  /** 必须是 detents 中的一个值；省略时 bottomSheet 取最大档，heroSheet 取 56vh 默认档。 */
  initialDetent?: number
}

/** 所有会修改原生栈的命令共用选项。 */
export interface NavigationCommandOptions {
  /** 是否执行平台默认转场动画，默认 true。 */
  animated?: boolean
  /** 是否抑制快速重复调用，默认 true。 */
  deduplicate?: boolean
  /** 重复操作窗口，范围 0..5000ms，默认 350ms。 */
  deduplicateWindowMs?: number
  /** back/popTo 可把该 JSON Object 返回给目标 entry。 */
  result?: Record<string, unknown>
}

/** 打开页面时额外支持 launch mode 和系统返回手势配置。 */
export interface OpenNavigationOptions extends NavigationCommandOptions {
  launchMode?: LaunchMode
  /**
   * iOS 控制侧滑返回；Android 控制系统 Back 按键/手势。
   * 原生导航栏返回和 NativeModules.close 始终保留。
   */
  backGestureEnabled?: boolean
  /** 原生只提供透明全屏承载；页面内容是否移动由 Lynx 自己决定。 */
  transparent?: boolean
  /** Skyline 预设名；双端映射为当前平台可稳定实现的原生转场。 */
  routeType?: SkylineRouteType
  routeConfig?: SkylineRouteConfig
  routeOptions?: SkylineRouteOptions
  transition?: NativeTransitionSpec
  /** prepareRoute 返回的一次性句柄；过期或失效时原生自动回退为普通加载。 */
  preparedRouteToken?: string
}

export interface NavigateRequest {
  path: string
  options?: OpenNavigationOptions & {
    params?: Record<string, unknown>
    /** 跨 Android/iOS 的稳定页面标识；栈定位只匹配当前 Lynx session。 */
    routeKey?: string
  }
}

export interface OpenRequest {
  scheme: string
  options?: OpenNavigationOptions & Record<string, unknown>
}

export interface NavigationEntry {
  entryID: string
  routeKey: string
  index: number
}

export interface NavigationState {
  sessionID: string
  current: NavigationEntry
  stack: NavigationEntry[]
  depth: number
  /** 只表示当前 Lynx session 内是否有上一页，不包含宿主页。 */
  canGoBack: boolean
  hasHostAnchor: boolean
  affectedCount: number
}

export interface NavigationResultPayload {
  hasResult: boolean
  result?: Record<string, unknown>
  sourceEntryID?: string
  sourceRouteKey?: string
  createdAt?: number
  affectedCount: number
}

export type TransitionStatus =
  | 'idle'
  | 'accepted'
  | 'waitingTarget'
  | 'running'
  | 'settling'
  | 'completed'
  | 'cancelled'
  | 'degraded'
  | 'failed'

export interface TransitionState {
  transactionID: string
  status: TransitionStatus
  requestedTransition: TransitionStyle
  effectiveTransition: TransitionStyle
  direction: 'push' | 'pop'
  progress: number
  reason?: string
  routeKey?: string
  updatedAt: number
}

export type RouteTerminalStatus =
  | 'completed'
  | 'cancelled'
  | 'degraded'
  | 'failed'
  | 'unknown'

/** 原生自定义路由终态载荷。 */
export interface RouteDoneEvent {
  transactionID?: string
  direction?: 'push' | 'pop'
  status: RouteTerminalStatus
  routeKey?: string
  reason?: string
}

export interface PreparedRoute {
  token: string
  expiresAt?: number
  sizeBytes?: number
  routeKey?: string
}

/**
 * 业务常用的简洁预设。
 *
 * 完整 NativeTransitionSpec 仍保留给框架层；普通页面优先调用
 * navigateWithPreset / navigateSharedElement / navigateOpenContainer。
 */
export type TransitionPreset =
  | 'fade'
  | 'slide'
  | 'up'
  | 'upwards'
  | 'zoom'
  | 'modal'
  | 'bottomSheet'
  | 'heroSheet'
  | 'cupertinoModal'
  | 'cupertinoModalInside'
  | 'modalNavigation'
  | 'shared'
  | 'container'
  | 'none'

interface PresetRequestBase {
  /** 目标 Bundle；wrapper 会自动组装 hybrid://lynxview_page。 */
  bundle: string
  params?: Record<string, unknown>
  routeKey?: string
  /** 进阶覆盖项；普通业务保持省略即可。 */
  routeConfig?: SkylineRouteConfig
  routeOptions?: SkylineRouteOptions
}

export interface BasicTransitionPresetRequest extends PresetRequestBase {
  preset:
    | 'fade'
    | 'slide'
    | 'up'
    | 'upwards'
    | 'zoom'
    | 'modal'
    | 'bottomSheet'
    | 'heroSheet'
    | 'cupertinoModal'
    | 'cupertinoModalInside'
    | 'modalNavigation'
    | 'none'
}

type SharedElementReference =
  | {
      /** 两页使用 shareElementSelector(key) 时，只传 key 即可自动配对。 */
      key: string
      source?: never
      target?: never
    }
  | {
      /** 兼容已有页面直接提供不同 source/target selector。 */
      key?: string
      source: string
      target: string
    }

export type SharedElementRouteItem = SharedElementReference & {
  transitionOnGesture?: boolean
  shuttleOnPush?: SharedElementShuttle
  shuttleOnPop?: SharedElementShuttle
  rectTweenType?: SharedElementRectTween
  sourceStyle?: ShellRectStyle
  targetStyle?: ShellRectStyle
}

export type SharedTransitionPresetRequest = PresetRequestBase &
  SharedElementRouteItem & {
    preset: 'shared'
  }

export type NavigateSharedElementRequest = PresetRequestBase & SharedElementRouteItem

export interface SharedElementsTransitionPresetRequest extends PresetRequestBase {
  preset: 'shared'
  /** 支持 Skyline 的多共享元素；数组后面的元素显示在更高 overlay 层。 */
  elements: SharedElementRouteItem[]
}

export interface ContainerTransitionPresetRequest extends PresetRequestBase {
  preset: 'container'
  /** Open Container 只需要关闭态卡片 selector。 */
  source: string
  /** 官方九项属性均为可选，省略时使用 white/0/300/fade。 */
  container?: Omit<OpenContainerSpec, 'sourceSelector'>
}

export type TransitionPresetRequest =
  | BasicTransitionPresetRequest
  | SharedTransitionPresetRequest
  | SharedElementsTransitionPresetRequest
  | ContainerTransitionPresetRequest

export type OpenResponse = NavigateResponse<Record<string, unknown>>
type Callback<T = unknown> = (result: NavigateResponse<T>) => void

const RESERVED_ROUTE_QUERY_KEYS = new Set(['bundle', 'url', 'route_key'])
/** 当前 Playground OTA TEST 归属的服务端 App ID；发布脚本只接受服务端已有 ID。 */
const PLAYGROUND_OTA_APP_ID = '10000001'

function localBundleName(value: string): string | undefined {
  let normalized = value.trim()
  if (/^https?:\/\//i.test(normalized)) return undefined
  normalized = normalized.replace(/^assets:\/\//i, '').replace(/^bundles\//i, '')
  if (normalized.includes('://')) return undefined
  return normalized.toLowerCase().endsWith('.lynx.bundle') ? normalized : undefined
}

function otaIdentityForBundle(value: string): Record<string, string> {
  const bundleName = localBundleName(value)
  return bundleName
    ? { lynxAppId: PLAYGROUND_OTA_APP_ID, bundleName }
    : {}
}

/** 给 Playground 内部手写 hybrid/lynxshell 路由补上 OTA 逻辑身份。 */
function withPlaygroundOtaIdentity(route: string): string {
  if (!/^(?:hybrid:\/\/lynxview_page|lynxshell:\/\/open)\?/i.test(route)) return route
  if (/[?&](?:lynxAppId|appId|lynx_app_id)=/i.test(route)) return route
  const match = route.match(/[?&](?:bundle|url)=([^&]*)/i)
  if (!match) return route
  let rawBundle = match[1]
  try {
    rawBundle = decodeURIComponent(rawBundle)
  } catch {
    return route
  }
  const identity = otaIdentityForBundle(rawBundle)
  if (!identity.bundleName) return route
  return `${route}&lynxAppId=${encodeURIComponent(identity.lynxAppId)}&bundleName=${encodeURIComponent(identity.bundleName)}`
}

function queryValue(value: unknown): string {
  if (
    typeof value === 'string'
    || typeof value === 'number'
    || typeof value === 'boolean'
  ) {
    return String(value)
  }
  // 结构化 query 值必须显式 JSON 化，禁止隐式变成 "[object Object]"。
  const serialized = JSON.stringify(value)
  if (serialized === undefined) {
    throw new TypeError('query 参数只支持 string/number/boolean 或可 JSON 序列化值')
  }
  return serialized
}

function safeRouteParams(params: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(
    Object.entries(params).filter(([key]) => !RESERVED_ROUTE_QUERY_KEYS.has(key)),
  )
}

function queryString(params: Record<string, unknown>): string {
  return Object.entries(params)
    .filter(([, value]) => value !== undefined && value !== null)
    .map(([key, value]) => `${encodeURIComponent(key)}=${encodeURIComponent(queryValue(value))}`)
    .join('&')
}

/** 去掉只属于 URL query 的 params，其余字段原样交给 Native Module。 */
function nativeOptions(
  options: NavigateRequest['options'] = {},
): Record<string, unknown> {
  const { params: _params, ...rest } = options
  return rest
}

function invokeRoute(
  method: 'open' | 'redirect',
  route: string,
  options: Record<string, unknown>,
  callback?: Callback,
): void {
  shellModule()[method](
    route,
    JSON.stringify(options),
    (result: NativeResult) => callback?.(normalizeShellResult(result)),
  )
}

/** 使用 Sparkling Playground 兼容路径打开一个 Lynx Bundle。 */
export function navigate(
  request: NavigateRequest,
  callback?: Callback,
): void {
  const params = safeRouteParams(request.options?.params || {})
  const routeKey = request.options?.routeKey
  const otaIdentity = otaIdentityForBundle(request.path)
  const query = queryString({
    ...params,
    ...otaIdentity,
    bundle: request.path,
    ...(routeKey ? { route_key: routeKey } : {}),
  })
  invokeRoute(
    'open',
    `hybrid://lynxview_page?${query}`,
    nativeOptions(request.options),
    callback,
  )
}

/** 把业务 key 稳定映射为两页都能复用的 Lynx id。 */
export function shareElementSelector(key: string): string {
  const normalized = key.trim()
  if (!normalized) {
    throw new Error('share-element key 不能为空')
  }
  const slug = normalized
    .replace(/[^A-Za-z0-9_-]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 56)
  let hash = 2166136261
  for (let index = 0; index < normalized.length; index += 1) {
    hash ^= normalized.charCodeAt(index)
    hash = Math.imul(hash, 16777619)
  }
  return `lynx-share-${slug || 'element'}-${(hash >>> 0).toString(36)}`
}

function normalizeSharedElement(item: SharedElementRouteItem): SharedElementSpec {
  if ('source' in item && item.source && item.target) {
    return {
      key: item.key || `${item.source}:${item.target}`.slice(0, 128),
      sourceSelector: item.source,
      targetSelector: item.target,
      // 便捷 API 默认让返回手势驱动共享元素；底层 NativeTransitionSpec 仍默认 false。
      transitionOnGesture: item.transitionOnGesture ?? true,
      shuttleOnPush: item.shuttleOnPush || 'to',
      shuttleOnPop: item.shuttleOnPop || 'to',
      rectTweenType: item.rectTweenType || 'materialRectArc',
      sourceStyle: item.sourceStyle,
      targetStyle: item.targetStyle,
    }
  }
  const key = item.key
  if (!key) {
    throw new Error('share-element 必须提供 key，或同时提供 source/target')
  }
  const selector = shareElementSelector(key)
  return {
    key,
    sourceSelector: selector,
    targetSelector: selector,
    transitionOnGesture: item.transitionOnGesture ?? true,
    shuttleOnPush: item.shuttleOnPush || 'to',
    shuttleOnPop: item.shuttleOnPop || 'to',
    rectTweenType: item.rectTweenType || 'materialRectArc',
    sourceStyle: item.sourceStyle,
    targetStyle: item.targetStyle,
  }
}

function presetTransition(
  request: TransitionPresetRequest,
): Pick<OpenNavigationOptions, 'routeType' | 'transition' | 'animated' | 'transparent'> {
  switch (request.preset) {
    case 'shared': {
      const items = 'elements' in request ? request.elements : [request]
      if (items.length === 0 || items.length > 8) {
        throw new Error('share-element elements 数量必须为 1..8')
      }
      const elements = items.map(normalizeSharedElement)
      return {
        transition: {
          style: 'sharedElement',
          sharedElements: elements,
          popGesture: {
            enabled: true,
            direction: 'horizontal',
            fullScreen: false,
            edgeWidth: 48,
          },
        },
      }
    }
    case 'container':
      return {
        transition: {
          style: 'openContainer',
          openContainer: {
            sourceSelector: request.source,
            ...request.container,
          },
          popGesture: {
            enabled: true,
            direction: 'horizontal',
            fullScreen: false,
            edgeWidth: 48,
          },
        },
      }
    case 'up':
    case 'upwards':
      return { routeType: 'wx://upwards' }
    case 'zoom':
      return { routeType: 'wx://zoom' }
    case 'bottomSheet':
      return { routeType: 'wx://bottom-sheet' }
    case 'heroSheet':
      return {
        routeType: 'wx://hero-sheet',
        transparent: true,
        // heroSheet 的入场/退场动画由 Lynx 页面执行，原生只立即切换承载层。
        animated: false,
      }
    case 'cupertinoModal':
      return { routeType: 'wx://cupertino-modal' }
    case 'cupertinoModalInside':
      return { routeType: 'wx://cupertino-modal-inside' }
    case 'modalNavigation':
      return { routeType: 'wx://modal-navigation' }
    case 'modal':
      return { routeType: 'wx://modal' }
    default:
      return { transition: { style: request.preset } }
  }
}

/**
 * 推荐给业务使用的转场入口：基础预设只传 bundle + preset，共享元素再传 source/target。
 */
export function navigateWithPreset(
  request: TransitionPresetRequest,
  callback?: Callback,
): void {
  navigate(
    {
      path: request.bundle,
      options: {
        routeKey: request.routeKey || request.bundle,
        params: request.params,
        routeConfig: request.routeConfig,
        routeOptions: request.routeOptions,
        ...presetTransition(request),
      },
    },
    callback,
  )
}

/** 最短共享元素调用，不暴露 duration、fallback、手势阈值等框架参数。 */
export function navigateSharedElement(
  request: NavigateSharedElementRequest,
  callback?: Callback,
): void {
  const presetRequest: SharedTransitionPresetRequest = { ...request, preset: 'shared' }
  navigateWithPreset(presetRequest, callback)
}

/** 多共享元素调用；最多 8 个，声明顺序决定 overlay 层级。 */
export function navigateSharedElements(
  request: Omit<SharedElementsTransitionPresetRequest, 'preset'>,
  callback?: Callback,
): void {
  navigateWithPreset({ ...request, preset: 'shared' }, callback)
}

/** 最短 Open Container 调用，只要求目标 Bundle 和源卡片 selector。 */
export function navigateOpenContainer(
  request: Omit<ContainerTransitionPresetRequest, 'preset'>,
  callback?: Callback,
): void {
  navigateWithPreset({ ...request, preset: 'container' }, callback)
}

function normalizeRouteEvent(payload: unknown): RouteDoneEvent {
  let candidate = payload
  if (Array.isArray(candidate) && candidate.length === 1) {
    candidate = candidate[0]
  }
  if (typeof candidate === 'string') {
    try {
      candidate = JSON.parse(candidate) as unknown
    } catch {
      return { status: 'unknown', reason: 'invalid_event_json' }
    }
  }
  if (!candidate || typeof candidate !== 'object' || Array.isArray(candidate)) {
    return { status: 'unknown', reason: 'invalid_event_payload' }
  }
  const value = candidate as Record<string, unknown>
  const allowedStatus: RouteTerminalStatus[] = [
    'completed',
    'cancelled',
    'degraded',
    'failed',
  ]
  const status = typeof value.status === 'string'
    && allowedStatus.includes(value.status as RouteTerminalStatus)
    ? value.status as RouteTerminalStatus
    : 'unknown'
  const direction = value.direction === 'push' || value.direction === 'pop'
    ? value.direction
    : undefined
  return {
    status,
    direction,
    transactionID: typeof value.transactionID === 'string'
      ? value.transactionID
      : undefined,
    routeKey: typeof value.routeKey === 'string' ? value.routeKey : undefined,
    reason: typeof value.reason === 'string'
      ? value.reason
      : status === 'unknown' ? 'invalid_event_status' : undefined,
  }
}

function listenRouteEvent(
  eventName: 'onRouteDone' | 'onTransitionSettled',
  listener: (event: RouteDoneEvent) => void,
): () => void {
  const emitter = lynx.getJSModule('GlobalEventEmitter')
  const nativeListener = (payload: unknown) => listener(normalizeRouteEvent(payload))
  emitter.addListener(eventName, nativeListener)
  return () => emitter.removeListener(eventName, nativeListener)
}

/**
 * 对应 Skyline 页面生命周期：只在路由真正提交完成后触发，手势取消不会触发。
 */
export function onRouteDone(listener: (event: RouteDoneEvent) => void): () => void {
  return listenRouteEvent('onRouteDone', listener)
}

/** 壳扩展：所有终态都触发，包含手势取消和失败。 */
export function onTransitionSettled(
  listener: (event: RouteDoneEvent) => void,
): () => void {
  return listenRouteEvent('onTransitionSettled', listener)
}

/** 直接打开任意壳支持的 scheme；原生回调只代表栈事务已提交。 */
export function open(
  request: OpenRequest,
  callback?: Callback,
): void {
  invokeRoute('open', withPlaygroundOtaIdentity(request.scheme), request.options || {}, callback)
}

/** 关闭当前容器；即使当前页是 session 首页也可以返回宿主页。 */
export function close(callback?: Callback): void {
  shellModule().close(
    (result: NativeResult) => callback?.(normalizeShellResult(result)),
  )
}

/** 在当前 Lynx session 内回退 delta 页，最多退到 session 首页。 */
export function back(
  delta = 1,
  options: NavigationCommandOptions = {},
  callback?: Callback,
): void {
  shellModule().back(
    delta,
    JSON.stringify(options),
    (result: NativeResult) => callback?.(normalizeShellResult(result)),
  )
}

/** 保留旧调用 popTo(routeKey, callback)，同时支持新的 options。 */
export function popTo(routeKey: string, callback?: Callback): void
export function popTo(
  routeKey: string,
  options: NavigationCommandOptions,
  callback?: Callback,
): void
export function popTo(
  routeKey: string,
  optionsOrCallback: NavigationCommandOptions | Callback = {},
  callback?: Callback,
): void {
  if (typeof optionsOrCallback === 'function') {
    shellModule().popTo(
      routeKey,
      (result: NativeResult) => optionsOrCallback(normalizeShellResult(result)),
    )
    return
  }
  shellModule().popToWithOptions(
    routeKey,
    JSON.stringify(optionsOrCallback),
    (result: NativeResult) => callback?.(normalizeShellResult(result)),
  )
}

/** 保留旧调用 closeAll(callback)，同时支持 animated/deduplicate options。 */
export function closeAll(callback?: Callback): void
export function closeAll(
  options: NavigationCommandOptions,
  callback?: Callback,
): void
export function closeAll(
  optionsOrCallback: NavigationCommandOptions | Callback = {},
  callback?: Callback,
): void {
  if (typeof optionsOrCallback === 'function') {
    shellModule().closeAll(
      (result: NativeResult) => optionsOrCallback(normalizeShellResult(result)),
    )
    return
  }
  shellModule().closeAllWithOptions(
    JSON.stringify(optionsOrCallback),
    (result: NativeResult) => callback?.(normalizeShellResult(result)),
  )
}

/** 关闭当前 session，并由宿主 Home Handler 返回 App 主 Tab/首页。 */
export function reLaunch(
  options: NavigationCommandOptions & Record<string, unknown> = {},
  callback?: Callback,
): void {
  shellModule().reLaunch(
    JSON.stringify(options),
    (result: NativeResult) => callback?.(normalizeShellResult(result)),
  )
}

/** 用目标页面原位替换当前 entry；entryID/session/order 保持不变。 */
export function redirect(
  request: NavigateRequest,
  callback?: Callback,
): void {
  const params = safeRouteParams(request.options?.params || {})
  const routeKey = request.options?.routeKey
  const otaIdentity = otaIdentityForBundle(request.path)
  const query = queryString({
    ...params,
    ...otaIdentity,
    bundle: request.path,
    ...(routeKey ? { route_key: routeKey } : {}),
  })
  invokeRoute(
    'redirect',
    `hybrid://lynxview_page?${query}`,
    nativeOptions(request.options),
    callback,
  )
}

/** 读取当前 session 的稳定栈状态，不修改页面。 */
export function getNavigationState(
  callback: Callback<NavigationState>,
): void {
  shellModule().getNavigationState(
    (result: NativeResult<NavigationState>) => callback(normalizeShellResult(result)),
  )
}

/** 关闭当前页并向下面的 Lynx entry 返回一个 JSON Object。 */
export function closeWithResult(
  result: Record<string, unknown>,
  callback?: Callback,
): void {
  shellModule().closeWithResult(
    JSON.stringify(result),
    (value: NativeResult) => callback?.(normalizeShellResult(value)),
  )
}

/** 一次性消费发给当前 entry 的页面结果；没有结果时 hasResult=false。 */
export function consumeNavigationResult(
  callback: Callback<NavigationResultPayload>,
): void {
  shellModule().consumeNavigationResult(
    (result: NativeResult<NavigationResultPayload>) => callback(normalizeShellResult(result)),
  )
}

/**
 * 只预取安全校验后的 Bundle 字节，不创建 LynxView/Activity/UIViewController。
 *
 * 该能力是当前壳的性能优化，并不是对 Skyline preset-route 私有缓存实现的推测。
 */
export function prepareRoute(
  request: OpenRequest,
  callback: Callback<PreparedRoute>,
): void {
  shellModule().prepareRoute(
    withPlaygroundOtaIdentity(request.scheme),
    JSON.stringify(request.options || {}),
    (result: NativeResult<PreparedRoute>) => callback(normalizeShellResult(result)),
  )
}

/** 主动释放尚未消费的预加载句柄。 */
export function cancelPreparedRoute(
  token: string,
  callback?: Callback,
): void {
  shellModule().cancelPreparedRoute(
    token,
    (result: NativeResult) => callback?.(normalizeShellResult(result)),
  )
}

/**
 * 通知原生：当前事务的异步内容已经稳定。
 *
 * 页面不传屏幕坐标，也不回写动画 progress；元素尺寸仍由 Activity/VC 在主线程测量。
 */
export function markTransitionReady(
  transactionID: string,
  callback?: Callback,
): void {
  shellModule().markTransitionReady(
    transactionID,
    (result: NativeResult) => callback?.(normalizeShellResult(result)),
  )
}

/** 低频读取原生转场状态，仅用于诊断和演示。 */
export function getTransitionState(
  callback: Callback<TransitionState>,
): void {
  shellModule().getTransitionState(
    (result: NativeResult<TransitionState>) => callback(normalizeShellResult(result)),
  )
}
