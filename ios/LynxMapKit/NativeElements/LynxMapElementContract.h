// Lynx 4.1 `lynx-map` 的 provider-neutral 合约。
//
// 这里不导入任何地图厂商 SDK。宿主通过 LynxMapProviderRegistry 注入一个“每个 Element
// 新建一个实例”的 adapter；缺省 adapter 明确返回 unavailable，避免 SDK、Key 或隐私配置
// 高德 adapter 通过条件编译接入 AMap3DMap 11.2.100；未链接 SDK 时才返回明确 unavailable。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const LynxMapProviderErrorDomain;

typedef NS_ENUM(NSInteger, LynxMapProviderErrorCode) {
  LynxMapProviderErrorUnavailable = 1,
  LynxMapProviderErrorMissingAPIKey,
  LynxMapProviderErrorPrivacyNotConfigured,
  LynxMapProviderErrorInvalidConfiguration,
  LynxMapProviderErrorInvalidOperation,
  LynxMapProviderErrorUnsupportedCapability,
  LynxMapProviderErrorCancelled,
};

/// adapter 声明的能力只描述它自己能兑现的语义，不代表跨厂商行为完全一致。
/// 例如高德的矢量 overlay 只有 AboveRoads/AboveLabels 两级及级内顺序，不能承诺与
/// marker 的 zIndex 形成一个全局排序；adapter 应在能力矩阵中区分这两者。
typedef NS_OPTIONS(NSUInteger, LynxMapProviderCapabilities) {
  LynxMapProviderCapabilityCamera = 1 << 0,
  LynxMapProviderCapabilityFitBounds = 1 << 1,
  LynxMapProviderCapabilityMapTap = 1 << 2,
  LynxMapProviderCapabilityMarkerTap = 1 << 3,
  LynxMapProviderCapabilityRegionChange = 1 << 4,
  LynxMapProviderCapabilityMarkers = 1 << 5,
  LynxMapProviderCapabilityPolylines = 1 << 6,
  LynxMapProviderCapabilityLayerVisibility = 1 << 7,
  LynxMapProviderCapabilityLayerOpacity = 1 << 8,
  LynxMapProviderCapabilityLayerZIndexWithinTier = 1 << 9,
  LynxMapProviderCapabilityMarkerZIndex = 1 << 10,
  LynxMapProviderCapabilityPauseResume = 1 << 11,
  LynxMapProviderCapabilityTrafficLayer = 1 << 12,
  LynxMapProviderCapabilityCamera3D = 1 << 13,
  LynxMapProviderCapabilityGestureOptions = 1 << 14,
  LynxMapProviderCapabilityMapControls = 1 << 15,
  LynxMapProviderCapabilityMarkerSelection = 1 << 16,
  LynxMapProviderCapabilityMarkerLongPress = 1 << 17,
  LynxMapProviderCapabilityCoordinateConversion = 1 << 18,
  LynxMapProviderCapabilityLongPress = 1 << 19,
  LynxMapProviderCapabilityMarkerIcon = 1 << 20,
  LynxMapProviderCapabilityMarkerView = 1 << 21,
  LynxMapProviderCapabilityMassPoints = 1 << 22,
};

/// 三端页面只使用这个无厂商对象的数据模型；adapter 可以在内部转换成高德对象。
@interface LynxMapCoordinate : NSObject <NSCopying>

@property(nonatomic, readonly) double latitude;
@property(nonatomic, readonly) double longitude;

- (instancetype)initWithLatitude:(double)latitude longitude:(double)longitude;
+ (nullable instancetype)coordinateWithObject:(id)object error:(NSError * _Nullable * _Nullable)error;
- (NSDictionary<NSString *, NSNumber *> *)dictionaryValue;

@end

/// camera 状态既可作为 Element prop，也可作为 moveCamera 的部分更新请求。
@interface LynxMapCamera : NSObject <NSCopying>

