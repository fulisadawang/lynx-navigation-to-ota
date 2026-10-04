#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Lynx/LynxTemplateProvider.h>
#import <Lynx/LynxView.h>
#import <Lynx/LynxContext.h>
#import <Lynx/LynxTemplateResourceFetcher.h>
#import <Lynx/LynxGenericResourceFetcher.h>
#import <Lynx/LynxMediaResourceFetcher.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^LynxLocalResolveBlock)(NSString *, LynxGenericResourceCompletionBlock);
typedef NSURL *_Nullable (^LynxLocalURLBlock)(NSString *);

/** 每个 View 独立捕获代码快照，Lynx 的资源 request 本身不提供页面身份。 */
@interface LynxLocalResourceFetcher : NSObject <LynxTemplateResourceFetcher, LynxGenericResourceFetcher, LynxMediaResourceFetcher>
- (instancetype)initWithProvider:(id<LynxTemplateProvider>)provider
                         resolver:(LynxLocalResolveBlock)resolver
                         localURL:(LynxLocalURLBlock)localURL
    NS_SWIFT_NAME(init(provider:resolver:localURL:));
- (void)cancel;
@end

/**
 * 用 Objective-C 保持 Lynx 4.1 官方 API 的原始调用形态，Swift 容器只面对稳定方法。
 */
@interface LynxNativeRuntime : NSObject

+ (void)bootstrap;

/** 宿主额外模块在首个 LynxView 创建前安装；每个 View 的独立 Config 都会注册。 */
+ (void)registerNativeModule:(Class)moduleClass
    NS_SWIFT_NAME(registerNativeModule(_:));

/** 当前 SDK 不会自动销毁自定义 Module，宿主显式提供对应 Context 的释放入口。 */
+ (void)registerNativeModule:(Class)moduleClass
              onViewDestroy:(nullable void (^)(LynxContext *))handler
    NS_SWIFT_NAME(registerNativeModule(_:onViewDestroy:));
+ (void)destroyView:(LynxView *)view NS_SWIFT_NAME(destroy(view:));

+ (LynxView *)makeViewWithProvider:(id<LynxTemplateProvider>)provider
                        screenSize:(CGSize)screenSize
                       globalProps:(NSDictionary<NSString *, id> *)globalProps
    NS_SWIFT_NAME(makeView(provider:screenSize:globalProps:));

+ (LynxView *)makeViewWithProvider:(id<LynxTemplateProvider>)provider
                        screenSize:(CGSize)screenSize
                      viewportSize:(CGSize)viewportSize
                       globalProps:(NSDictionary<NSString *, id> *)globalProps
    NS_SWIFT_NAME(makeView(provider:screenSize:viewportSize:globalProps:));

+ (LynxView *)makeViewWithProvider:(id<LynxTemplateProvider>)provider
                  resourceFetcher:(nullable LynxLocalResourceFetcher *)resourceFetcher
                       screenSize:(CGSize)screenSize
                     viewportSize:(CGSize)viewportSize
                      globalProps:(NSDictionary<NSString *, id> *)globalProps
    NS_SWIFT_NAME(makeView(provider:resourceFetcher:screenSize:viewportSize:globalProps:));

+ (void)loadURL:(NSString *)url
       initData:(NSDictionary<NSString *, id> *)initData
         inView:(LynxView *)lynxView
    NS_SWIFT_NAME(load(url:initData:in:));

+ (void)updateLayoutForView:(LynxView *)lynxView
                       size:(CGSize)size
    NS_SWIFT_NAME(updateLayout(view:size:));

+ (void)updateLayoutForView:(LynxView *)lynxView
                        size:(CGSize)size
                  screenSize:(CGSize)screenSize
    NS_SWIFT_NAME(updateLayout(view:size:screenSize:));

/**
 * 更新 Lynx 4.1 的 prefers-color-scheme；调用方必须在主线程执行。
 * Swift 使用 Bool 避免把平台枚举值泄露到壳层，Objective-C 内部再映射为 LynxColorScheme。
 */
+ (void)updateColorSchemeForView:(LynxView *)lynxView
                         darkMode:(BOOL)darkMode
    NS_SWIFT_NAME(updateColorScheme(for:darkMode:));

+ (void)updateGlobalProps:(NSDictionary<NSString *, id> *)globalProps
                   inView:(LynxView *)lynxView
    NS_SWIFT_NAME(updateGlobalProps(_:in:));

@end

NS_ASSUME_NONNULL_END
