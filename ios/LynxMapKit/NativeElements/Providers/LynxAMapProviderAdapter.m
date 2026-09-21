#import "LynxAMapProviderAdapter.h"

#import <CoreLocation/CoreLocation.h>
#import <SDWebImage/SDWebImage.h>
#import <math.h>
#import <stdlib.h>
#import <stdint.h>
#import <string.h>

#if __has_include(<MAMapKit/MAMapKit.h>)
#define LYNX_HAS_AMAP_IOS 1
#import <MAMapKit/MAMapKit.h>
#else
#define LYNX_HAS_AMAP_IOS 0
#endif

#if LYNX_HAS_AMAP_IOS

@interface LynxAMapMapViewBox : NSObject <LynxMapProviderMapView>

@property(nonatomic, strong) MAMapView *mapView;

@end

@implementation LynxAMapMapViewBox

- (UIView *)view {
  return self.mapView;
}

- (UIView *)overlayView {
  // LynxMapUI 的外层容器负责把 Lynx sibling overlay 放到 MapView 上方。
  // 高德 annotation/overlay 对象不从这个接口泄漏。
  return nil;
}

- (void)dealloc {
  self.mapView.delegate = nil;
}

@end

@interface LynxAMapAnnotation : MAPointAnnotation

@property(nonatomic, copy) NSString *lynxIdentifier;
@property(nonatomic, assign) BOOL lynxVisible;
@property(nonatomic, assign) BOOL lynxSelected;
@property(nonatomic, assign) BOOL lynxDraggable;
@property(nonatomic, assign) CGFloat lynxOpacity;
@property(nonatomic, assign) NSInteger lynxZIndex;
@property(nonatomic, copy, nullable) NSDictionary<NSString *, id> *lynxIcon;
@property(nonatomic, copy, nullable) NSDictionary<NSString *, id> *lynxViewConfiguration;

@end

@implementation LynxAMapAnnotation
@end

@interface LynxAMapMarkerView : MAAnnotationView

@property(nonatomic, strong) UIView *markerBackgroundView;
@property(nonatomic, strong) UIImageView *markerImageView;
@property(nonatomic, strong) UILabel *markerLabel;
@property(nonatomic, strong, nullable) id<SDWebImageOperation> imageOperation;
@property(nonatomic, copy, nullable) NSString *imageURI;

- (void)applyIcon:(nullable NSDictionary<NSString *, id> *)icon
             view:(nullable NSDictionary<NSString *, id> *)viewConfiguration
         selected:(BOOL)selected;

@end

static UIColor *LynxAMapColorFromHex(NSString *value, CGFloat alpha);

@implementation LynxAMapMarkerView

- (instancetype)initWithAnnotation:(id<MAAnnotation>)annotation
                    reuseIdentifier:(NSString *)reuseIdentifier {
  self = [super initWithAnnotation:annotation reuseIdentifier:reuseIdentifier];
  if (self != nil) {
    self.backgroundColor = UIColor.clearColor;
    self.canShowCallout = NO;
    self.markerBackgroundView = [[UIView alloc] initWithFrame:CGRectZero];
    self.markerBackgroundView.userInteractionEnabled = NO;
    [self addSubview:self.markerBackgroundView];
    self.markerImageView = [[UIImageView alloc] initWithFrame:CGRectZero];
    self.markerImageView.contentMode = UIViewContentModeScaleAspectFit;
    self.markerImageView.userInteractionEnabled = NO;
    [self.markerBackgroundView addSubview:self.markerImageView];
    self.markerLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.markerLabel.textAlignment = NSTextAlignmentCenter;
    self.markerLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.markerLabel.numberOfLines = 1;
    self.markerLabel.adjustsFontSizeToFitWidth = YES;
    self.markerLabel.minimumScaleFactor = .65;
    self.markerLabel.userInteractionEnabled = NO;
    [self.markerBackgroundView addSubview:self.markerLabel];
  }
  return self;
}

- (void)prepareForReuse {
  [super prepareForReuse];
  [self.imageOperation cancel];
  self.imageOperation = nil;
  self.imageURI = nil;
  self.markerImageView.image = nil;
  self.markerLabel.text = nil;
}

- (void)dealloc {
  [self.imageOperation cancel];
}

- (void)applyIcon:(NSDictionary<NSString *,id> *)icon
             view:(NSDictionary<NSString *,id> *)viewConfiguration
         selected:(BOOL)selected {
  [self.imageOperation cancel];
  self.imageOperation = nil;

  CGFloat width = [icon[@"width"] doubleValue] ?: [viewConfiguration[@"width"] doubleValue];
  CGFloat height = [icon[@"height"] doubleValue] ?: [viewConfiguration[@"height"] doubleValue];
  if (width < 1) width = 44;
  if (height < 1) height = 44;
  self.bounds = CGRectMake(0, 0, width, height);

  NSDictionary *anchor = icon[@"anchor"];
  CGFloat anchorX = anchor != nil ? [anchor[@"x"] doubleValue] : .5;
  CGFloat anchorY = anchor != nil ? [anchor[@"y"] doubleValue] : 1;
  self.centerOffset = CGPointMake((anchorX - .5) * width, (.5 - anchorY) * height);

  NSString *backgroundColor = viewConfiguration[@"backgroundColor"];
  self.markerBackgroundView.backgroundColor = viewConfiguration != nil
      ? LynxAMapColorFromHex(backgroundColor ?: @"#147EF5", 1)
      : UIColor.clearColor;
  self.markerBackgroundView.layer.cornerRadius = [viewConfiguration[@"cornerRadius"] doubleValue] ?: [icon[@"cornerRadius"] doubleValue];
  self.markerBackgroundView.layer.borderWidth = [viewConfiguration[@"borderWidth"] doubleValue];
  self.markerBackgroundView.layer.borderColor = LynxAMapColorFromHex(
      viewConfiguration[@"borderColor"] ?: (selected ? @"#FF6A3D" : @"#FFFFFF"), 1).CGColor;
  self.markerBackgroundView.layer.masksToBounds = YES;
  self.markerBackgroundView.frame = self.bounds;

  self.markerImageView.hidden = icon == nil;
  self.markerImageView.frame = self.markerBackgroundView.bounds;
  self.markerLabel.hidden = viewConfiguration[@"text"] == nil;
  self.markerLabel.text = viewConfiguration[@"text"];
  self.markerLabel.textColor = LynxAMapColorFromHex(viewConfiguration[@"foregroundColor"] ?: @"#FFFFFF", 1);
  self.markerLabel.frame = self.markerBackgroundView.bounds;

  NSString *uri = icon[@"uri"];
  self.imageURI = uri;
  if (uri.length == 0) {
    self.markerImageView.image = nil;
    return;
  }
  NSURL *url = [NSURL URLWithString:uri];
  if (url == nil) return;
  __weak LynxAMapMarkerView *weakSelf = self;
  self.imageOperation = [[SDWebImageManager sharedManager]
      loadImageWithURL:url
               options:SDWebImageRetryFailed
              context:nil
             progress:nil
            completed:^(UIImage * _Nullable image,
                        NSData * _Nullable data,
                        NSError * _Nullable error,
                        SDImageCacheType cacheType,
                        BOOL finished,
                        NSURL * _Nullable imageURL) {
    (void)data;
    (void)error;
    (void)cacheType;
    if (!finished || image == nil) return;
    dispatch_async(dispatch_get_main_queue(), ^{
      LynxAMapMarkerView *strongSelf = weakSelf;
      if (strongSelf != nil && [strongSelf.imageURI isEqualToString:imageURL.absoluteString]) {
        strongSelf.markerImageView.image = image;
      }
    });
  }];
}

@end

@interface LynxAMapPolyline : MAPolyline

