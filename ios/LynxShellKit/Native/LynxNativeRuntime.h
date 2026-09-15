#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Lynx/LynxTemplateProvider.h>
#import <Lynx/LynxView.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * 用 Objective-C 保持 Lynx 4.1 官方 API 的原始调用形态，Swift 容器只面对稳定方法。
 */
@interface LynxNativeRuntime : NSObject

+ (void)bootstrap;

+ (LynxView *)makeViewWithProvider:(id<LynxTemplateProvider>)provider
                        screenSize:(CGSize)screenSize
                       globalProps:(NSDictionary<NSString *, id> *)globalProps
    NS_SWIFT_NAME(makeView(provider:screenSize:globalProps:));

+ (LynxView *)makeViewWithProvider:(id<LynxTemplateProvider>)provider
                        screenSize:(CGSize)screenSize
                      viewportSize:(CGSize)viewportSize
                       globalProps:(NSDictionary<NSString *, id> *)globalProps
    NS_SWIFT_NAME(makeView(provider:screenSize:viewportSize:globalProps:));

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