@property(nonatomic, readonly, nullable) LynxMapCoordinate *center;
@property(nonatomic, readonly, nullable) NSNumber *zoom;
/// 顺时针 bearing，范围 [0, 360)。对应 AMap rotationDegree。
@property(nonatomic, readonly, nullable) NSNumber *bearing;
/// 相机俯视角，范围 [0, 60]。对应 AMap cameraDegree。
@property(nonatomic, readonly, nullable) NSNumber *pitch;
/// 归一化 screen anchor，字典形如 {x: 0.5, y: 0.5}。
@property(nonatomic, readonly, nullable) NSDictionary<NSString *, NSNumber *> *anchor;
@property(nonatomic, readonly) BOOL hasCenter;
@property(nonatomic, readonly) BOOL hasZoom;
@property(nonatomic, readonly) BOOL hasBearing;
@property(nonatomic, readonly) BOOL hasPitch;
@property(nonatomic, readonly) BOOL hasAnchor;

- (instancetype)initWithCenter:(nullable LynxMapCoordinate *)center
                           zoom:(nullable NSNumber *)zoom;
- (instancetype)initWithCenter:(nullable LynxMapCoordinate *)center
                           zoom:(nullable NSNumber *)zoom
                        bearing:(nullable NSNumber *)bearing
                           pitch:(nullable NSNumber *)pitch
                          anchor:(nullable NSDictionary<NSString *, NSNumber *> *)anchor;
+ (nullable instancetype)cameraWithObject:(id)object error:(NSError * _Nullable * _Nullable)error;
- (NSDictionary<NSString *, id> *)dictionaryValue;

@end

@interface LynxMapMarker : NSObject <NSCopying>

@property(nonatomic, readonly, copy) NSString *identifier;
@property(nonatomic, readonly) LynxMapCoordinate *coordinate;
@property(nonatomic, readonly, copy, nullable) NSString *title;
@property(nonatomic, readonly, copy, nullable) NSString *subtitle;
/// 可序列化的 HTTPS 图片配置：uri、width、height、anchor、cornerRadius。
@property(nonatomic, readonly, copy, nullable) NSDictionary<NSString *, id> *icon;
/// 可序列化的原生 Marker View 样式：text、尺寸、颜色和圆角。
@property(nonatomic, readonly, copy, nullable) NSDictionary<NSString *, id> *viewConfiguration;
@property(nonatomic, readonly) BOOL visible;
@property(nonatomic, readonly) BOOL selected;
@property(nonatomic, readonly) BOOL draggable;
@property(nonatomic, readonly) double opacity;
@property(nonatomic, readonly) NSInteger zIndex;

+ (nullable instancetype)markerWithObject:(id)object
                                     index:(NSUInteger)index
                                     error:(NSError * _Nullable * _Nullable)error;

@end

@interface LynxMapPolyline : NSObject <NSCopying>

@property(nonatomic, readonly, copy) NSString *identifier;
@property(nonatomic, readonly, copy) NSArray<LynxMapCoordinate *> *points;
@property(nonatomic, readonly) BOOL visible;
@property(nonatomic, readonly) double opacity;
@property(nonatomic, readonly) CGFloat width;
@property(nonatomic, readonly, copy, nullable) NSString *color;
@property(nonatomic, readonly) NSInteger zIndex;

+ (nullable instancetype)polylineWithObject:(id)object
                                       index:(NSUInteger)index
                                       error:(NSError * _Nullable * _Nullable)error;

@end

@interface LynxMapMassPoint : NSObject <NSCopying>

@property(nonatomic, readonly, copy) NSString *identifier;
@property(nonatomic, readonly) LynxMapCoordinate *coordinate;
@property(nonatomic, readonly, copy, nullable) NSString *title;
@property(nonatomic, readonly, copy, nullable) NSString *subtitle;

+ (nullable instancetype)massPointWithObject:(id)object
                                        index:(NSUInteger)index
                                        error:(NSError * _Nullable * _Nullable)error;

@end

@interface LynxMapLayerState : NSObject <NSCopying>

@property(nonatomic, readonly) BOOL visible;
@property(nonatomic, readonly) double opacity;
@property(nonatomic, readonly) NSInteger zIndex;
@property(nonatomic, readonly, copy) NSString *mapType;
@property(nonatomic, readonly) BOOL trafficEnabled;