@property(nonatomic, copy) NSString *lynxIdentifier;
@property(nonatomic, assign) BOOL lynxVisible;
@property(nonatomic, assign) CGFloat lynxOpacity;
@property(nonatomic, assign) CGFloat lynxWidth;
@property(nonatomic, copy, nullable) NSString *lynxColor;
@property(nonatomic, assign) NSInteger lynxZIndex;

@end

@implementation LynxAMapPolyline
@end

@interface LynxAMapMassPointOverlay : MAMultiPointOverlay

@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *identifiersByCustomID;

@end

@implementation LynxAMapMassPointOverlay
@end

#endif

@interface LynxAMapProviderAdapter ()

@property(nonatomic, readwrite, copy) NSString *providerIdentifier;
@property(nonatomic, readwrite) BOOL available;
@property(nonatomic, readwrite) LynxMapProviderCapabilities capabilities;
@property(nonatomic, readwrite, nullable) NSError *availabilityError;

#if LYNX_HAS_AMAP_IOS
@property(nonatomic, strong) LynxAMapMapViewBox *activeBox;
@property(nonatomic, weak) id<LynxMapProviderEventSink> eventSink;
@property(nonatomic, strong) NSMutableDictionary<NSString *, LynxAMapAnnotation *> *annotationsByID;
@property(nonatomic, strong) NSMutableDictionary<NSString *, LynxAMapPolyline *> *polylinesByID;
@property(nonatomic, strong) NSMutableDictionary<NSString *, MAPolylineRenderer *> *renderersByID;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *pathFingerprintsByID;
@property(nonatomic, strong, nullable) LynxAMapMassPointOverlay *massPointOverlay;
@property(nonatomic, strong, nullable) MAMultiPointOverlayRenderer *massPointRenderer;
@property(nonatomic, assign) uint64_t massPointFingerprint;
@property(nonatomic, copy) NSArray<NSString *> *orderedPolylineIDs;
@property(nonatomic, copy) LynxMapLayerState *layerState;
@property(nonatomic, assign) BOOL pendingReady;
@property(nonatomic, assign) BOOL readySent;
@property(nonatomic, assign) BOOL destroyed;
@property(nonatomic, copy, nullable) dispatch_block_t pendingLoadFailureTask;
#endif

@end

static BOOL LynxAMapStringIsUsable(NSString * _Nullable value) {
  return value.length > 0 && [value rangeOfString:@"$("].location == NSNotFound;
}

#if LYNX_HAS_AMAP_IOS

static BOOL LynxAMapIsCurrentBox(LynxAMapProviderAdapter *adapter,
                                 LynxAMapMapViewBox *box,
                                 MAMapView *mapView) {
  return !adapter.destroyed && adapter.activeBox == box && box.mapView == mapView && mapView != nil;
}

static LynxMapCoordinate *LynxAMapCoordinateFromCLLocation(CLLocationCoordinate2D coordinate) {
  if (!CLLocationCoordinate2DIsValid(coordinate) ||
      !isfinite(coordinate.latitude) || !isfinite(coordinate.longitude)) {
    return nil;
  }
  return [[LynxMapCoordinate alloc] initWithLatitude:coordinate.latitude
                                           longitude:coordinate.longitude];
}

static UIColor *LynxAMapColorFromHex(NSString *value, CGFloat alpha) {
  if (!LynxAMapStringIsUsable(value)) {
    return [UIColor colorWithRed:0.04 green:0.49 blue:0.98 alpha:alpha];
  }
  NSString *hex = [value stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if ([hex hasPrefix:@"#"]) {
    hex = [hex substringFromIndex:1];
  }
  unsigned long long parsed = 0;
  NSScanner *scanner = [NSScanner scannerWithString:hex];
  if (![scanner scanHexLongLong:&parsed] || scanner.isAtEnd == NO) {
    return [UIColor colorWithRed:0.04 green:0.49 blue:0.98 alpha:alpha];
  }
  CGFloat red = 0;
  CGFloat green = 0;
  CGFloat blue = 0;
  if (hex.length == 6) {
    red = ((parsed >> 16) & 0xff) / 255.0;
    green = ((parsed >> 8) & 0xff) / 255.0;
    blue = (parsed & 0xff) / 255.0;
  } else if (hex.length == 8) {
    alpha *= (parsed & 0xff) / 255.0;
    red = ((parsed >> 24) & 0xff) / 255.0;
    green = ((parsed >> 16) & 0xff) / 255.0;
    blue = ((parsed >> 8) & 0xff) / 255.0;
  } else {
    return [UIColor colorWithRed:0.04 green:0.49 blue:0.98 alpha:alpha];
  }
  return [UIColor colorWithRed:red green:green blue:blue alpha:alpha];
}

static MAMapType LynxAMapTypeFromString(NSString *value) {
  if ([value isEqualToString:@"satellite"]) return MAMapTypeSatellite;
  if ([value isEqualToString:@"night"]) return MAMapTypeStandardNight;
  if ([value isEqualToString:@"navi"]) return MAMapTypeNavi;
  if ([value isEqualToString:@"bus"]) return MAMapTypeBus;
  if ([value isEqualToString:@"navi-night"]) return MAMapTypeNaviNight;
  return MAMapTypeStandard;
}

static CGFloat LynxAMapClampedZoom(MAMapView *mapView, NSNumber *zoom) {
  CGFloat value = (CGFloat)zoom.doubleValue;
  CGFloat minimum = mapView.minZoomLevel;
  CGFloat maximum = mapView.maxZoomLevel;
  if (minimum > maximum) {
    return value;
  }
  return MIN(MAX(value, minimum), maximum);
}

static uint64_t LynxAMapPolylineFingerprint(LynxMapPolyline *polyline) {
  uint64_t hash = UINT64_C(1469598103934665603);
  for (LynxMapCoordinate *coordinate in polyline.points) {
    uint64_t latitudeBits = 0;
    uint64_t longitudeBits = 0;
    double latitude = coordinate.latitude;
    double longitude = coordinate.longitude;
    memcpy(&latitudeBits, &latitude, sizeof(latitudeBits));
    memcpy(&longitudeBits, &longitude, sizeof(longitudeBits));
    hash ^= latitudeBits;
    hash *= UINT64_C(1099511628211);
    hash ^= longitudeBits;
    hash *= UINT64_C(1099511628211);
  }
  hash ^= (uint64_t)polyline.points.count;
  hash *= UINT64_C(1099511628211);
  return hash;
}

static uint64_t LynxAMapMassPointFingerprint(NSArray<LynxMapMassPoint *> *points) {
  uint64_t hash = UINT64_C(1469598103934665603);
  for (LynxMapMassPoint *point in points) {
    hash ^= point.identifier.hash;
    hash *= UINT64_C(1099511628211);
    uint64_t latitudeBits = 0;
    uint64_t longitudeBits = 0;
    double latitude = point.coordinate.latitude;
    double longitude = point.coordinate.longitude;
    memcpy(&latitudeBits, &latitude, sizeof(latitudeBits));
    memcpy(&longitudeBits, &longitude, sizeof(longitudeBits));
    hash ^= latitudeBits;
    hash *= UINT64_C(1099511628211);
    hash ^= longitudeBits;
    hash *= UINT64_C(1099511628211);
    hash ^= point.title.hash;
    hash *= UINT64_C(1099511628211);
    hash ^= point.subtitle.hash;
    hash *= UINT64_C(1099511628211);
  }
  hash ^= (uint64_t)points.count;
  hash *= UINT64_C(1099511628211);
  return hash;
}

static UIImage *LynxAMapMassPointIcon(void) {
  static UIImage *icon;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    CGFloat size = 14.0;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
        initWithSize:CGSizeMake(size, size)];
    icon = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
      (void)context;
      [[UIColor colorWithRed:0.04 green:0.49 blue:0.98 alpha:1.0] setFill];
      [[UIColor whiteColor] setStroke];
      UIBezierPath *path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(1, 1, size - 2, size - 2)];
      path.lineWidth = 1.5;
      [path fill];
      [path stroke];
    }];
  });
  return icon;
}

