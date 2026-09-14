import ShellJson from './ShellJson';
import ShellConstants from './ShellConstants';
import ShellThemeState from './ShellTheme';
import ShellLocaleState from './ShellLocale';
import ShellLayoutState from './ShellLayoutState';
import LynxPageRequest from '../model/LynxPageRequest';

/** 页面可见的真实 Bundle 身份；loadPolicy 与 source 分离，避免把 cache-only 当成来源。 */
export interface ShellBundleMetadata {
  lynxAppId: string;
  releaseId: string;
  source: string;
  bundleName: string;
  sha256: string;
  manifestId?: string;
  navigationSnapshotID?: string;
  loadPolicy?: string;
  userIdentityEpoch?: number;
  selectionKind?: string;
  releaseSequence?: string;
  policyRevision?: string;
}

/** 构建传给 Lynx 的 globalProps，保留业务字段并补充稳定宿主信息。 */
export default class ShellGlobalPropsFactory {
  static build(
    businessJson: string,
    request?: LynxPageRequest,
    bundleMetadata?: ShellBundleMetadata
  ): Object {
    const business = ShellJson.parseObject(businessJson) as Record<string, Object>;
    const pageId = request?.entryID ?? '';
    const environment = ShellGlobalPropsFactory.environmentProps(pageId);
    Object.keys(environment).forEach((key: string) => {
      business[key] = environment[key];
    });
    business['platform'] = 'harmony';
    business['os'] = 'harmony';
    business['lynxVersion'] = '4.0';
    business['theme'] = ShellThemeState.current();
    business['frontendTheme'] = 'system';
    business['hostAppVersion'] = ShellConstants.APP_VERSION;
    const queryItems = (business['queryItems'] as Record<string, Object>) ?? {};
    if (request !== undefined) {
      queryItems['fullscreen'] = request.fullscreen ? '1' : '0';
      queryItems['hide_nav_bar'] = request.hideNavigationBar ? '1' : '0';
      queryItems['hide_status_bar'] = request.hideStatusBar ? '1' : '0';
    }
    business['queryItems'] = queryItems;
    // v1 跨端契约：每次打开同一个 Bundle 都必须拥有独立 pageId，不能使用 Bundle 名称或
    // hash 作为消息目标。containerID 继续保留为旧 Shell 字段，但值改为当前 entry 身份。
    const resolvedPageId = request?.entryID ?? `lynx-shell-${request?.bundleUrl ?? 'container'}`;
    const pageKey = request?.routeKey ?? request?.bundleUrl ?? 'lynx';
    business['containerID'] = resolvedPageId;
    business['__lynxRouterContainerId'] = resolvedPageId;
    business['__lynxRouterPageId'] = resolvedPageId;
    business['__lynxRouterPageKey'] = pageKey;
    business['__lynxRouterSessionId'] = request?.sessionID ?? '';
    business['__lynxRouterNavigationModel'] = 'native_page_stack';
    business['__lynxRouterPlatformContainer'] = 'arkui_page';
    business['__lynxRouterParams'] = queryItems;
    if (bundleMetadata !== undefined) {
    business['__lynxBundleMeta'] = bundleMetadata;
    }
    return business;
  }

  /** 主题、语言和布局共用的宿主环境增量字段；业务 GlobalProps 不能覆盖这些字段。 */
  static environmentProps(pageId: string = ''): Record<string, Object> {
    const locale = ShellLocaleState.current();
    const layout = ShellLayoutState.snapshot(pageId);
    const rawScreen = ShellLayoutState.rawScreenSize();
    const props: Record<string, Object> = {};
    props['density'] = layout.density;
    props['screenWidthPx'] = rawScreen.width;
    props['screenHeightPx'] = rawScreen.height;
    props['screenWidth'] = layout.screenWidth;
    props['screenHeight'] = layout.screenHeight;
    props['viewportWidth'] = layout.viewportWidth;
    props['viewportHeight'] = layout.viewportHeight;
    props['direction'] = locale.direction;
    props['locale'] = locale.appLocale;
    props['effectiveLocale'] = locale.appLocale;
    props['appLocale'] = locale.appLocale;
    props['appLocaleOverride'] = locale.appLocaleOverride ?? '';
    props['appLanguage'] = locale.language;
    props['systemLocale'] = locale.systemLocale;
    props['localeSource'] = locale.source;
    props['localeStatus'] = locale.status;
    props['localeRevision'] = locale.revision;
    props['formatLocale'] = locale.formatLocale;
    props['__lynxShellLocale'] = locale;
    props['__lynxShellLayout'] = layout;
    return props;
  }

  private constructor() {
  }
}
