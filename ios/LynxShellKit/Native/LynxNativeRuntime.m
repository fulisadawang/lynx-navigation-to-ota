#import "LynxNativeRuntime.h"

#import <Lynx/LynxConfig.h>
#import <Lynx/LynxEnv.h>
#import <Lynx/LynxTemplateData.h>
#if defined(LYNX_SHELL_ENABLE_MAP)
#import <LynxMapKit/LynxMapModuleRuntime.h>
#endif
#import <SDWebImage/SDWebImage.h>
#import <SDWebImageWebPCoder/SDWebImageWebPCoder.h>
#import <objc/runtime.h>

// XElement 4.1 全量组件的公开头文件。
// 这些 import 是编译期哨兵：Pod 缺少任一 subspec 时，真实 Xcode 编译会立即失败，
// 而不是等 Lynx 页面渲染到对应标签时才暴露组件未注册问题。
#import <XElement/LynxUIBlurView.h>
#import <XElement/LynxUIInput.h>
#import <XElement/LynxUIMarkdown.h>
#import <XElement/LynxUIOverlay.h>
#import <XElement/LynxUIRefresh.h>
#import <XElement/LynxUIScrollCoordinator.h>
#import <XElement/LynxUISVG.h>
#import <XElement/LynxUITextArea.h>
#import <XElement/LynxUIViewPager.h>
#import <XElement/LynxUIWebView.h>
#import <XElement/LynxUIVideo.h>

// Behavior subspec 的懒注册入口。Lynx 在创建组件时通过这些 Registry 完成映射；
// 不需要宿主再手工调用 registerUI，避免与官方自动注册机制重复。
#import <XElement/LynxUIBlurViewAutoRegistry.h>
#import <XElement/LynxUIInputAutoRegistry.h>
#import <XElement/LynxUIMarkdownAutoRegistry.h>
#import <XElement/LynxUIOverlayAutoRegistry.h>
#import <XElement/LynxUIRefreshAutoRegistry.h>
#import <XElement/LynxUIScrollCoordinatorAutoRegistry.h>
#import <XElement/LynxUISVGAutoRegistry.h>
#import <XElement/LynxUITextAreaAutoRegistry.h>
#import <XElement/LynxUIViewPagerAutoRegistry.h>
#import <XElement/LynxUIWebViewAutoRegistry.h>
#import <XElement/LynxUIVideoAutoRegistry.h>

// Swift Module 与 Provider 会出现在 CocoaPods Target 自动生成的接口头中。
// 条件分支兼容 framework 与 development pod 两种 Header 搜索路径。
#if defined(LYNX_SHELL_E2E_CORE_ONLY)
#if __has_include(<LynxShellKitE2ECore/LynxShellKitE2ECore-Swift.h>)
#import <LynxShellKitE2ECore/LynxShellKitE2ECore-Swift.h>
#else
#import "LynxShellKitE2ECore-Swift.h"
#endif
#elif __has_include(<LynxShellKit/LynxShellKit-Swift.h>)
#import <LynxShellKit/LynxShellKit-Swift.h>
#else
#import "LynxShellKit-Swift.h"
#endif

@implementation LynxNativeRuntime

static NSMutableArray<Class> *LynxHostNativeModules(void) {
  static NSMutableArray<Class> *modules;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{ modules = [NSMutableArray array]; });
  return modules;
}

+ (void)registerNativeModule:(Class)moduleClass {
  NSAssert(NSThread.isMainThread, @"原生模块必须在主线程安装");
  if (![LynxHostNativeModules() containsObject:moduleClass]) {
    [LynxHostNativeModules() addObject:moduleClass];
  }
}

static NSMutableDictionary<NSString *, id> *LynxViewDestroyHandlers(void) {
  static NSMutableDictionary<NSString *, id> *handlers;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{ handlers = [NSMutableDictionary dictionary]; });
  return handlers;
}