static void LynxAMapSendRegionEvent(LynxAMapProviderAdapter *adapter,
                                    LynxAMapMapViewBox *box,
                                    BOOL userAction,
                                    NSString *phase) {
  MAMapView *mapView = box.mapView;
  if (!LynxAMapIsCurrentBox(adapter, box, mapView)) {
    return;
  }
  id<LynxMapProviderEventSink> sink = adapter.eventSink;
  LynxMapCoordinate *center = LynxAMapCoordinateFromCLLocation(mapView.centerCoordinate);
  if (sink != nil) {
    [sink mapProvider:box
        didChangeRegionWithCenter:center
                              zoom:@(mapView.zoomLevel)
                            reason:[NSString stringWithFormat:@"%@:%@",
                                                              userAction ? @"gesture" : @"api",
                                                              phase]];
  }
}

@interface LynxAMapProviderAdapter (MAMapViewDelegate) <MAMapViewDelegate>
@end

#endif

@implementation LynxAMapProviderAdapter

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _providerIdentifier = @"amap";
#if LYNX_HAS_AMAP_IOS
    _available = YES;
    _capabilities = LynxMapProviderCapabilityCamera |
                    LynxMapProviderCapabilityFitBounds |
                    LynxMapProviderCapabilityMapTap |
                    LynxMapProviderCapabilityMarkerTap |
                    LynxMapProviderCapabilityRegionChange |
                    LynxMapProviderCapabilityMarkers |
                    LynxMapProviderCapabilityPolylines |
                    LynxMapProviderCapabilityLayerVisibility |
                    LynxMapProviderCapabilityLayerOpacity |
                    LynxMapProviderCapabilityLayerZIndexWithinTier |
                    LynxMapProviderCapabilityMarkerZIndex |
                    LynxMapProviderCapabilityPauseResume |
                    LynxMapProviderCapabilityTrafficLayer |
                    LynxMapProviderCapabilityCamera3D |
                    LynxMapProviderCapabilityGestureOptions |
                    LynxMapProviderCapabilityMapControls |
                    LynxMapProviderCapabilityMarkerSelection |
                    LynxMapProviderCapabilityMarkerLongPress |
                    LynxMapProviderCapabilityMarkerIcon |
                    LynxMapProviderCapabilityMarkerView |
                    LynxMapProviderCapabilityMassPoints |
                    LynxMapProviderCapabilityLongPress;
    _annotationsByID = [NSMutableDictionary dictionary];
    _polylinesByID = [NSMutableDictionary dictionary];
    _renderersByID = [NSMutableDictionary dictionary];
    _pathFingerprintsByID = [NSMutableDictionary dictionary];
    _massPointFingerprint = 0;
    _orderedPolylineIDs = @[];
#else
    _available = NO;
    _capabilities = 0;
    _availabilityError = LynxMapMakeProviderError(
        LynxMapProviderErrorUnavailable, @"高德 iOS Map SDK 尚未链接。");
#endif
  }
  return self;
}

- (id<LynxMapProviderMapView>)createMapViewWithConfiguration:(LynxMapProviderConfiguration *)configuration
                                                    eventSink:(id<LynxMapProviderEventSink>)eventSink
                                                        error:(NSError * _Nullable * _Nullable)error {
#if !LYNX_HAS_AMAP_IOS
  if (error != NULL) {
    *error = self.availabilityError;
  }
  (void)configuration;
  (void)eventSink;
  return nil;
#else
  if (!LynxAMapStringIsUsable(configuration.providerKey)) {
    if (error != NULL) {
      *error = LynxMapMakeProviderError(LynxMapProviderErrorMissingAPIKey,
                                         @"高德 iOS Map SDK 缺少宿主 Key。");
    }
    return nil;
  }
  if (!configuration.privacyAgreed) {
    if (error != NULL) {
      *error = LynxMapMakeProviderError(LynxMapProviderErrorPrivacyNotConfigured,
                                         @"高德 iOS Map SDK 隐私配置未完成。");
    }
    return nil;
  }

  // 高德要求这些状态在 MAMapView 实例化之前设置；Key 只从宿主配置读取。
  [MAMapView updatePrivacyShow:AMapPrivacyShowStatusDidShow
                    privacyInfo:AMapPrivacyInfoStatusDidContain];
  [MAMapView updatePrivacyAgree:AMapPrivacyAgreeStatusDidAgree];
  [AMapServices sharedServices].apiKey = configuration.providerKey;
  [AMapServices sharedServices].enableHTTPS = YES;

  MAMapView *mapView = [[MAMapView alloc] initWithFrame:CGRectZero];
  mapView.delegate = self;
  mapView.maxRenderFrame = 60;
  mapView.isAllowDecreaseFrame = YES;
  mapView.showsCompass = NO;
  mapView.showsScale = NO;
  mapView.touchPOIEnabled = NO;
  mapView.zoomEnabled = YES;
  mapView.scrollEnabled = YES;
  mapView.rotateEnabled = YES;
  mapView.rotateCameraEnabled = YES;

  LynxAMapMapViewBox *box = [[LynxAMapMapViewBox alloc] init];
  box.mapView = mapView;
  self.activeBox = box;
  self.eventSink = eventSink;
  self.pendingReady = NO;
  self.readySent = NO;
  self.destroyed = NO;

  if (configuration.initialCamera.hasCenter) {
    mapView.centerCoordinate = (CLLocationCoordinate2D){
        configuration.initialCamera.center.latitude,
        configuration.initialCamera.center.longitude};
  }
  if (configuration.initialCamera.hasZoom) {
    mapView.zoomLevel = LynxAMapClampedZoom(mapView, configuration.initialCamera.zoom);
  }
  if (configuration.initialCamera.hasBearing) {
    mapView.rotationDegree = configuration.initialCamera.bearing.doubleValue;
  }
  if (configuration.initialCamera.hasPitch) {
    mapView.cameraDegree = MIN(MAX(configuration.initialCamera.pitch.doubleValue, 0.0), 60.0);
  }
  if (configuration.initialCamera.hasAnchor) {
    mapView.screenAnchor = CGPointMake(configuration.initialCamera.anchor[@"x"].doubleValue,
                                       configuration.initialCamera.anchor[@"y"].doubleValue);
  }
  return box;
#endif
}

- (void)startMapView:(id<LynxMapProviderMapView>)mapView {
#if LYNX_HAS_AMAP_IOS
  LynxAMapMapViewBox *box = (LynxAMapMapViewBox *)mapView;
  if (box == self.activeBox && box.mapView != nil) {
    [box.mapView setNeedsLayout];
  }
#else
  (void)mapView;
#endif
}

- (void)setMapView:(id<LynxMapProviderMapView>)mapView paused:(BOOL)paused {
#if LYNX_HAS_AMAP_IOS
  LynxAMapMapViewBox *box = (LynxAMapMapViewBox *)mapView;
  if (box == self.activeBox && box.mapView != nil) {
    box.mapView.renderringDisabled = paused;
  }
#else
  (void)mapView;
  (void)paused;
#endif
}

