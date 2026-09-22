#import "LynxNativeRuntime.h"

#import <Lynx/LynxConfig.h>
#import <Lynx/LynxEnv.h>
#import <Lynx/DevToolSettings.h>
#import <Lynx/LynxService.h>
#import <Lynx/LynxServiceDevToolProtocol.h>
#import <Lynx/LynxTemplateData.h>
#import <LynxMapKit/LynxMapModuleRuntime.h>
#import <SDWebImage/SDWebImage.h>
#import <SDWebImageWebPCoder/SDWebImageWebPCoder.h>

// 同根 Pod 的调试 subspec 会合并；禁止用开发 Pods 构建生产 Release。
#if !DEBUG && __has_include(<LynxDevtool/LynxDevtoolEnv.h>)
#error "Release 必须先使用 LYNX_DEVTOOLS=0 pod install 解析不含 DevTool 的依赖"
#endif

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
#if __has_include(<LynxShellKit/LynxShellKit-Swift.h>)
#import <LynxShellKit/LynxShellKit-Swift.h>
#else
#import "LynxShellKit-Swift.h"
#endif

@implementation LynxNativeRuntime

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

    DevToolSettings *settings = [DevToolSettings sharedInstance];
#if DEBUG
    [settings.bootstrap applyDevelopmentDefaultsIfUnset];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    // 仅首次写入默认值，保留官方设置页的持久化选择。
    if ([defaults objectForKey:SP_KEY_ENABLE_DEVTOOL] == nil) settings.devToolEnabled = YES;
    if ([defaults objectForKey:SP_KEY_ENABLE_LOGBOX] == nil) settings.logBoxEnabled = YES;
    if ([defaults objectForKey:SP_KEY_ENABLE_DOM_TREE] == nil) settings.domTreeEnabled = YES;
    if ([defaults objectForKey:SP_KEY_ENABLE_LONG_PRESS_MENU] == nil) settings.longPressMenuEnabled = YES;
    // 默认保留 iOS 的生产引擎选择；需要 JS 断点时由开发者开启 PrimJS 调试并重启。
    if ([defaults objectForKey:SP_KEY_ENABLE_QUICKJS_DEBUG] == nil) settings.quickjsDebugEnabled = NO;
#else
    settings.bootstrap.lynxDebugEnabled = NO;
    settings.bootstrap.logBoxEnabled = NO;
#endif

    // bootstrap 必须早于首次获取 LynxEnv，业务 Config 和页面加载保持原有顺序。
    LynxEnv *env = [LynxEnv sharedInstance];
#if DEBUG
    [LynxService(LynxServiceDevToolProtocol) enableAllSessions];
#else
    env.lynxDebugEnabled = NO;
#endif
    LynxConfig *globalConfig =
        [[LynxConfig alloc] initWithProvider:[[ShellTemplateProvider alloc] init]];
    [globalConfig registerModule:LynxShellModule.class];
    [LynxMapModuleRuntime registerModulesIntoConfig:globalConfig];
    [env prepareConfig:globalConfig];

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
  LynxConfig *config = [[LynxConfig alloc] initWithProvider:provider];
  [config registerModule:LynxShellModule.class];
  [LynxMapModuleRuntime registerModulesIntoConfig:config];
  // 每个 LynxView 显式注册，保证普通 Page 与 Native Tab 不依赖静态链接器是否保留 lazy symbol。
  [LynxMapModuleRuntime registerUIElementsIntoConfig:config];

  LynxView *lynxView = [[LynxView alloc] initWithBuilderBlock:^(LynxViewBuilder *builder) {
    builder.config = config;
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
