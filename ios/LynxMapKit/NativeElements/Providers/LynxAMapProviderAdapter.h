// Lynx lynx-map 的高德 iOS provider adapter。
//
// 公开头文件只导出 neutral adapter 类型。MAMapView、MAAnnotation 和 MAPolyline
// 均留在实现文件中，宿主需要在包含 AMap Pod 的 target 中注册该 adapter factory。

#import "../LynxMapElementContract.h"

NS_ASSUME_NONNULL_BEGIN

@interface LynxAMapProviderAdapter : NSObject <LynxMapProviderAdapter>
@end

NS_ASSUME_NONNULL_END