- (void)mapViewDidLayout:(id<LynxMapProviderMapView>)mapView {
#if LYNX_HAS_AMAP_IOS
  LynxAMapMapViewBox *box = (LynxAMapMapViewBox *)mapView;
  if (box != self.activeBox || box.mapView == nil) {
    return;
  }
  [box.mapView setNeedsLayout];
  if (self.pendingReady && !self.readySent &&
      box.mapView.bounds.size.width > 0 && box.mapView.bounds.size.height > 0) {
    self.pendingReady = NO;
    self.readySent = YES;
    [self.eventSink mapProviderDidBecomeReadyForMapView:box];
  }
#else
  (void)mapView;
#endif
}

- (BOOL)updateMapView:(id<LynxMapProviderMapView>)mapView
   withConfiguration:(LynxMapProviderConfiguration *)configuration
               error:(NSError * _Nullable * _Nullable)error {
#if !LYNX_HAS_AMAP_IOS
  if (error != NULL) {
    *error = self.availabilityError;
  }
  (void)mapView;
  (void)configuration;
  return NO;
#else
  LynxAMapMapViewBox *box = (LynxAMapMapViewBox *)mapView;
  if (box != self.activeBox || box.mapView == nil || self.destroyed) {
    if (error != NULL) {
      *error = LynxMapMakeProviderError(LynxMapProviderErrorInvalidOperation,
                                         @"地图实例已失效。");
    }
    return NO;
  }
  if (!LynxAMapStringIsUsable(configuration.providerKey)) {
    if (error != NULL) {
      *error = LynxMapMakeProviderError(LynxMapProviderErrorMissingAPIKey,
                                         @"高德 iOS Map SDK 缺少宿主 Key。");
    }
    return NO;
  }
  if (!configuration.privacyAgreed) {
    if (error != NULL) {
      *error = LynxMapMakeProviderError(LynxMapProviderErrorPrivacyNotConfigured,
                                         @"高德 iOS Map SDK 隐私配置未完成。");
    }
    return NO;
  }
  return YES;
#endif
}