+ (void)registerNativeModule:(Class)moduleClass onViewDestroy:(void (^)(LynxContext *))handler {
  [self registerNativeModule:moduleClass];
  if (handler) { LynxViewDestroyHandlers()[NSStringFromClass(moduleClass)] = [handler copy]; }
}

+ (void)destroyView:(LynxView *)view {
  NSAssert(NSThread.isMainThread, @"LynxView 必须在主线程销毁");
  static char destroyedKey;
  if ([objc_getAssociatedObject(view, &destroyedKey) boolValue]) { return; }
  objc_setAssociatedObject(view, &destroyedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  LynxContext *context = [view getLynxContext];
  context.hasLynxViewDestroyed = YES;
  for (id value in LynxViewDestroyHandlers().allValues.copy) {
    void (^handler)(LynxContext *) = value;
    handler(context);
  }
  [view clearForDestroy];
}

static NSString *LynxHostString(NSDictionary *info, NSString *key) {
  id value = info[key];
  if (![value isKindOfClass:[NSString class]]) {
    return nil;
  }
  NSString *string = [(NSString *)value stringByTrimmingCharactersInSet:
                                                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (string.length == 0 || [string rangeOfString:@"$("].location != NSNotFound) {
    return nil;
  }
  return string;
}

+ (void)bootstrap {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    // Image Service 使用 WebP 时必须提前注册 coder。
    SDImageWebPCoder *webPCoder = [SDImageWebPCoder sharedCoder];
    [[SDImageCodersManager sharedManager] addCoder:webPCoder];

    // XElement/Behavior 使用 LYNX_LAZY_REGISTER_* 宏完成全量懒注册。
    // Podfile 已显式包含 Behavior、Video 及现有组件 subspec，宿主无需重复注册 UI 类。

    // 与 Lynx 4.1 Explorer 一致：先拿到 LynxEnv，再准备全局 Config。
    LynxEnv *env = [LynxEnv sharedInstance];
    LynxConfig *globalConfig =
        [[LynxConfig alloc] initWithProvider:[[ShellTemplateProvider alloc] init]];
    [globalConfig registerModule:LynxShellModule.class];
    for (Class moduleClass in LynxHostNativeModules()) {
      [globalConfig registerModule:moduleClass];
    }
#if defined(LYNX_SHELL_ENABLE_MAP)
    [LynxMapModuleRuntime registerModulesIntoConfig:globalConfig];
#endif
    [env prepareConfig:globalConfig];

#if defined(LYNX_SHELL_ENABLE_MAP)
    // 地图 Key 可以由宿主构建配置提供；隐私同意状态必须由运行时授权结果提供，默认拒绝。
    NSDictionary *info = [NSBundle mainBundle].infoDictionary ?: @{};
    BOOL privacyAgreed = NO;
#if DEBUG
    // 模拟器验收必须显式带启动参数；Release 仍由宿主真实授权结果更新。
    privacyAgreed = [NSProcessInfo.processInfo.arguments
                        containsObject:@"--lynx-map-consent-granted"];
#endif
    [LynxMapModuleRuntime bootstrapWithAPIKey:LynxHostString(info, @"LynxMapAPIKey")
                               privacyAgreed:privacyAgreed];
#endif
  });
}

+ (LynxView *)makeViewWithProvider:(id<LynxTemplateProvider>)provider
                        screenSize:(CGSize)screenSize
                       globalProps:(NSDictionary<NSString *, id> *)globalProps {
  return [self makeViewWithProvider:provider
                         screenSize:screenSize
                       viewportSize:screenSize
                        globalProps:globalProps];
}

+ (LynxView *)makeViewWithProvider:(id<LynxTemplateProvider>)provider
                        screenSize:(CGSize)screenSize
                      viewportSize:(CGSize)viewportSize
                       globalProps:(NSDictionary<NSString *, id> *)globalProps {
  return [self makeViewWithProvider:provider resourceFetcher:nil screenSize:screenSize
                      viewportSize:viewportSize globalProps:globalProps];
}

