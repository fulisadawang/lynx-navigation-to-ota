import url from '@ohos.url';
import ShellJson from '../common/ShellJson';
import ShellSecurityPolicy from '../common/ShellSecurityPolicy';
import { ShellOpenOptions } from '../common/ShellTypes';
import LynxPageRequest from '../model/LynxPageRequest';

/** 路由解析结果：禁止用空 URL 继续创建 LynxView。 */
export class LynxRouteResult {
  readonly request: LynxPageRequest | null;
  readonly errorMessage: string;

  constructor(request: LynxPageRequest | null, errorMessage: string = '') {
    this.request = request;
    this.errorMessage = errorMessage;
  }

  get isSuccess(): boolean {
    return this.request !== null && this.errorMessage.length === 0;
  }
}

/** Explorer、Sparkling 与自定义壳协议的统一解析器。 */
export default class LynxRouteParser {
  private static readonly EXPLORER_PREFIX: string = 'file://lynx?local://';

  static parse(rawRoute: string): LynxRouteResult {
    const route = rawRoute.trim();
    if (route.length === 0) {
      return new LynxRouteResult(null, 'Lynx 路由不能为空');
    }

    if (route.startsWith(LynxRouteParser.EXPLORER_PREFIX)) {
      return LynxRouteParser.parseExplorerRoute(route);
    }

    const lower = route.toLowerCase();
    if (lower.startsWith('lynxshell://') || lower.startsWith('lynx://') || lower.startsWith('hybrid://')) {
      return LynxRouteParser.parseHostSchema(route);
    }

    return LynxRouteParser.buildRequest(route, new url.URLParams(''));
  }

  static parseWithOptions(rawRoute: string, optionsJson: string): LynxRouteResult {
    const result = LynxRouteParser.parse(rawRoute);
    if (!result.isSuccess || result.request === null || optionsJson.trim().length === 0) {
      return result;
    }
    try {
      const parsedOptions = JSON.parse(optionsJson) as Object;
      if (parsedOptions === null || Array.isArray(parsedOptions) || typeof parsedOptions !== 'object') {
        return new LynxRouteResult(null, 'optionsJSON 必须是 JSON Object');
      }
      const options = parsedOptions as ShellOpenOptions;
      LynxRouteParser.applyOpenOptions(result.request, options);
      return LynxRouteParser.validateRequest(result.request);
    } catch (error) {
      return new LynxRouteResult(null, `optionsJSON 不是合法 JSON Object: ${error}`);
    }
  }

  private static parseExplorerRoute(route: string): LynxRouteResult {
    const payload = route.substring(LynxRouteParser.EXPLORER_PREFIX.length);
    const optionIndex = payload.indexOf('?');
    const localPath = optionIndex >= 0 ? payload.substring(0, optionIndex) : payload;
    const query = optionIndex >= 0 ? payload.substring(optionIndex + 1) : '';
    return LynxRouteParser.buildRequest(`local://${localPath}`, new url.URLParams(query));
  }

  private static parseHostSchema(route: string): LynxRouteResult {
    try {
      const parsed = url.URL.parseURL(route);
      const scheme = parsed.protocol.replace(':', '').toLowerCase();
      const host = parsed.hostname.toLowerCase();

      // 只接受壳协议定义的固定入口，避免把任意自定义 Scheme/Host 当作 Lynx 页面。
      // Sparkling Playground 使用 hybrid://lynxview_page；统一壳协议使用 lynxshell://open / lynx://open。
      const isShellRoute = (scheme === 'lynxshell' || scheme === 'lynx') && host === 'open';
      const isSparklingRoute = scheme === 'hybrid' && host === 'lynxview_page';
      if (!isShellRoute && !isSparklingRoute) {
        return new LynxRouteResult(null, `不支持的 Lynx 路由入口: ${scheme}://${host}`);
      }

      const params = new url.URLParams(parsed.search);
      const bundle = LynxRouteParser.firstNonEmpty([
        params.get('url') ?? '',
        params.get('bundle') ?? ''
      ]);
      if (bundle.length === 0) {
        return new LynxRouteResult(null, '路由缺少 url 或 bundle 参数');
      }
      return LynxRouteParser.buildRequest(bundle, params);
    } catch (error) {
      return new LynxRouteResult(null, `路由解析失败: ${error}`);
    }
  }