- (BOOL)updateMapView:(id<LynxMapProviderMapView>)mapView
               camera:(LynxMapCamera *)camera
               markers:(NSArray<LynxMapMarker *> *)markers
             polylines:(NSArray<LynxMapPolyline *> *)polylines
            massPoints:(NSArray<LynxMapMassPoint *> *)massPoints
          layerState:(LynxMapLayerState *)layerState
         viewOptions:(LynxMapViewOptions *)viewOptions
               error:(NSError * _Nullable * _Nullable)error {
#if !LYNX_HAS_AMAP_IOS
  if (error != NULL) {
    *error = self.availabilityError;
  }
  (void)mapView;
  (void)camera;
  (void)markers;
  (void)polylines;
  (void)massPoints;
  (void)layerState;
  (void)viewOptions;
  return NO;
#else
  LynxAMapMapViewBox *box = (LynxAMapMapViewBox *)mapView;
  if (box != self.activeBox || box.mapView == nil || self.destroyed) {
    if (error != NULL) {
      *error = LynxMapMakeProviderError(LynxMapProviderErrorInvalidOperation,
                                         @"地图实例已失效。");
    }
    return NO;
  }
  self.layerState = [layerState copy];
  box.mapView.mapType = LynxAMapTypeFromString(self.layerState.mapType);
  box.mapView.showTraffic = self.layerState.trafficEnabled;
  if (viewOptions != nil) {
    box.mapView.zoomEnabled = viewOptions.zoomEnabled;
    box.mapView.scrollEnabled = viewOptions.scrollEnabled;
    box.mapView.rotateEnabled = viewOptions.rotateEnabled;
    box.mapView.rotateCameraEnabled = viewOptions.rotateCameraEnabled;
    box.mapView.showsCompass = viewOptions.showsCompass;
    box.mapView.showsScale = viewOptions.showsScale;
    box.mapView.showsLabels = viewOptions.showsLabels;
    box.mapView.showsBuildings = viewOptions.showsBuildings;
    box.mapView.touchPOIEnabled = viewOptions.touchPOIEnabled;
  }
  if (camera.hasCenter) {
    box.mapView.centerCoordinate = (CLLocationCoordinate2D){
        camera.center.latitude,
        camera.center.longitude};
  }
  if (camera.hasZoom) {
    box.mapView.zoomLevel = LynxAMapClampedZoom(box.mapView, camera.zoom);
  }
  if (camera.hasBearing) {
    box.mapView.rotationDegree = camera.bearing.doubleValue;
  }
  if (camera.hasPitch) {
    box.mapView.cameraDegree = MIN(MAX(camera.pitch.doubleValue, 0.0), 60.0);
  }
  if (camera.hasAnchor) {
    box.mapView.screenAnchor = CGPointMake(camera.anchor[@"x"].doubleValue,
                                           camera.anchor[@"y"].doubleValue);
  }

  NSMutableSet<NSString *> *markerIDs = [NSMutableSet setWithCapacity:markers.count];
  for (LynxMapMarker *marker in markers) {
    [markerIDs addObject:marker.identifier];
    LynxAMapAnnotation *annotation = self.annotationsByID[marker.identifier];
    BOOL hadCustomView = annotation.lynxIcon != nil || annotation.lynxViewConfiguration != nil;
    BOOL hasCustomView = marker.icon != nil || marker.viewConfiguration != nil;
    if (annotation == nil) {
      annotation = [[LynxAMapAnnotation alloc] init];
      annotation.lynxIdentifier = marker.identifier;
      self.annotationsByID[marker.identifier] = annotation;
      [box.mapView addAnnotation:annotation];
    }
    annotation.coordinate = (CLLocationCoordinate2D){
        marker.coordinate.latitude,
        marker.coordinate.longitude};
    annotation.title = marker.title;
    annotation.subtitle = marker.subtitle;
    annotation.lynxIcon = marker.icon;
    annotation.lynxViewConfiguration = marker.viewConfiguration;
    BOOL selectionChanged = annotation.lynxSelected != marker.selected;
    annotation.lynxSelected = marker.selected;
    annotation.lynxDraggable = marker.draggable;
    annotation.lynxVisible = marker.visible && self.layerState.visible;
    annotation.lynxOpacity = marker.opacity * self.layerState.opacity;
    annotation.lynxZIndex = marker.zIndex + self.layerState.zIndex;
    MAAnnotationView *view = [box.mapView viewForAnnotation:annotation];
    if (view != nil) {
      view.hidden = !annotation.lynxVisible;
      view.alpha = annotation.lynxVisible ? annotation.lynxOpacity : 0;
      view.zIndex = annotation.lynxZIndex;
      view.draggable = annotation.lynxDraggable;
      view.selected = annotation.lynxSelected;
      if ([view isKindOfClass:[LynxAMapMarkerView class]]) {
        [(LynxAMapMarkerView *)view applyIcon:annotation.lynxIcon
                                          view:annotation.lynxViewConfiguration
                                      selected:annotation.lynxSelected];
      }
    }
    if (annotation != nil && hadCustomView != hasCustomView) {
      [box.mapView removeAnnotation:annotation];
      [box.mapView addAnnotation:annotation];
    }
    if (selectionChanged) {
      if (annotation.lynxSelected) {
        [box.mapView selectAnnotation:annotation animated:NO];
      } else {
        [box.mapView deselectAnnotation:annotation animated:NO];
      }
    }
  }
  for (NSString *identifier in [self.annotationsByID.allKeys copy]) {
    if (![markerIDs containsObject:identifier]) {
      LynxAMapAnnotation *annotation = self.annotationsByID[identifier];
      [box.mapView removeAnnotation:annotation];
      [self.annotationsByID removeObjectForKey:identifier];
    }
  }

  NSMutableSet<NSString *> *polylineIDs = [NSMutableSet setWithCapacity:polylines.count];
  for (LynxMapPolyline *polyline in polylines) {
    [polylineIDs addObject:polyline.identifier];
    LynxAMapPolyline *overlay = self.polylinesByID[polyline.identifier];
    if (overlay == nil) {
      CLLocationCoordinate2D firstPoints[2] = {
          {polyline.points[0].latitude, polyline.points[0].longitude},
          {polyline.points[1].latitude, polyline.points[1].longitude},
      };
      overlay = [LynxAMapPolyline polylineWithCoordinates:firstPoints count:2];
      overlay.lynxIdentifier = polyline.identifier;
      self.polylinesByID[polyline.identifier] = overlay;
      [box.mapView addOverlay:overlay level:MAOverlayLevelAboveLabels];
    }
    uint64_t pathFingerprint = LynxAMapPolylineFingerprint(polyline);
    NSNumber *previousFingerprint = self.pathFingerprintsByID[polyline.identifier];
    if (previousFingerprint == nil || previousFingerprint.unsignedLongLongValue != pathFingerprint) {
      CLLocationCoordinate2D *coordinates =
          calloc(polyline.points.count, sizeof(CLLocationCoordinate2D));
      if (coordinates == NULL) {
        if (error != NULL) {
          *error = LynxMapMakeProviderError(LynxMapProviderErrorInvalidOperation,
                                             @"地图折线路径内存分配失败。");
        }
        return NO;
      }
      for (NSUInteger index = 0; index < polyline.points.count; index++) {
        coordinates[index] = (CLLocationCoordinate2D){
            polyline.points[index].latitude,
            polyline.points[index].longitude};
      }
      BOOL updated =
          [overlay setPolylineWithCoordinates:coordinates count:(NSInteger)polyline.points.count];
      free(coordinates);
      if (!updated) {
        if (error != NULL) {
          *error = LynxMapMakeProviderError(LynxMapProviderErrorInvalidConfiguration,
                                             @"地图折线路径更新失败。");
        }
        return NO;
      }
      self.pathFingerprintsByID[polyline.identifier] = @(pathFingerprint);
    }
    overlay.lynxVisible = polyline.visible && self.layerState.visible;
    overlay.lynxOpacity = polyline.opacity * self.layerState.opacity;
    overlay.lynxWidth = polyline.width;
    overlay.lynxColor = polyline.color;
    overlay.lynxZIndex = polyline.zIndex + self.layerState.zIndex;
    MAPolylineRenderer *renderer = self.renderersByID[polyline.identifier];
    if (renderer == nil) {
      renderer = (MAPolylineRenderer *)[box.mapView rendererForOverlay:overlay];
      if (renderer != nil) {
        self.renderersByID[polyline.identifier] = renderer;
      }
    }
    if (renderer != nil) {
      renderer.alpha = overlay.lynxVisible ? overlay.lynxOpacity : 0;
      renderer.lineWidth = overlay.lynxWidth;
      renderer.strokeColor = LynxAMapColorFromHex(overlay.lynxColor ?: @"#0A7CF9", 1.0);
      [renderer setNeedsUpdate];
    }
  }
  for (NSString *identifier in [self.polylinesByID.allKeys copy]) {
    if (![polylineIDs containsObject:identifier]) {
      LynxAMapPolyline *overlay = self.polylinesByID[identifier];
      [box.mapView removeOverlay:overlay];
      [self.polylinesByID removeObjectForKey:identifier];
      [self.renderersByID removeObjectForKey:identifier];
      [self.pathFingerprintsByID removeObjectForKey:identifier];
    }
  }

  // AMap 的 overlay 顺序只在同一 MAOverlayLevel 内生效。用稳定的 zIndex + id 排序，
  // 只在顺序确实变化时重排，避免每次 props 更新都销毁 renderer。
  NSArray<LynxAMapPolyline *> *orderedPolylines =
      [[self.polylinesByID.allValues sortedArrayUsingComparator:^NSComparisonResult(
          LynxAMapPolyline *left, LynxAMapPolyline *right) {
        if (left.lynxZIndex < right.lynxZIndex) return NSOrderedAscending;
        if (left.lynxZIndex > right.lynxZIndex) return NSOrderedDescending;
        return [left.lynxIdentifier compare:right.lynxIdentifier];
      }] copy];
  NSMutableArray<NSString *> *orderedIDs =
      [NSMutableArray arrayWithCapacity:orderedPolylines.count];
  for (LynxAMapPolyline *overlay in orderedPolylines) {
    [orderedIDs addObject:overlay.lynxIdentifier];
  }
  if (![orderedIDs isEqualToArray:self.orderedPolylineIDs]) {
    [box.mapView removeOverlays:self.polylinesByID.allValues];
    NSUInteger overlayIndex = 0;
    for (LynxAMapPolyline *overlay in orderedPolylines) {
      [box.mapView insertOverlay:overlay
                         atIndex:overlayIndex++
                            level:MAOverlayLevelAboveLabels];
    }
    [self.renderersByID removeAllObjects];
    self.orderedPolylineIDs = orderedIDs.copy;
  }

  uint64_t massPointFingerprint = LynxAMapMassPointFingerprint(massPoints);
  if (massPointFingerprint != self.massPointFingerprint) {
    if (self.massPointOverlay != nil) {
      [box.mapView removeOverlay:self.massPointOverlay];
    }
    self.massPointOverlay = nil;
    self.massPointRenderer = nil;
    if (massPoints.count > 0) {
      NSMutableArray<MAMultiPointItem *> *items = [NSMutableArray arrayWithCapacity:massPoints.count];
      NSMutableDictionary<NSString *, NSString *> *identifiers = [NSMutableDictionary dictionaryWithCapacity:massPoints.count];
      for (LynxMapMassPoint *point in massPoints) {
        MAMultiPointItem *item = [[MAMultiPointItem alloc] init];
        item.customID = point.identifier;
        item.title = point.title;
        item.subtitle = point.subtitle;
        item.coordinate = (CLLocationCoordinate2D){point.coordinate.latitude, point.coordinate.longitude};
        [items addObject:item];
        identifiers[point.identifier] = point.identifier;
      }
      LynxAMapMassPointOverlay *overlay = [[LynxAMapMassPointOverlay alloc] initWithMultiPointItems:items];
      overlay.identifiersByCustomID = identifiers.copy;
      self.massPointOverlay = overlay;
      [box.mapView addOverlay:overlay level:MAOverlayLevelAboveLabels];
    }
    self.massPointFingerprint = massPointFingerprint;
  }
  return YES;
#endif
}

- (LynxMapCamera * _Nullable)currentCameraForMapView:(id<LynxMapProviderMapView>)mapView
                                      error:(NSError * _Nullable * _Nullable)error {
#if !LYNX_HAS_AMAP_IOS
  if (error != NULL) *error = self.availabilityError;
  (void)mapView;
  return nil;
#else
  LynxAMapMapViewBox *box = (LynxAMapMapViewBox *)mapView;
  if (!LynxAMapIsCurrentBox(self, box, box.mapView)) {
    if (error != NULL) {
      *error = LynxMapMakeProviderError(LynxMapProviderErrorInvalidOperation,
                                         @"地图实例已失效。");
    }
    return nil;
  }
  LynxMapCoordinate *center = LynxAMapCoordinateFromCLLocation(box.mapView.centerCoordinate);
  if (center == nil || !isfinite(box.mapView.zoomLevel)) {
    if (error != NULL) {
      *error = LynxMapMakeProviderError(LynxMapProviderErrorInvalidOperation,
                                         @"地图相机状态无效。");
    }
    return nil;
  }
  NSDictionary *anchor = @{
    @"x" : @(box.mapView.screenAnchor.x),
    @"y" : @(box.mapView.screenAnchor.y),
  };
  return [[LynxMapCamera alloc] initWithCenter:center
                                         zoom:@(box.mapView.zoomLevel)
                                      bearing:@(box.mapView.rotationDegree)
                                         pitch:@(box.mapView.cameraDegree)
                                        anchor:anchor];
#endif
}

