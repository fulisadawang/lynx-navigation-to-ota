#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Lynx/LynxTemplateProvider.h>
#import <Lynx/LynxView.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * 用 Objective-C 保持 Lynx 4.0 官方 API 的原始调用形态，Swift 容器只面对稳定方法。
 */
@interface LynxNativeRuntime : NSObject

+ (void)bootstrap;

+ (LynxView *)makeViewWithProvider:(id<LynxTemplateProvider>)provider
                        screenSize:(CGSize)screenSize
                       globalProps:(NSDictionary<NSString *, id> *)globalProps
    NS_SWIFT_NAME(makeView(provider:screenSize:globalProps:));

+ (void)loadURL:(NSString *)url
       initData:(NSDictionary<NSString *, id> *)initData
         inView:(LynxView *)lynxView
    NS_SWIFT_NAME(load(url:initData:in:));

+ (void)updateLayoutForView:(LynxView *)lynxView
                       size:(CGSize)size
    NS_SWIFT_NAME(updateLayout(view:size:));

+ (void)updateGlobalProps:(NSDictionary<NSString *, id> *)globalProps
                   inView:(LynxView *)lynxView
    NS_SWIFT_NAME(updateGlobalProps(_:in:));

@end

NS_ASSUME_NONNULL_END