- (instancetype)initWithVisible:(BOOL)visible
                         opacity:(double)opacity
                          zIndex:(NSInteger)zIndex;
- (instancetype)initWithVisible:(BOOL)visible
                         opacity:(double)opacity
                          zIndex:(NSInteger)zIndex
                         mapType:(NSString *)mapType
                  trafficEnabled:(BOOL)trafficEnabled;

@end

/// MAMapView 的可序列化交互/控件选项；不把 UIKit 控件对象跨 Lynx 边界。
@interface LynxMapViewOptions : NSObject <NSCopying>

@property(nonatomic, readonly) BOOL zoomEnabled;
@property(nonatomic, readonly) BOOL scrollEnabled;
@property(nonatomic, readonly) BOOL rotateEnabled;
@property(nonatomic, readonly) BOOL rotateCameraEnabled;
@property(nonatomic, readonly) BOOL showsCompass;
@property(nonatomic, readonly) BOOL showsScale;
@property(nonatomic, readonly) BOOL showsLabels;
@property(nonatomic, readonly) BOOL showsBuildings;
@property(nonatomic, readonly) BOOL touchPOIEnabled;

- (instancetype)initWithZoomEnabled:(BOOL)zoomEnabled
                       scrollEnabled:(BOOL)scrollEnabled
                       rotateEnabled:(BOOL)rotateEnabled
                 rotateCameraEnabled:(BOOL)rotateCameraEnabled
                       showsCompass:(BOOL)showsCompass
                         showsScale:(BOOL)showsScale
                        showsLabels:(BOOL)showsLabels
                     showsBuildings:(BOOL)showsBuildings
                     touchPOIEnabled:(BOOL)touchPOIEnabled;

@end

@interface LynxMapBounds : NSObject <NSCopying>

@property(nonatomic, readonly) LynxMapCoordinate *southWest;
@property(nonatomic, readonly) LynxMapCoordinate *northEast;

- (instancetype)initWithSouthWest:(LynxMapCoordinate *)southWest
                          northEast:(LynxMapCoordinate *)northEast;
+ (nullable instancetype)boundsWithObject:(id)object error:(NSError * _Nullable * _Nullable)error;

@end

/// 不在 Lynx Bundle/Element props 中保存 Key。providerKey 与隐私状态只能由宿主注入到这个配置，
/// adapter 不得打印或放入 Lynx 事件；页面只能读取脱敏后的能力快照。
@interface LynxMapProviderConfiguration : NSObject <NSCopying>

@property(nonatomic, readonly, copy, nullable) NSString *providerKey;
@property(nonatomic, readonly) BOOL privacyAgreed;
@property(nonatomic, readonly, nullable) LynxMapCamera *initialCamera;

- (instancetype)initWithProviderKey:(nullable NSString *)providerKey
                       privacyAgreed:(BOOL)privacyAgreed
                       initialCamera:(nullable LynxMapCamera *)initialCamera;

@end

@protocol LynxMapProviderMapView;

@protocol LynxMapProviderEventSink <NSObject>

- (void)mapProviderDidBecomeReadyForMapView:(id<LynxMapProviderMapView>)mapView;
- (void)mapProvider:(id<LynxMapProviderMapView>)mapView didFailWithError:(NSError *)error;
- (void)mapProvider:(id<LynxMapProviderMapView>)mapView
      didTapAtCoordinate:(LynxMapCoordinate *)coordinate;
- (void)mapProvider:(id<LynxMapProviderMapView>)mapView
       didTapMarkerWithIdentifier:(NSString *)identifier
                       coordinate:(LynxMapCoordinate *)coordinate;
- (void)mapProvider:(id<LynxMapProviderMapView>)mapView
   didTapMassPointWithIdentifier:(NSString *)identifier
                       coordinate:(LynxMapCoordinate *)coordinate;
- (void)mapProvider:(id<LynxMapProviderMapView>)mapView
       didSelectMarkerWithIdentifier:(NSString *)identifier
                           coordinate:(LynxMapCoordinate *)coordinate;
