#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class LynxConfig;

/**
 * 地图模块的宿主接入面。
 *
 * Shell 只负责在创建 LynxConfig 时调用注册方法，以及在宿主隐私弹窗完成后
 * 注入 Key/同意状态；地图 Element、AMap Provider、Search 和 Location 实现
 * 都保留在 LynxMapKit 内部。
 */
@interface LynxMapModuleRuntime : NSObject

+ (void)bootstrapWithAPIKey:(nullable NSString *)apiKey
               privacyAgreed:(BOOL)privacyAgreed;

+ (void)configureAMapWithAPIKey:(nullable NSString *)apiKey
                   privacyAgreed:(BOOL)privacyAgreed
    NS_SWIFT_NAME(configureAMap(apiKey:privacyAgreed:));

+ (void)updateAMapPrivacyAgreed:(BOOL)privacyAgreed
    NS_SWIFT_NAME(updateAMapPrivacyAgreed(_:));

+ (BOOL)isAMapPrivacyAgreed;

+ (void)registerModulesIntoConfig:(LynxConfig *)config;
+ (void)registerUIElementsIntoConfig:(LynxConfig *)config;

@end

NS_ASSUME_NONNULL_END