+ (LynxView *)makeViewWithProvider:(id<LynxTemplateProvider>)provider
                  resourceFetcher:(LynxLocalResourceFetcher *)resourceFetcher
                       screenSize:(CGSize)screenSize
                     viewportSize:(CGSize)viewportSize
                      globalProps:(NSDictionary<NSString *, id> *)globalProps {
  LynxConfig *config = [[LynxConfig alloc] initWithProvider:provider];
  [config registerModule:LynxShellModule.class];
  for (Class moduleClass in LynxHostNativeModules()) {
    [config registerModule:moduleClass];
  }
#if defined(LYNX_SHELL_ENABLE_MAP)
  [LynxMapModuleRuntime registerModulesIntoConfig:config];
  // 每个 LynxView 显式注册，保证普通 Page 与 Native Tab 不依赖静态链接器是否保留 lazy symbol。
  [LynxMapModuleRuntime registerUIElementsIntoConfig:config];
#endif

  LynxView *lynxView = [[LynxView alloc] initWithBuilderBlock:^(LynxViewBuilder *builder) {
    builder.config = config;
    if (resourceFetcher) {
      builder.templateResourceFetcher = resourceFetcher;
      builder.genericResourceFetcher = resourceFetcher;
      builder.mediaResourceFetcher = resourceFetcher;
      builder.enableGenericResourceFetcher = LynxBooleanOptionTrue;
    }
    builder.screenSize = screenSize;
    builder.fontScale = 1.0;
    id theme = globalProps[@"theme"];
    builder.colorScheme = [theme isKindOfClass:NSString.class] &&
                                  [theme caseInsensitiveCompare:@"dark"] == NSOrderedSame
                              ? LynxColorSchemeDark
                              : LynxColorSchemeLight;
  }];

  lynxView.preferredLayoutWidth = viewportSize.width;
  lynxView.preferredLayoutHeight = viewportSize.height;
  lynxView.layoutWidthMode = LynxViewSizeModeExact;
  lynxView.layoutHeightMode = LynxViewSizeModeExact;
  lynxView.frame = CGRectMake(0, 0, viewportSize.width, viewportSize.height);

  LynxTemplateData *templateData =
      [[LynxTemplateData alloc] initWithDictionary:globalProps ?: @{}];
  [lynxView updateGlobalPropsWithTemplateData:templateData];
  return lynxView;
}

+ (void)loadURL:(NSString *)url
       initData:(NSDictionary<NSString *, id> *)initData
         inView:(LynxView *)lynxView {
  LynxTemplateData *templateData =
      [[LynxTemplateData alloc] initWithDictionary:initData ?: @{}];
  [lynxView loadTemplateFromURL:url initData:templateData];
  [lynxView triggerLayout];
}

+ (void)updateLayoutForView:(LynxView *)lynxView size:(CGSize)size {
  [self updateLayoutForView:lynxView size:size screenSize:size];
}

+ (void)updateLayoutForView:(LynxView *)lynxView
                        size:(CGSize)size
                  screenSize:(CGSize)screenSize {
  NSAssert([NSThread isMainThread], @"LynxView 布局更新必须在主线程调用");
  lynxView.frame = CGRectMake(0, 0, size.width, size.height);
  [lynxView updateScreenMetricsWithWidth:screenSize.width height:screenSize.height];
  [lynxView updateViewportWithPreferredLayoutWidth:size.width
                               preferredLayoutHeight:size.height
                                          needLayout:YES];
}

+ (void)updateColorSchemeForView:(LynxView *)lynxView darkMode:(BOOL)darkMode {
  NSAssert([NSThread isMainThread], @"LynxView.updateColorScheme 必须在主线程调用");
  [lynxView updateColorScheme:darkMode ? LynxColorSchemeDark : LynxColorSchemeLight];
}