  private static buildRequest(bundle: string, params: url.URLParams): LynxRouteResult {
    const request = new LynxPageRequest();
    request.bundleUrl = LynxRouteParser.normalizeBundleUrl(bundle);
    const explicitRouteKey = LynxRouteParser.firstNonEmpty([
      params.get('routeKey') ?? '',
      params.get('route_key') ?? ''
    ]);

    // scheme 可以直接携带 OTA 逻辑地址；但 HTTPS 永远是 Direct Remote，不能因为
    // query 同时出现 appId/bundleName 就偷偷进入本地 OTA 目录。
    const isRemoteBundle = ShellSecurityPolicy.isRemoteUrl(request.bundleUrl);
    const requestedAppId = LynxRouteParser.firstNonEmpty([
      params.get('lynxAppId') ?? '',
      params.get('appId') ?? '',
      params.get('lynx_app_id') ?? ''
    ]);
    const requestedBundleName = LynxRouteParser.firstNonEmpty([
      params.get('bundleName') ?? '',
      params.get('bundle_name') ?? ''
    ]);
    if (!isRemoteBundle && requestedAppId.length > 0) {
      request.lynxAppId = requestedAppId;
      request.bundleName = requestedBundleName.length > 0
        ? requestedBundleName
        : LynxRouteParser.lastPathSegment(request.bundleUrl);
    }
    request.routeKey = LynxRouteParser.firstNonEmpty([
      explicitRouteKey,
      request.lynxAppId.length > 0 && request.bundleName.length > 0
        ? `${request.lynxAppId}/${request.bundleName}`
        : '',
      request.bundleUrl
    ]);
    request.title = params.get('title') ?? request.title;
    request.initDataJson = ShellJson.normalizeObjectJson(LynxRouteParser.firstNonEmpty([
      params.get('initData') ?? '',
      params.get('initialData') ?? '',
      params.get('initial_data') ?? ''
    ]));
    const explicitGlobalProps = ShellJson.normalizeObjectJson(LynxRouteParser.firstNonEmpty([
      params.get('globalProps') ?? '',
      params.get('global_props') ?? ''
    ]));
    // Sparkling Playground 约定把 URL query 暴露为 __globalProps.queryItems。
    // 原生壳参数解析成功不等于页面能收到参数，这里与 Android/iOS 保持同一契约。
    const globalProps = ShellJson.parseObject(explicitGlobalProps) as Record<string, Object>;
    const queryItems: Record<string, string> = {};
    for (const key of params.keys()) {
      const value = params.get(key);
      if (value !== null && value !== undefined) {
        queryItems[key] = value;
      }
    }
    globalProps['queryItems'] = queryItems;
    request.globalPropsJson = JSON.stringify(globalProps);

    const hideNavigationValue = LynxRouteParser.firstNonEmpty([
      params.get('hideNavigationBar') ?? '',
      params.get('hideNavBar') ?? '',
      params.get('hide_nav_bar') ?? '',
      params.get('hidden_nav') ?? ''
    ]);
    // Lynx 页面默认自绘导航；字段仅为跨端协议兼容，Container 不渲染原生标题栏。
    request.hideNavigationBar = LynxRouteParser.parseBoolean(hideNavigationValue, true);

    const showNavigationValue = LynxRouteParser.firstNonEmpty([
      params.get('showNavigationBar') ?? '',
      params.get('showToolbar') ?? ''
    ]);
    if (showNavigationValue.length > 0) {
      request.hideNavigationBar = !LynxRouteParser.parseBoolean(showNavigationValue, true);
    }

    request.hideStatusBar = LynxRouteParser.parseBoolean(LynxRouteParser.firstNonEmpty([
      params.get('hideStatusBar') ?? '',
      params.get('hide_status_bar') ?? ''
    ]), false);
    request.fullscreen = LynxRouteParser.parseBoolean(params.get('fullscreen') ?? '', false);
    if (request.fullscreen) {
      request.hideNavigationBar = true;
      request.hideStatusBar = true;
    }

    request.orientation = LynxRouteParser.normalizeOrientation(LynxRouteParser.firstNonEmpty([
      params.get('orientation') ?? '',
      params.get('screenOrientation') ?? '',
      params.get('screen_orientation') ?? ''
    ]));
    request.backgroundColor = LynxRouteParser.normalizeColor(LynxRouteParser.firstNonEmpty([
      params.get('backgroundColor') ?? '',
      params.get('background_color') ?? ''
    ]));
    request.widthPx = LynxRouteParser.parsePositiveNumber(LynxRouteParser.firstNonEmpty([
      params.get('width') ?? '',
      params.get('widthPx') ?? '',
      params.get('width_px') ?? ''
    ]));
    request.heightPx = LynxRouteParser.parsePositiveNumber(LynxRouteParser.firstNonEmpty([
      params.get('height') ?? '',
      params.get('heightPx') ?? '',
      params.get('height_px') ?? ''
    ]));
    request.allowHttpInDebug = LynxRouteParser.parseBoolean(LynxRouteParser.firstNonEmpty([
      params.get('allowHttpInDebug') ?? '',
      params.get('allow_http_in_debug') ?? '',
      params.get('allowHttp') ?? '',
      params.get('allow_http') ?? ''
    ]), false);

    return LynxRouteParser.validateRequest(request);
  }