- (NSDictionary<NSString *, NSNumber *> * _Nullable)screenPointForCoordinate:(LynxMapCoordinate *)coordinate
                                                                      mapView:(id<LynxMapProviderMapView>)mapView
                                                                        error:(NSError * _Nullable * _Nullable)error {
#if !LYNX_HAS_AMAP_IOS
  (void)coordinate;
  (void)mapView;
  if (error != NULL) *error = self.availabilityError;
  return nil;
#else
  LynxAMapMapViewBox *box = (LynxAMapMapViewBox *)mapView;
  if (coordinate == nil || !LynxAMapIsCurrentBox(self, box, box.mapView)) {
    if (error != NULL) {
      *error = LynxMapMakeProviderError(LynxMapProviderErrorInvalidOperation, @"地图实例已失效。");
    }
    return nil;
  }
  CGPoint point = [box.mapView convertCoordinate:(CLLocationCoordinate2D){
      coordinate.latitude, coordinate.longitude
  } toPointToView:box.mapView];
  if (!isfinite(point.x) || !isfinite(point.y)) {
    if (error != NULL) {
      *error = LynxMapMakeProviderError(LynxMapProviderErrorInvalidOperation, @"坐标投影失败。");
    }
    return nil;
  }
  return @{
    @"x" : @(point.x),
    @"y" : @(point.y),
    @"visible" : @(CGRectContainsPoint(box.mapView.bounds, point)),
  };
#endif
}

- (void)moveCamera:(LynxMapCamera *)camera
           mapView:(id<LynxMapProviderMapView>)mapView
          animated:(BOOL)animated
        completion:(LynxMapProviderOperationCompletion)completion {
#if !LYNX_HAS_AMAP_IOS
  (void)camera;
  (void)mapView;
  (void)animated;
  if (completion != nil) completion(self.availabilityError);
#else
  LynxAMapMapViewBox *box = (LynxAMapMapViewBox *)mapView;
  if (!LynxAMapIsCurrentBox(self, box, box.mapView)) {
    if (completion != nil) completion(LynxMapMakeProviderError(LynxMapProviderErrorCancelled, @"地图实例已失效。"));
    return;
  }
  if (camera.hasCenter) {
    [box.mapView setCenterCoordinate:(CLLocationCoordinate2D){camera.center.latitude, camera.center.longitude}
                            animated:animated];
  }
  if (camera.hasZoom) {
    [box.mapView setZoomLevel:LynxAMapClampedZoom(box.mapView, camera.zoom) animated:animated];
  }
  if (camera.hasBearing) {
    [box.mapView setRotationDegree:camera.bearing.doubleValue
                           animated:animated
                           duration:animated ? 0.35 : 0.0];
  }
  if (camera.hasPitch) {
    [box.mapView setCameraDegree:MIN(MAX(camera.pitch.doubleValue, 0.0), 60.0)
                          animated:animated
                          duration:animated ? 0.35 : 0.0];
  }
  if (camera.hasAnchor) {
    box.mapView.screenAnchor = CGPointMake(camera.anchor[@"x"].doubleValue,
                                           camera.anchor[@"y"].doubleValue);
  }
  if (completion != nil) completion(nil);
#endif
}

- (void)fitBounds:(LynxMapBounds *)bounds
           mapView:(id<LynxMapProviderMapView>)mapView
           padding:(UIEdgeInsets)padding
          animated:(BOOL)animated
        completion:(LynxMapProviderOperationCompletion)completion {
#if !LYNX_HAS_AMAP_IOS
  (void)bounds;
  (void)mapView;
  (void)padding;
  (void)animated;
  if (completion != nil) completion(self.availabilityError);
#else
  LynxAMapMapViewBox *box = (LynxAMapMapViewBox *)mapView;
  if (!LynxAMapIsCurrentBox(self, box, box.mapView)) {
    if (completion != nil) completion(LynxMapMakeProviderError(LynxMapProviderErrorCancelled, @"地图实例已失效。"));
    return;
  }
  CLLocationDegrees minLatitude = MIN(bounds.southWest.latitude, bounds.northEast.latitude);
  CLLocationDegrees maxLatitude = MAX(bounds.southWest.latitude, bounds.northEast.latitude);
  CLLocationDegrees minLongitude = MIN(bounds.southWest.longitude, bounds.northEast.longitude);
  CLLocationDegrees maxLongitude = MAX(bounds.southWest.longitude, bounds.northEast.longitude);
  CLLocationCoordinate2D center = {
      (minLatitude + maxLatitude) / 2.0,
      (minLongitude + maxLongitude) / 2.0};
  MACoordinateRegion region = MACoordinateRegionMake(
      center,
      MACoordinateSpanMake(MAX(maxLatitude - minLatitude, 0.001),
                           MAX(maxLongitude - minLongitude, 0.001)));
  MAMapRect rect = MAMapRectForCoordinateRegion(region);
  [box.mapView setVisibleMapRect:rect edgePadding:padding animated:animated];
  if (completion != nil) completion(nil);
#endif
}

- (void)setMarkerWithIdentifier:(NSString *)identifier
                         selected:(BOOL)selected
                          mapView:(id<LynxMapProviderMapView>)mapView
                          animated:(BOOL)animated
                        completion:(LynxMapProviderOperationCompletion)completion {
#if !LYNX_HAS_AMAP_IOS
  (void)identifier;
  (void)selected;
  (void)mapView;
  (void)animated;
  if (completion != nil) completion(self.availabilityError);
#else
  LynxAMapMapViewBox *box = (LynxAMapMapViewBox *)mapView;
  LynxAMapAnnotation *annotation = self.annotationsByID[identifier];
  if (!LynxAMapIsCurrentBox(self, box, box.mapView) || annotation == nil) {
    if (completion != nil) {
      completion(LynxMapMakeProviderError(LynxMapProviderErrorInvalidOperation,
                                          @"目标 marker 不存在。"));
    }
    return;
  }
  annotation.lynxSelected = selected;
  if (selected) {
    [box.mapView selectAnnotation:annotation animated:animated];
  } else {
    [box.mapView deselectAnnotation:annotation animated:animated];
  }
  if (completion != nil) completion(nil);
#endif
}

- (void)showMarkersWithIdentifiers:(NSArray<NSString *> *)identifiers
                           mapView:(id<LynxMapProviderMapView>)mapView
                           padding:(UIEdgeInsets)padding
                          animated:(BOOL)animated
                        completion:(LynxMapProviderOperationCompletion)completion {
#if !LYNX_HAS_AMAP_IOS
  (void)identifiers;
  (void)mapView;
  (void)padding;
  (void)animated;
  if (completion != nil) completion(self.availabilityError);
#else
  LynxAMapMapViewBox *box = (LynxAMapMapViewBox *)mapView;
  if (!LynxAMapIsCurrentBox(self, box, box.mapView)) {
    if (completion != nil) completion(LynxMapMakeProviderError(LynxMapProviderErrorInvalidOperation,
                                                                @"地图实例已失效。"));
    return;
  }
  NSMutableArray<LynxAMapAnnotation *> *annotations =
      [NSMutableArray arrayWithCapacity:identifiers.count];
  for (NSString *identifier in identifiers) {
    LynxAMapAnnotation *annotation = self.annotationsByID[identifier];
    if (annotation == nil) {
      if (completion != nil) completion(LynxMapMakeProviderError(
          LynxMapProviderErrorInvalidOperation, @"showMarkers 包含不存在的 marker。"));
      return;
    }
    [annotations addObject:annotation];
  }
  [box.mapView showAnnotations:annotations edgePadding:padding animated:animated];
  if (completion != nil) completion(nil);
#endif
}

