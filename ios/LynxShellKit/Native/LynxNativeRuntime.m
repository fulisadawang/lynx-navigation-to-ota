#import "LynxNativeRuntime.h"

#import <Lynx/LynxConfig.h>
#import <Lynx/LynxEnv.h>
#import <Lynx/LynxTemplateData.h>
#import <SDWebImage/SDWebImage.h>
#import <SDWebImageWebPCoder/SDWebImageWebPCoder.h>

// XElement 4.0 全量组件的公开头文件。
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

// Swift Module 与 Provider 会出现在 CocoaPods Target 自动生成的接口头中。
// 条件分支兼容 framework 与 development pod 两种 Header 搜索路径。
#if __has_include(<LynxShellKit/LynxShellKit-Swift.h>)
#import <LynxShellKit/LynxShellKit-Swift.h>
#else
#import "LynxShellKit-Swift.h"
#endif

@implementation LynxNativeRuntime

+ (void)bootstrap {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    // Image Service 使用 WebP 时必须提前注册 coder。
    SDImageWebPCoder *webPCoder = [SDImageWebPCoder sharedCoder];
    [[SDImageCodersManager sharedManager] addCoder:webPCoder];

    // XElement/Behavior 使用 LYNX_LAZY_REGISTER_* 宏完成全量懒注册。
    // Podfile 已显式包含 Behavior 及全部九个组件 subspec，宿主无需重复注册 UI 类。

    // 与 Lynx 4.0 Explorer 一致：先拿到 LynxEnv，再准备全局 Config。
    LynxEnv *env = [LynxEnv sharedInstance];
    LynxConfig *globalConfig =
        [[LynxConfig alloc] initWithProvider:[[ShellTemplateProvider alloc] init]];
    [globalConfig registerModule:LynxShellModule.class];
    [env prepareConfig:globalConfig];
  });
}

+ (LynxView *)makeViewWithProvider:(id<LynxTemplateProvider>)provider
                        screenSize:(CGSize)screenSize
                       globalProps:(NSDictionary<NSString *, id> *)globalProps {
  LynxConfig *config = [[LynxConfig alloc] initWithProvider:provider];
  [config registerModule:LynxShellModule.class];

  LynxView *lynxView = [[LynxView alloc] initWithBuilderBlock:^(LynxViewBuilder *builder) {
    builder.config = config;
    builder.screenSize = screenSize;
    builder.fontScale = 1.0;
  }];

  lynxView.preferredLayoutWidth = screenSize.width;
  lynxView.preferredLayoutHeight = screenSize.height;
  lynxView.layoutWidthMode = LynxViewSizeModeExact;
  lynxView.layoutHeightMode = LynxViewSizeModeExact;
  lynxView.frame = CGRectMake(0, 0, screenSize.width, screenSize.height);

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
  lynxView.preferredLayoutWidth = size.width;
  lynxView.preferredLayoutHeight = size.height;
  lynxView.frame = CGRectMake(0, 0, size.width, size.height);
  [lynxView triggerLayout];
}

+ (void)updateGlobalProps:(NSDictionary<NSString *, id> *)globalProps
                   inView:(LynxView *)lynxView {
  LynxTemplateData *templateData =
      [[LynxTemplateData alloc] initWithDictionary:globalProps ?: @{}];
  [lynxView updateGlobalPropsWithTemplateData:templateData];
}

@end