  private static applyOpenOptions(request: LynxPageRequest, options: ShellOpenOptions): void {
    request.title = options.title ?? request.title;
    if (options.initData !== undefined) {
      request.initDataJson = ShellJson.normalizeObjectJson(JSON.stringify(options.initData));
    }
    if (options.globalProps !== undefined) {
      request.globalPropsJson = ShellJson.normalizeObjectJson(JSON.stringify(options.globalProps));
    }
    request.hideNavigationBar = options.hideNavigationBar ?? options.hideNavBar ?? request.hideNavigationBar;
    request.hideStatusBar = options.hideStatusBar ?? request.hideStatusBar;
    request.fullscreen = options.fullscreen ?? request.fullscreen;
    if (request.fullscreen) {
      request.hideNavigationBar = true;
      request.hideStatusBar = true;
    }
    request.orientation = LynxRouteParser.normalizeOrientation(
      options.orientation ?? options.screenOrientation ?? request.orientation
    );
    request.backgroundColor = LynxRouteParser.normalizeColor(options.backgroundColor ?? request.backgroundColor);
    const width = options.widthPx ?? options.width;
    request.widthPx = width !== undefined && width > 0 ? width : request.widthPx;
    const height = options.heightPx ?? options.height;
    request.heightPx = height !== undefined && height > 0 ? height : request.heightPx;
    request.allowHttpInDebug = options.allowHttpInDebug ?? options.allowHttp ?? request.allowHttpInDebug;
    const requestedAppId = options.lynxAppId?.trim() ?? request.lynxAppId;
    const requestedBundleName = options.bundleName?.trim() ?? request.bundleName;
    if (ShellSecurityPolicy.isRemoteUrl(request.bundleUrl)) {
      // HTTPS 的语义是“按给定 URL 直接加载”，即使 options 带了 OTA 字段也必须清空。
      request.lynxAppId = '';
      request.bundleName = '';
    } else {
      request.lynxAppId = requestedAppId;
      request.bundleName = requestedBundleName.length > 0
        ? requestedBundleName
        : (requestedAppId.length > 0 ? LynxRouteParser.lastPathSegment(request.bundleUrl) : '');
    }
    if (request.lynxAppId.length > 0 && request.bundleName.length > 0) {
      request.routeKey = `${request.lynxAppId}/${request.bundleName}`;
    }
  }