- (void)cancelPendingOperationsForMapView:(id<LynxMapProviderMapView>)mapView {
  (void)mapView;
}

- (void)removeAllListenersFromMapView:(id<LynxMapProviderMapView>)mapView {
#if LYNX_HAS_AMAP_IOS
  LynxAMapMapViewBox *box = (LynxAMapMapViewBox *)mapView;
  if (box == self.activeBox && box.mapView != nil) box.mapView.delegate = nil;
#else
  (void)mapView;
#endif
}

- (void)removeAllOverlaysFromMapView:(id<LynxMapProviderMapView>)mapView {
#if LYNX_HAS_AMAP_IOS
  LynxAMapMapViewBox *box = (LynxAMapMapViewBox *)mapView;
  if (box != self.activeBox || box.mapView == nil) return;
  [box.mapView removeAnnotations:self.annotationsByID.allValues];
  [box.mapView removeOverlays:self.polylinesByID.allValues];
  if (self.massPointOverlay != nil) {
    [box.mapView removeOverlay:self.massPointOverlay];
  }
  [self.annotationsByID removeAllObjects];
  [self.polylinesByID removeAllObjects];
  [self.renderersByID removeAllObjects];
  [self.pathFingerprintsByID removeAllObjects];
  self.massPointOverlay = nil;
  self.massPointRenderer = nil;
  self.massPointFingerprint = 0;
  self.orderedPolylineIDs = @[];
#else
  (void)mapView;
#endif
}

- (void)clearIconCacheForMapView:(id<LynxMapProviderMapView>)mapView {
  (void)mapView;
}

- (void)destroyMapView:(id<LynxMapProviderMapView>)mapView {
#if LYNX_HAS_AMAP_IOS
  LynxAMapMapViewBox *box = (LynxAMapMapViewBox *)mapView;
  if (box != self.activeBox) return;
  if (self.pendingLoadFailureTask != nil) {
    dispatch_block_cancel(self.pendingLoadFailureTask);
    self.pendingLoadFailureTask = nil;
  }
  self.destroyed = YES;
  box.mapView.renderringDisabled = YES;
  box.mapView.delegate = nil;
  [box.mapView removeFromSuperview];
  box.mapView = nil;
  [self.annotationsByID removeAllObjects];
  [self.polylinesByID removeAllObjects];
  [self.renderersByID removeAllObjects];
  [self.pathFingerprintsByID removeAllObjects];
  self.massPointOverlay = nil;
  self.massPointRenderer = nil;
  self.massPointFingerprint = 0;
  self.orderedPolylineIDs = @[];
  self.activeBox = nil;
  self.eventSink = nil;
#else
  (void)mapView;
#endif
}

#if LYNX_HAS_AMAP_IOS

- (void)mapViewDidFinishLoadingMap:(MAMapView *)mapView {
  LynxAMapMapViewBox *box = self.activeBox;
  if (!LynxAMapIsCurrentBox(self, box, mapView) || self.readySent) return;
  if (self.pendingLoadFailureTask != nil) {
    dispatch_block_cancel(self.pendingLoadFailureTask);
    self.pendingLoadFailureTask = nil;
  }
  if (mapView.bounds.size.width <= 0 || mapView.bounds.size.height <= 0) {
    self.pendingReady = YES;
    return;
  }
  self.readySent = YES;
  [self.eventSink mapProviderDidBecomeReadyForMapView:box];
}

- (void)mapViewDidFailLoadingMap:(MAMapView *)mapView withError:(NSError *)error {
  LynxAMapMapViewBox *box = self.activeBox;
  if (!LynxAMapIsCurrentBox(self, box, mapView)) return;
  if (self.readySent) return;

  // AMap 11.2.x 在首次创建实例时可能先回调一次失败（例如统计/资源目录尚未
  // 初始化），随后仍然会回调 finish。延迟失败事件，避免把最终成功的地图显示为
  // 错误；如果延迟结束仍未 ready，再向 Lynx 发送可安全展示的错误码。
  if (self.pendingLoadFailureTask != nil) {
    dispatch_block_cancel(self.pendingLoadFailureTask);
    self.pendingLoadFailureTask = nil;
  }
  __weak LynxAMapProviderAdapter *weakSelf = self;
  __weak LynxAMapMapViewBox *weakBox = box;
  dispatch_block_t failureTask = dispatch_block_create(0, ^{
    LynxAMapProviderAdapter *strongSelf = weakSelf;
    LynxAMapMapViewBox *strongBox = weakBox;
    if (strongSelf == nil || strongBox == nil || strongSelf.destroyed ||
        strongSelf.activeBox != strongBox || strongBox.mapView != mapView ||
        strongSelf.readySent) {
      return;
    }
    strongSelf.pendingLoadFailureTask = nil;
    NSError *safeError = LynxMapMakeProviderError(
        LynxMapProviderErrorUnavailable,
        @"高德地图加载失败，请检查 Key、网络和宿主配置。");
    [strongSelf.eventSink mapProvider:strongBox didFailWithError:safeError];
  });
  self.pendingLoadFailureTask = failureTask;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), failureTask);
  (void)error;
}

- (void)mapView:(MAMapView *)mapView didSingleTappedAtCoordinate:(CLLocationCoordinate2D)coordinate {
  LynxAMapMapViewBox *box = self.activeBox;
  LynxMapCoordinate *value = LynxAMapCoordinateFromCLLocation(coordinate);
  if (!LynxAMapIsCurrentBox(self, box, mapView) || value == nil) return;
  [self.eventSink mapProvider:box didTapAtCoordinate:value];
}

- (void)mapView:(MAMapView *)mapView regionWillChangeAnimated:(BOOL)animated wasUserAction:(BOOL)wasUserAction {
  (void)mapView;
  (void)animated;
  LynxAMapSendRegionEvent(self, self.activeBox, wasUserAction, @"begin");
}

- (void)mapView:(MAMapView *)mapView regionDidChangeAnimated:(BOOL)animated wasUserAction:(BOOL)wasUserAction {
  (void)mapView;
  (void)animated;
  LynxAMapSendRegionEvent(self, self.activeBox, wasUserAction, @"end");
}

