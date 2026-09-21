#import "LynxMapModuleRuntime.h"

#import "NativeElements/LynxMapElementContract.h"
#import "NativeElements/LynxMapUI.h"
#import "NativeElements/Providers/LynxAMapProviderAdapter.h"

#import <AMapFoundationKit/AMapServices.h>
#import <AMapLocationKit/AMapLocationManager.h>
#import <Lynx/LynxConfig.h>

@implementation LynxMapModuleRuntime

+ (void)installAdapterFactory {
  [LynxMapProviderRegistry setAdapterFactory:^id<LynxMapProviderAdapter> {
    return [[LynxAMapProviderAdapter alloc] init];
  }];
}

+ (void)bootstrapWithAPIKey:(NSString *)apiKey privacyAgreed:(BOOL)privacyAgreed {
  [self installAdapterFactory];
  [self configureAMapWithAPIKey:apiKey privacyAgreed:privacyAgreed];
}

+ (void)configureAMapWithAPIKey:(NSString *)apiKey privacyAgreed:(BOOL)privacyAgreed {
  [self installAdapterFactory];
  if ([apiKey isKindOfClass:NSString.class] && apiKey.length > 0 &&
      [apiKey rangeOfString:@"$("].location == NSNotFound) {
    [AMapServices sharedServices].apiKey = apiKey;
  }
  [AMapLocationManager updatePrivacyShow:AMapPrivacyShowStatusDidShow
                            privacyInfo:AMapPrivacyInfoStatusDidContain];
  [AMapLocationManager updatePrivacyAgree:privacyAgreed ? AMapPrivacyAgreeStatusDidAgree
                                                  : AMapPrivacyAgreeStatusNotAgree];
  LynxMapProviderConfiguration *current = [LynxMapProviderRegistry defaultConfiguration];
  LynxMapProviderConfiguration *configuration =
      [[LynxMapProviderConfiguration alloc] initWithProviderKey:apiKey
                                                  privacyAgreed:privacyAgreed
                                                  initialCamera:current.initialCamera];
  [LynxMapProviderRegistry setDefaultConfiguration:configuration];
}

+ (BOOL)isAMapPrivacyAgreed {
  return [LynxMapProviderRegistry defaultConfiguration].privacyAgreed;
}

+ (void)updateAMapPrivacyAgreed:(BOOL)privacyAgreed {
  LynxMapProviderConfiguration *current = [LynxMapProviderRegistry defaultConfiguration];
  [self configureAMapWithAPIKey:current.providerKey privacyAgreed:privacyAgreed];
}

+ (void)registerModulesIntoConfig:(LynxConfig *)config {
  Class locationModuleClass = NSClassFromString(@"LynxMapLocationModule");
  if (locationModuleClass != Nil) {
    [config registerModule:locationModuleClass];
  }
  Class searchModuleClass = NSClassFromString(@"LynxMapSearchModule");
  if (searchModuleClass != Nil) {
    [config registerModule:searchModuleClass];
  }
}

+ (void)registerUIElementsIntoConfig:(LynxConfig *)config {
  [config registerUI:LynxMapUI.class withName:@"lynx-map"];
}

@end