  private static validateRequest(request: LynxPageRequest): LynxRouteResult {
    // 再次在校验边界执行 Direct Remote 隔离，防止未来新增 options 字段时绕过上面的清理。
    if (ShellSecurityPolicy.isRemoteUrl(request.bundleUrl)) {
      request.lynxAppId = '';
      request.bundleName = '';
    }
    const hasOtaAppId = request.lynxAppId.trim().length > 0;
    const hasOtaBundleName = request.bundleName.trim().length > 0;
    if (hasOtaAppId !== hasOtaBundleName) {
      return new LynxRouteResult(null, 'OTA 路由必须同时提供 lynxAppId 和 bundleName');
    }
    if (hasOtaBundleName && !LynxRouteParser.isSafeOtaBundleName(request.bundleName)) {
      return new LynxRouteResult(null, 'OTA bundleName 必须是安全的相对 .lynx.bundle 路径');
    }
    if (ShellSecurityPolicy.isRemoteUrl(request.bundleUrl)) {
      const result = ShellSecurityPolicy.validateTemplateUrl(request.bundleUrl, request.allowHttpInDebug);
      return result.valid ? new LynxRouteResult(request) : new LynxRouteResult(null, result.message);
    }

    const localResult = ShellSecurityPolicy.validateLocalRawFilePath(request.bundleUrl);
    return localResult.valid ? new LynxRouteResult(request) : new LynxRouteResult(null, localResult.message);
  }

  private static normalizeBundleUrl(value: string): string {
    let result = value.trim();
    if (ShellSecurityPolicy.isRemoteUrl(result)) {
      return result;
    }
    if (result.startsWith('assets://')) {
      result = result.substring('assets://'.length);
    } else if (result.startsWith('local://')) {
      result = result.substring('local://'.length);
    }
    while (result.startsWith('./')) {
      result = result.substring(2);
    }
    if (!result.includes('/') && result.length > 0) {
      result = `bundles/${result}`;
    }
    return result;
  }

  private static normalizeOrientation(value: string): string {
    const normalized = value.trim().toLowerCase();
    if (normalized === 'portrait' || normalized === 'landscape') {
      return normalized;
    }
    return 'auto';
  }

  private static normalizeColor(value: string): string {
    const normalized = value.trim();
    if (/^#[0-9a-fA-F]{6}$/.test(normalized) || /^#[0-9a-fA-F]{8}$/.test(normalized)) {
      return normalized.toUpperCase();
    }
    return '#FFFFFF';
  }

  private static parsePositiveNumber(value: string): number {
    if (value.trim().length === 0) {
      return 0;
    }
    const parsed = Number(value);
    return Number.isFinite(parsed) && parsed > 0 ? parsed : 0;
  }

  /** 从受控的本地 Bundle 路径推导默认逻辑名称；绝不用于 HTTPS URL 的 appId 反查。 */
  private static lastPathSegment(value: string): string {
    const pieces = value.split('/');
    return pieces.length > 0 ? pieces[pieces.length - 1] : '';
  }

  /** OTA 逻辑名称只允许相对路径，避免 scheme/options 把路径穿越带进本地 Store。 */
  private static isSafeOtaBundleName(value: string): boolean {
    const normalized = value.trim();
    if (!normalized.toLowerCase().endsWith('.lynx.bundle') || normalized.startsWith('/') ||
      normalized.includes('\\') || normalized.includes('\0')) {
      return false;
    }
    const segments = normalized.split('/');
    return segments.length > 0 && !segments.some((segment: string) =>
      segment.length === 0 || segment === '.' || segment === '..');
  }

  private static parseBoolean(value: string, fallback: boolean): boolean {
    const normalized = value.trim().toLowerCase();
    if (normalized === '1' || normalized === 'true' || normalized === 'yes') {
      return true;
    }
    if (normalized === '0' || normalized === 'false' || normalized === 'no') {
      return false;
    }
    return fallback;
  }

  private static firstNonEmpty(values: string[]): string {
    for (const value of values) {
      if (value.trim().length > 0) {
        return value;
      }
    }
    return '';
  }

  private constructor() {
  }
}