- (void)mapProvider:(id<LynxMapProviderMapView>)mapView
     didDeselectMarkerWithIdentifier:(NSString *)identifier
                             coordinate:(LynxMapCoordinate *)coordinate;
- (void)mapProvider:(id<LynxMapProviderMapView>)mapView
       didDragMarkerWithIdentifier:(NSString *)identifier
                         coordinate:(LynxMapCoordinate *)coordinate
                              phase:(NSString *)phase;
- (void)mapProvider:(id<LynxMapProviderMapView>)mapView
       didLongPressAtCoordinate:(LynxMapCoordinate *)coordinate;
- (void)mapProvider:(id<LynxMapProviderMapView>)mapView
      didChangeRegionWithCenter:(nullable LynxMapCoordinate *)center
                            zoom:(nullable NSNumber *)zoom
                          reason:(nullable NSString *)reason;

@end

/// 只允许暴露渲染所需 UIView；高德 MAMapView、MAAnnotation、MAPolyline 等对象不能进入
/// Lynx 事件 params 或 UI Method callback。overlayView 用于承载厂商需要置于 Metal map layer
/// 之上的 marker/callout 容器，仍由 adapter 私有管理。
@protocol LynxMapProviderMapView <NSObject>

@property(nonatomic, readonly) UIView *view;
@property(nonatomic, readonly, nullable) UIView *overlayView;

@end

typedef void (^LynxMapProviderOperationCompletion)(NSError * _Nullable error);

@protocol LynxMapProviderAdapter <NSObject>

@property(nonatomic, readonly, copy) NSString *providerIdentifier;
@property(nonatomic, readonly) BOOL available;
@property(nonatomic, readonly) LynxMapProviderCapabilities capabilities;
@property(nonatomic, readonly, nullable) NSError *availabilityError;

- (nullable id<LynxMapProviderMapView>)createMapViewWithConfiguration:(LynxMapProviderConfiguration *)configuration
                                                            eventSink:(id<LynxMapProviderEventSink>)eventSink
                                                                error:(NSError * _Nullable * _Nullable)error;
- (void)startMapView:(id<LynxMapProviderMapView>)mapView;
- (void)setMapView:(id<LynxMapProviderMapView>)mapView paused:(BOOL)paused;
- (void)mapViewDidLayout:(id<LynxMapProviderMapView>)mapView;

- (BOOL)updateMapView:(id<LynxMapProviderMapView>)mapView
       withConfiguration:(LynxMapProviderConfiguration *)configuration
                   error:(NSError * _Nullable * _Nullable)error;
- (BOOL)updateMapView:(id<LynxMapProviderMapView>)mapView
               camera:(nullable LynxMapCamera *)camera
               markers:(NSArray<LynxMapMarker *> *)markers
             polylines:(NSArray<LynxMapPolyline *> *)polylines
            massPoints:(NSArray<LynxMapMassPoint *> *)massPoints
            layerState:(LynxMapLayerState *)layerState
         viewOptions:(LynxMapViewOptions *)viewOptions
               error:(NSError * _Nullable * _Nullable)error;

- (nullable LynxMapCamera *)currentCameraForMapView:(id<LynxMapProviderMapView>)mapView
                                               error:(NSError * _Nullable * _Nullable)error;

/// 把经纬度投影到 MapView 本地坐标，供 Lynx sibling overlay 使用。
- (nullable NSDictionary<NSString *, NSNumber *> *)screenPointForCoordinate:(LynxMapCoordinate *)coordinate
                                                                      mapView:(id<LynxMapProviderMapView>)mapView
                                                                        error:(NSError * _Nullable * _Nullable)error;

- (void)moveCamera:(LynxMapCamera *)camera
          mapView:(id<LynxMapProviderMapView>)mapView
          animated:(BOOL)animated
        completion:(LynxMapProviderOperationCompletion)completion;