+ (void)updateGlobalProps:(NSDictionary<NSString *, id> *)globalProps
                   inView:(LynxView *)lynxView {
  LynxTemplateData *templateData =
      [[LynxTemplateData alloc] initWithDictionary:globalProps ?: @{}];
  [lynxView updateGlobalPropsWithTemplateData:templateData];
}

@end

@interface LynxLocalResourceFetcher ()
@property(nonatomic, strong) id<LynxTemplateProvider> provider;
@property(nonatomic, copy) LynxLocalResolveBlock resolver;
@property(nonatomic, copy) LynxLocalURLBlock localURL;
@property(atomic, assign) BOOL cancelled;
@end

@implementation LynxLocalResourceFetcher

- (instancetype)initWithProvider:(id<LynxTemplateProvider>)provider
                         resolver:(LynxLocalResolveBlock)resolver
                         localURL:(LynxLocalURLBlock)localURL {
  if ((self = [super init])) {
    _provider = provider;
    _resolver = [resolver copy];
    _localURL = [localURL copy];
  }
  return self;
}

- (void)cancel { self.cancelled = YES; }

- (NSError *)unavailableError {
  return [NSError errorWithDomain:@"LynxLocalResource" code:404
                        userInfo:@{NSLocalizedDescriptionKey:@"当前页面版本没有可用的本地资源"}];
}

- (void)fetchTemplate:(LynxResourceRequest *)request onComplete:(LynxTemplateResourceCompletionBlock)callback {
  if (self.cancelled) return;
  __weak typeof(self) weakSelf = self;
  LynxGenericResourceCompletionBlock complete = ^(NSData *data, NSError *error) {
    typeof(self) self = weakSelf;
    if (!self || self.cancelled) return;
    callback(data ? [[LynxTemplateResource alloc] initWithNSData:data] : nil, error);
  };
  if (request.type == LynxResourceTypeTemplate) {
    [self.provider loadTemplateWithUrl:request.url onComplete:complete];
  } else if (request.type == LynxResourceTypeDynamicComponent) {
    self.resolver(request.url, complete);
  } else {
    callback(nil, [self unavailableError]);
  }
}

- (void)fetchSSRData:(LynxResourceRequest *)request onComplete:(LynxSSRResourceCompletionBlock)callback {
  if (!self.cancelled) callback(nil, [self unavailableError]);
}

- (dispatch_block_t)fetchResource:(LynxResourceRequest *)request onComplete:(LynxGenericResourceCompletionBlock)callback {
  NSProgress *progress = [NSProgress progressWithTotalUnitCount:1];
  __weak typeof(self) weakSelf = self;
  if (!self.cancelled) self.resolver(request.url, ^(NSData *data, NSError *error) {
    typeof(self) self = weakSelf;
    if (self && !self.cancelled && !progress.cancelled) callback(data, error);
  });
  return ^{ [progress cancel]; };
}

- (dispatch_block_t)fetchResourcePath:(LynxResourceRequest *)request onComplete:(LynxGenericResourcePathCompletionBlock)callback {
  if (!self.cancelled) {
    NSURL *url = self.localURL(request.url);
    callback(url.path, url ? nil : [self unavailableError]);
  }
  return ^{};
}

- (LynxResourceOptionalBool)isLocalResource:(NSURL *)url {
  if (self.cancelled) return LynxResourceOptionalBoolFalse;
  return self.localURL(url.absoluteString) || [url.scheme isEqualToString:@"webpack"]
      ? LynxResourceOptionalBoolTrue : LynxResourceOptionalBoolFalse;
}

- (NSString *)shouldRedirectUrl:(LynxResourceRequest *)request {
  if (self.cancelled) return @"";
  NSURL *url = self.localURL(request.url);
  if (url) return url.absoluteString;
  return [request.url hasPrefix:@"webpack:"] ? @"" : request.url;
}
@end