- (MAAnnotationView *)mapView:(MAMapView *)mapView viewForAnnotation:(id<MAAnnotation>)annotation {
  if (![annotation isKindOfClass:[LynxAMapAnnotation class]]) return nil;
  LynxAMapAnnotation *lynxAnnotation = (LynxAMapAnnotation *)annotation;
  if (lynxAnnotation.lynxIcon != nil || lynxAnnotation.lynxViewConfiguration != nil) {
    static NSString *const customReuseIdentifier = @"lynx-map-custom-marker";
    LynxAMapMarkerView *view = (LynxAMapMarkerView *)[mapView dequeueReusableAnnotationViewWithIdentifier:customReuseIdentifier];
    if (view == nil) {
      view = [[LynxAMapMarkerView alloc] initWithAnnotation:annotation
                                            reuseIdentifier:customReuseIdentifier];
    } else {
      view.annotation = annotation;
    }
    view.zIndex = lynxAnnotation.lynxZIndex;
    view.hidden = !lynxAnnotation.lynxVisible;
    view.alpha = lynxAnnotation.lynxVisible ? lynxAnnotation.lynxOpacity : 0;
    view.draggable = lynxAnnotation.lynxDraggable;
    [view applyIcon:lynxAnnotation.lynxIcon
               view:lynxAnnotation.lynxViewConfiguration
           selected:lynxAnnotation.lynxSelected];
    return view;
  }
  static NSString *const reuseIdentifier = @"lynx-map-marker";
  MAPinAnnotationView *view = (MAPinAnnotationView *)[mapView dequeueReusableAnnotationViewWithIdentifier:reuseIdentifier];
  if (view == nil) {
    view = [[MAPinAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:reuseIdentifier];
  } else {
    view.annotation = annotation;
  }
  view.pinColor = MAPinAnnotationColorRed;
  view.canShowCallout = NO;
  view.zIndex = lynxAnnotation.lynxZIndex;
  view.hidden = !lynxAnnotation.lynxVisible;
  view.alpha = lynxAnnotation.lynxVisible ? lynxAnnotation.lynxOpacity : 0;
  view.draggable = lynxAnnotation.lynxDraggable;
  return view;
}

- (void)mapView:(MAMapView *)mapView didAddAnnotationViews:(NSArray *)views {
  (void)mapView;
  for (MAAnnotationView *view in views) {
    if (![view.annotation isKindOfClass:[LynxAMapAnnotation class]]) continue;
    LynxAMapAnnotation *annotation = (LynxAMapAnnotation *)view.annotation;
    view.zIndex = annotation.lynxZIndex;
    view.hidden = !annotation.lynxVisible;
    view.alpha = annotation.lynxVisible ? annotation.lynxOpacity : 0;
    view.draggable = annotation.lynxDraggable;
    if ([view isKindOfClass:[LynxAMapMarkerView class]]) {
      [(LynxAMapMarkerView *)view applyIcon:annotation.lynxIcon
                                        view:annotation.lynxViewConfiguration
                                    selected:annotation.lynxSelected];
    }
  }
}

- (void)mapView:(MAMapView *)mapView didAnnotationViewTapped:(MAAnnotationView *)view {
  if (![view.annotation isKindOfClass:[LynxAMapAnnotation class]]) return;
  LynxAMapMapViewBox *box = self.activeBox;
  LynxAMapAnnotation *annotation = (LynxAMapAnnotation *)view.annotation;
  LynxMapCoordinate *coordinate = LynxAMapCoordinateFromCLLocation(annotation.coordinate);
  if (!LynxAMapIsCurrentBox(self, box, mapView) || coordinate == nil) return;
  [self.eventSink mapProvider:box
      didTapMarkerWithIdentifier:annotation.lynxIdentifier
                       coordinate:coordinate];
}

- (void)mapView:(MAMapView *)mapView didSelectAnnotationView:(MAAnnotationView *)view {
  if (![view.annotation isKindOfClass:[LynxAMapAnnotation class]]) return;
  LynxAMapMapViewBox *box = self.activeBox;
  LynxAMapAnnotation *annotation = (LynxAMapAnnotation *)view.annotation;
  LynxMapCoordinate *coordinate = LynxAMapCoordinateFromCLLocation(annotation.coordinate);
  if (!LynxAMapIsCurrentBox(self, box, mapView) || coordinate == nil) return;
  annotation.lynxSelected = YES;
  [self.eventSink mapProvider:box
      didSelectMarkerWithIdentifier:annotation.lynxIdentifier
                          coordinate:coordinate];
}

- (void)mapView:(MAMapView *)mapView didDeselectAnnotationView:(MAAnnotationView *)view {
  if (![view.annotation isKindOfClass:[LynxAMapAnnotation class]]) return;
  LynxAMapMapViewBox *box = self.activeBox;
  LynxAMapAnnotation *annotation = (LynxAMapAnnotation *)view.annotation;
  LynxMapCoordinate *coordinate = LynxAMapCoordinateFromCLLocation(annotation.coordinate);
  if (!LynxAMapIsCurrentBox(self, box, mapView) || coordinate == nil) return;
  annotation.lynxSelected = NO;
  [self.eventSink mapProvider:box
    didDeselectMarkerWithIdentifier:annotation.lynxIdentifier
                           coordinate:coordinate];
}

- (void)mapView:(MAMapView *)mapView
    annotationView:(MAAnnotationView *)view
    didChangeDragState:(MAAnnotationViewDragState)newState
         fromOldState:(MAAnnotationViewDragState)oldState {
  (void)oldState;
  if (![view.annotation isKindOfClass:[LynxAMapAnnotation class]]) return;
  LynxAMapMapViewBox *box = self.activeBox;
  LynxAMapAnnotation *annotation = (LynxAMapAnnotation *)view.annotation;
  LynxMapCoordinate *coordinate = LynxAMapCoordinateFromCLLocation(annotation.coordinate);
  if (!LynxAMapIsCurrentBox(self, box, mapView) || coordinate == nil) return;
  NSString *phase = nil;
  switch (newState) {
    case MAAnnotationViewDragStateStarting:
      phase = @"start";
      break;
    case MAAnnotationViewDragStateDragging:
      phase = @"dragging";
      break;
    case MAAnnotationViewDragStateEnding:
      phase = @"end";
      break;
    case MAAnnotationViewDragStateCanceling:
      phase = @"cancel";
      break;
    case MAAnnotationViewDragStateNone:
      return;
  }
  [self.eventSink mapProvider:box
      didDragMarkerWithIdentifier:annotation.lynxIdentifier
                        coordinate:coordinate
                             phase:phase];
}

- (void)mapView:(MAMapView *)mapView didLongPressedAtCoordinate:(CLLocationCoordinate2D)coordinate {
  LynxAMapMapViewBox *box = self.activeBox;
  LynxMapCoordinate *value = LynxAMapCoordinateFromCLLocation(coordinate);
  if (!LynxAMapIsCurrentBox(self, box, mapView) || value == nil) return;
  [self.eventSink mapProvider:box didLongPressAtCoordinate:value];
}

- (MAOverlayRenderer *)mapView:(MAMapView *)mapView rendererForOverlay:(id<MAOverlay>)overlay {
  (void)mapView;
  if ([overlay isKindOfClass:[LynxAMapMassPointOverlay class]]) {
    MAMultiPointOverlayRenderer *renderer = [[MAMultiPointOverlayRenderer alloc]
        initWithMultiPointOverlay:(MAMultiPointOverlay *)overlay];
    renderer.icon = LynxAMapMassPointIcon();
    renderer.pointSize = CGSizeMake(14, 14);
    renderer.anchor = CGPointMake(.5, .5);
    renderer.delegate = self;
    self.massPointRenderer = renderer;
    return renderer;
  }
  if (![overlay isKindOfClass:[LynxAMapPolyline class]]) return nil;
  LynxAMapPolyline *polyline = (LynxAMapPolyline *)overlay;
  MAPolylineRenderer *renderer = [[MAPolylineRenderer alloc] initWithPolyline:polyline];
  LynxMapLayerState *state = self.layerState;
  renderer.strokeColor = LynxAMapColorFromHex(polyline.lynxColor ?: @"#0A7CF9", 1.0);
  renderer.lineWidth = polyline.lynxWidth;
  // `lynxOpacity` 已在 state diff 时乘过 layer opacity，这里不能再次相乘。
  BOOL layerVisible = state == nil || state.visible;
  renderer.alpha = polyline.lynxVisible && layerVisible ? polyline.lynxOpacity : 0;
  return renderer;
}

- (void)multiPointOverlayRenderer:(MAMultiPointOverlayRenderer *)renderer
                    didItemTapped:(MAMultiPointItem *)item {
  if (renderer != self.massPointRenderer || item.customID.length == 0) return;
  LynxAMapMapViewBox *box = self.activeBox;
  LynxMapCoordinate *coordinate = LynxAMapCoordinateFromCLLocation(item.coordinate);
  if (box == nil || coordinate == nil || !LynxAMapIsCurrentBox(self, box, box.mapView)) return;
  [self.eventSink mapProvider:box
      didTapMassPointWithIdentifier:item.customID
                          coordinate:coordinate];
}

#endif

@end