- (void)fitBounds:(LynxMapBounds *)bounds
          mapView:(id<LynxMapProviderMapView>)mapView
          padding:(UIEdgeInsets)padding
         animated:(BOOL)animated
       completion:(LynxMapProviderOperationCompletion)completion;
- (void)setMarkerWithIdentifier:(NSString *)identifier
                         selected:(BOOL)selected
                         mapView:(id<LynxMapProviderMapView>)mapView
                         animated:(BOOL)animated
                       completion:(LynxMapProviderOperationCompletion)completion;
- (void)showMarkersWithIdentifiers:(NSArray<NSString *> *)identifiers
                           mapView:(id<LynxMapProviderMapView>)mapView
                           padding:(UIEdgeInsets)padding
                          animated:(BOOL)animated
                        completion:(LynxMapProviderOperationCompletion)completion;

/// 释放顺序由 Element 统一协调：先取消任务，再移除 listener/overlay/icon cache，最后销毁 MapView。
- (void)cancelPendingOperationsForMapView:(id<LynxMapProviderMapView>)mapView;
- (void)removeAllListenersFromMapView:(id<LynxMapProviderMapView>)mapView;
- (void)removeAllOverlaysFromMapView:(id<LynxMapProviderMapView>)mapView;
- (void)clearIconCacheForMapView:(id<LynxMapProviderMapView>)mapView;
- (void)destroyMapView:(id<LynxMapProviderMapView>)mapView;

@end

/// 工厂必须返回每个 `lynx-map` 独立的 adapter 实例；此处只保存工厂，不保存任何 MapView、
/// annotation、overlay 或 listener 集合。
typedef id<LynxMapProviderAdapter> _Nullable (^LynxMapProviderAdapterFactory)(void);

@interface LynxMapProviderRegistry : NSObject

+ (void)setAdapterFactory:(nullable LynxMapProviderAdapterFactory)factory;
+ (void)setDefaultConfiguration:(nullable LynxMapProviderConfiguration *)configuration;
+ (LynxMapProviderConfiguration *)defaultConfiguration;
+ (id<LynxMapProviderAdapter>)makeAdapter;

@end

/// 缺少 SDK/Key/隐私配置时的显式默认实现。它绝不会创建 UIView 或发送 ready。
@interface LynxMapUnavailableProviderAdapter : NSObject <LynxMapProviderAdapter>
@end

FOUNDATION_EXPORT NSError *LynxMapMakeProviderError(LynxMapProviderErrorCode code,
                                                     NSString *message);
FOUNDATION_EXPORT NSString *LynxMapProviderErrorName(NSError *error);
FOUNDATION_EXPORT NSString *LynxMapProviderSafeErrorMessage(NSError *error);

/// 导出给静态检查和 adapter 实现使用的边界；所有 Element 实例共享上限值，不共享业务对象。
FOUNDATION_EXPORT const NSUInteger LynxMapMaximumMarkerCount;
FOUNDATION_EXPORT const NSUInteger LynxMapMaximumIdentifierLength;
FOUNDATION_EXPORT const NSUInteger LynxMapMaximumMarkerTextLength;
FOUNDATION_EXPORT const NSUInteger LynxMapMaximumMarkerIconURLLength;
FOUNDATION_EXPORT const NSUInteger LynxMapMaximumColorLength;
FOUNDATION_EXPORT const NSUInteger LynxMapMaximumPolylineCount;
FOUNDATION_EXPORT const NSUInteger LynxMapMaximumPolylinePointCount;
FOUNDATION_EXPORT const NSUInteger LynxMapMaximumTotalPolylinePointCount;
FOUNDATION_EXPORT const NSUInteger LynxMapMaximumMassPointCount;
FOUNDATION_EXPORT const double LynxMapMinimumZoom;
FOUNDATION_EXPORT const double LynxMapMaximumZoom;
FOUNDATION_EXPORT const double LynxMapMaximumPolylineWidth;
FOUNDATION_EXPORT const double LynxMapMaximumPadding;
FOUNDATION_EXPORT const NSInteger LynxMapMaximumZIndexMagnitude;

NS_ASSUME_NONNULL_END
