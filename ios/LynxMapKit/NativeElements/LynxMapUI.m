#import "LynxMapUI.h"

#import "LynxMapElementContract.h"

#import <Lynx/LynxComponentRegistry.h>
#import <Lynx/LynxEvent.h>
#import <Lynx/LynxEventEmitter.h>
#import <Lynx/LynxPropsProcessor.h>
#import <Lynx/LynxUIMethodProcessor.h>

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

@class LynxMapUI;

typedef void (^LynxMapContainerLayoutObserver)(void);

/// 高德 Metal 瓦片层可能盖住 MapView 内部标记，因此 adapter 可以提供一个外置 overlayView。
/// 该容器只管理 sibling 的 frame 和层级，不创建或持有任何厂商对象。
@interface LynxMapElementContainerView : UIView

@property(nonatomic, copy, nullable) LynxMapContainerLayoutObserver layoutObserver;

- (BOOL)attachProviderMapView:(id<LynxMapProviderMapView>)providerMapView;
- (void)detachProviderMapView;

@end

@interface LynxMapUI (LynxMapProviderEvents)

- (void)handleProviderReadyForMapView:(id<LynxMapProviderMapView>)mapView
                           generation:(NSUInteger)generation;
- (void)handleProviderFailureForMapView:(id<LynxMapProviderMapView>)mapView
                              generation:(NSUInteger)generation
                                  error:(NSError *)error;
- (void)handleProviderMapTapForMapView:(id<LynxMapProviderMapView>)mapView
                             generation:(NSUInteger)generation
                            coordinate:(LynxMapCoordinate *)coordinate;
- (void)handleProviderMarkerTapForMapView:(id<LynxMapProviderMapView>)mapView
                                generation:(NSUInteger)generation
                                identifier:(NSString *)identifier
                                coordinate:(LynxMapCoordinate *)coordinate;
- (void)handleProviderMassPointTapForMapView:(id<LynxMapProviderMapView>)mapView
                                   generation:(NSUInteger)generation
                                   identifier:(NSString *)identifier
                                   coordinate:(LynxMapCoordinate *)coordinate;
- (void)handleProviderMarkerSelectionForMapView:(id<LynxMapProviderMapView>)mapView
                                      generation:(NSUInteger)generation
                                      identifier:(NSString *)identifier
                                      coordinate:(LynxMapCoordinate *)coordinate
                                        selected:(BOOL)selected;
- (void)handleProviderMarkerDragForMapView:(id<LynxMapProviderMapView>)mapView
                                  generation:(NSUInteger)generation
                                  identifier:(NSString *)identifier
                                  coordinate:(LynxMapCoordinate *)coordinate
                                       phase:(NSString *)phase;
- (void)handleProviderLongPressForMapView:(id<LynxMapProviderMapView>)mapView
                                generation:(NSUInteger)generation
                               coordinate:(LynxMapCoordinate *)coordinate;
- (void)handleProviderRegionChangeForMapView:(id<LynxMapProviderMapView>)mapView
                                   generation:(NSUInteger)generation
                                      center:(nullable LynxMapCoordinate *)center
                                        zoom:(nullable NSNumber *)zoom
                                      reason:(nullable NSString *)reason;

@end

@implementation LynxMapElementContainerView {
  UIView *_providerView;
  UIView *_overlayView;
  CGSize _lastNotifiedSize;
}

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self != nil) {
    self.backgroundColor = UIColor.clearColor;
    // 不裁剪外置 marker/callout，避免 provider 的 Metal 层造成空白或截断。
    self.clipsToBounds = NO;
    self.opaque = NO;
    _lastNotifiedSize = CGSizeZero;
  }
  return self;
}

- (BOOL)attachProviderMapView:(id<LynxMapProviderMapView>)providerMapView {
  UIView *providerView = providerMapView.view;
  if (![providerView isKindOfClass:[UIView class]]) {
    return NO;
  }

  [_providerView removeFromSuperview];
  [_overlayView removeFromSuperview];
  _providerView = providerView;
  _overlayView = nil;

  providerView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self addSubview:providerView];

  UIView *overlayView = providerMapView.overlayView;
  if ([overlayView isKindOfClass:[UIView class]] && overlayView != providerView) {
    overlayView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlayView.backgroundColor = UIColor.clearColor;
    overlayView.opaque = NO;
    [self addSubview:overlayView];
    _overlayView = overlayView;
  }

  _lastNotifiedSize = CGSizeZero;
  [self setNeedsLayout];
  if (self.window != nil) {
    [self layoutIfNeeded];
    [self notifyLayoutIfNeededForce:YES];
  }
  return YES;
}

- (void)detachProviderMapView {
  [_overlayView removeFromSuperview];
  [_providerView removeFromSuperview];
  _overlayView = nil;
  _providerView = nil;
  _lastNotifiedSize = CGSizeZero;
  self.layoutObserver = nil;
}

- (void)layoutSubviews {
  [super layoutSubviews];
  _providerView.frame = self.bounds;
  _overlayView.frame = self.bounds;
  if (_overlayView != nil) {
    [self bringSubviewToFront:_overlayView];
  }
  [self notifyLayoutIfNeededForce:NO];
}

- (void)didMoveToWindow {
  [super didMoveToWindow];
  if (self.window != nil) {
    [self notifyLayoutIfNeededForce:YES];
  }
}

- (void)notifyLayoutIfNeededForce:(BOOL)force {
  if (_providerView == nil || self.bounds.size.width <= 0 || self.bounds.size.height <= 0) {
    return;
  }
  if (!force && CGSizeEqualToSize(_lastNotifiedSize, self.bounds.size)) {
    return;
  }
  _lastNotifiedSize = self.bounds.size;
  LynxMapContainerLayoutObserver observer = self.layoutObserver;
  if (observer != nil) {
    observer();
  }
}

@end

/// adapter 的 listener 只持有 weak Element，并把 generation 固定在一次 MapView 会话上。
/// adapter 迟到回调即使仍然到达，也无法标记下一次会话 ready。
@interface LynxMapProviderEventSinkBridge : NSObject <LynxMapProviderEventSink>

@property(nonatomic, weak) LynxMapUI *owner;
@property(nonatomic, assign) NSUInteger generation;

@end

@implementation LynxMapProviderEventSinkBridge

- (void)deliver:(void (^)(LynxMapUI *owner, NSUInteger generation))block {
  __weak LynxMapProviderEventSinkBridge *weakSelf = self;
  void (^delivery)(void) = ^{
    LynxMapProviderEventSinkBridge *strongSelf = weakSelf;
    LynxMapUI *owner = strongSelf.owner;
    if (owner != nil) {
      block(owner, strongSelf.generation);
    }
  };
  if ([NSThread isMainThread]) {
    delivery();
  } else {
    dispatch_async(dispatch_get_main_queue(), delivery);
  }
}

- (void)mapProviderDidBecomeReadyForMapView:(id<LynxMapProviderMapView>)mapView {
  [self deliver:^(LynxMapUI *owner, NSUInteger generation) {
    [owner handleProviderReadyForMapView:mapView generation:generation];
  }];
}

- (void)mapProvider:(id<LynxMapProviderMapView>)mapView didFailWithError:(NSError *)error {
  [self deliver:^(LynxMapUI *owner, NSUInteger generation) {
    [owner handleProviderFailureForMapView:mapView generation:generation error:error];
  }];
}

- (void)mapProvider:(id<LynxMapProviderMapView>)mapView
    didTapAtCoordinate:(LynxMapCoordinate *)coordinate {
  [self deliver:^(LynxMapUI *owner, NSUInteger generation) {
    [owner handleProviderMapTapForMapView:mapView generation:generation coordinate:coordinate];
  }];
}

- (void)mapProvider:(id<LynxMapProviderMapView>)mapView
    didTapMarkerWithIdentifier:(NSString *)identifier
                     coordinate:(LynxMapCoordinate *)coordinate {
  [self deliver:^(LynxMapUI *owner, NSUInteger generation) {
    [owner handleProviderMarkerTapForMapView:mapView
                                   generation:generation
                                   identifier:identifier
                                   coordinate:coordinate];
  }];
}

- (void)mapProvider:(id<LynxMapProviderMapView>)mapView
  didTapMassPointWithIdentifier:(NSString *)identifier
                      coordinate:(LynxMapCoordinate *)coordinate {
  [self deliver:^(LynxMapUI *owner, NSUInteger generation) {
    [owner handleProviderMassPointTapForMapView:mapView
                                      generation:generation
                                      identifier:identifier
                                      coordinate:coordinate];
  }];
}

- (void)mapProvider:(id<LynxMapProviderMapView>)mapView
     didSelectMarkerWithIdentifier:(NSString *)identifier
                         coordinate:(LynxMapCoordinate *)coordinate {
  [self deliver:^(LynxMapUI *owner, NSUInteger generation) {
    [owner handleProviderMarkerSelectionForMapView:mapView
                                         generation:generation
                                         identifier:identifier
                                         coordinate:coordinate
                                           selected:YES];
  }];
}

- (void)mapProvider:(id<LynxMapProviderMapView>)mapView
   didDeselectMarkerWithIdentifier:(NSString *)identifier
                           coordinate:(LynxMapCoordinate *)coordinate {
  [self deliver:^(LynxMapUI *owner, NSUInteger generation) {
    [owner handleProviderMarkerSelectionForMapView:mapView
                                         generation:generation
                                         identifier:identifier
                                         coordinate:coordinate
                                           selected:NO];
  }];
}

- (void)mapProvider:(id<LynxMapProviderMapView>)mapView
     didDragMarkerWithIdentifier:(NSString *)identifier
                       coordinate:(LynxMapCoordinate *)coordinate
                            phase:(NSString *)phase {
  [self deliver:^(LynxMapUI *owner, NSUInteger generation) {
    [owner handleProviderMarkerDragForMapView:mapView
                                    generation:generation
                                    identifier:identifier
                                    coordinate:coordinate
                                         phase:phase];
  }];
}

- (void)mapProvider:(id<LynxMapProviderMapView>)mapView
     didLongPressAtCoordinate:(LynxMapCoordinate *)coordinate {
  [self deliver:^(LynxMapUI *owner, NSUInteger generation) {
    [owner handleProviderLongPressForMapView:mapView
                                   generation:generation
                                  coordinate:coordinate];
  }];
}

- (void)mapProvider:(id<LynxMapProviderMapView>)mapView
    didChangeRegionWithCenter:(LynxMapCoordinate *)center
                          zoom:(NSNumber *)zoom
                        reason:(NSString *)reason {
  [self deliver:^(LynxMapUI *owner, NSUInteger generation) {
    [owner handleProviderRegionChangeForMapView:mapView
                                       generation:generation
                                          center:center
                                            zoom:zoom
                                          reason:reason];
  }];
}

@end

@interface LynxMapPendingOperation : NSObject

@property(nonatomic, copy, nullable) LynxUIMethodCallbackBlock callback;
@property(nonatomic, assign) NSUInteger generation;
@property(nonatomic, assign) NSUInteger cameraCommandSequence;
@property(nonatomic, assign) BOOL completed;

@end

@implementation LynxMapPendingOperation
@end

static const NSUInteger LynxMapMaximumPendingOperationCount = 16;

static NSUInteger LynxMapNextGeneration(NSUInteger generation) {
  return generation == NSUIntegerMax ? 1 : generation + 1;
}

static BOOL LynxMapReadFiniteCGFloat(id object, CGFloat *result) {
  if (![object isKindOfClass:[NSNumber class]]) {
    return NO;
  }
  double value = [object doubleValue];
  if (!isfinite(value)) {
    return NO;
  }
  if (result != NULL) {
    *result = (CGFloat)value;
  }
  return YES;
}

static BOOL LynxMapReadAnimated(NSDictionary *params, BOOL *animated, NSError **error) {
  id value = params[@"animated"];
  if (value == nil || value == [NSNull null]) {
    if (animated != NULL) {
      *animated = YES;
    }
    return YES;
  }
  if (![value isKindOfClass:[NSNumber class]]) {
    if (error != NULL) {
      *error = LynxMapMakeProviderError(LynxMapProviderErrorInvalidConfiguration,
                                        @"animated 必须是布尔值。");
    }
    return NO;
  }
  if (animated != NULL) {
    *animated = [value boolValue];
  }
  return YES;
}

static BOOL LynxMapReadPadding(id object, UIEdgeInsets *padding, NSError **error) {
  if (object == nil || object == [NSNull null]) {
    if (padding != NULL) {
      *padding = UIEdgeInsetsZero;
    }
    return YES;
  }

  CGFloat top = 0;
  CGFloat right = 0;
  CGFloat bottom = 0;
  CGFloat left = 0;
  if ([object isKindOfClass:[NSNumber class]]) {
    if (!LynxMapReadFiniteCGFloat(object, &top) || top < 0) {
      goto invalid;
    }
    right = top;
    bottom = top;
    left = top;
  } else if ([object isKindOfClass:[NSArray class]]) {
    NSArray *array = (NSArray *)object;
    if (array.count != 4 || !LynxMapReadFiniteCGFloat(array[0], &top) ||
        !LynxMapReadFiniteCGFloat(array[1], &right) ||
        !LynxMapReadFiniteCGFloat(array[2], &bottom) ||
        !LynxMapReadFiniteCGFloat(array[3], &left) || top < 0 || right < 0 || bottom < 0 ||
        left < 0) {
      goto invalid;
    }
  } else if ([object isKindOfClass:[NSDictionary class]]) {
    NSDictionary *dictionary = (NSDictionary *)object;
    if (!LynxMapReadFiniteCGFloat(dictionary[@"top"] ?: @0, &top) ||
        !LynxMapReadFiniteCGFloat(dictionary[@"right"] ?: @0, &right) ||
        !LynxMapReadFiniteCGFloat(dictionary[@"bottom"] ?: @0, &bottom) ||
        !LynxMapReadFiniteCGFloat(dictionary[@"left"] ?: @0, &left) || top < 0 || right < 0 ||
        bottom < 0 || left < 0 || top > LynxMapMaximumPadding || right > LynxMapMaximumPadding ||
        bottom > LynxMapMaximumPadding || left > LynxMapMaximumPadding) {
      goto invalid;
    }
  } else {
    goto invalid;
  }

  if (top > LynxMapMaximumPadding || right > LynxMapMaximumPadding ||
      bottom > LynxMapMaximumPadding || left > LynxMapMaximumPadding) {
    goto invalid;
  }
  if (padding != NULL) {
    *padding = UIEdgeInsetsMake(top, left, bottom, right);
  }
  return YES;

invalid:
  if (error != NULL) {
    *error = LynxMapMakeProviderError(LynxMapProviderErrorInvalidConfiguration,
                                      @"padding 必须是非负数字、四项数组或边距对象。");
  }
  return NO;
}

@interface LynxMapUI ()

- (void)mapContainerDidLayout;
- (void)emitEvent:(NSString *)name params:(nullable NSDictionary *)params;
- (void)emitError:(NSError *)error;
- (void)emitErrorCode:(LynxMapProviderErrorCode)code message:(NSString *)message;
- (NSDictionary *)methodErrorData:(NSError *)error;
- (void)ensureProviderMap;
- (void)setMarkerSelectionWithParams:(id)params
                            callback:(nullable LynxUIMethodCallbackBlock)callback
                            selected:(BOOL)selected;
- (void)updateViewOptionsWithZoomEnabled:(BOOL)zoomEnabled
                           scrollEnabled:(BOOL)scrollEnabled
                           rotateEnabled:(BOOL)rotateEnabled
                     rotateCameraEnabled:(BOOL)rotateCameraEnabled
                           showsCompass:(BOOL)showsCompass
                             showsScale:(BOOL)showsScale
                            showsLabels:(BOOL)showsLabels
                         showsBuildings:(BOOL)showsBuildings
                         touchPOIEnabled:(BOOL)touchPOIEnabled;
- (void)updateProviderPausedState;
- (void)scheduleRender;
- (void)applyCurrentStateForGeneration:(NSUInteger)generation;
- (void)teardownMap;
- (nullable LynxMapPendingOperation *)beginPendingOperationWithCallback:(nullable LynxUIMethodCallbackBlock)callback
                                                               generation:(NSUInteger)generation;
- (void)finishPendingOperation:(LynxMapPendingOperation *)operation
                    generation:(NSUInteger)generation
                          error:(nullable NSError *)error
                successData:(nullable NSDictionary *)successData;
- (void)finishPendingOperation:(LynxMapPendingOperation *)operation
                          code:(int)code
                          data:(nullable id)data;
- (BOOL)isCurrentMapView:(id<LynxMapProviderMapView>)mapView generation:(NSUInteger)generation;
- (LynxMapCamera *)cameraByApplyingPatch:(LynxMapCamera *)patch;
- (void)handleApplicationDidEnterBackground:(NSNotification *)notification;
- (void)handleApplicationWillEnterForeground:(NSNotification *)notification;

@end

@implementation LynxMapUI {
  LynxMapElementContainerView *_mapContainer;
  id<LynxMapProviderAdapter> _adapter;
  id<LynxMapProviderMapView> _providerMapView;
  LynxMapProviderEventSinkBridge *_eventSink;

  LynxMapCamera *_camera;
  LynxMapViewOptions *_viewOptions;
  NSArray<LynxMapMarker *> *_markers;
  NSArray<LynxMapPolyline *> *_polylines;
  NSArray<LynxMapMassPoint *> *_massPoints;
  LynxMapLayerState *_layerState;

  NSMutableSet<LynxMapPendingOperation *> *_pendingOperations;
  dispatch_block_t _pendingRenderTask;
  NSUInteger _generation;
  NSUInteger _latestCameraCommandSequence;
  BOOL _attemptedStart;
  BOOL _destroyed;
  BOOL _providerReady;
  BOOL _applicationInBackground;
  BOOL _windowAttached;
  BOOL _observingApplicationLifecycle;
  NSUInteger _applyCount;
  NSUInteger _lastMarkerCount;
  NSUInteger _lastPolylineCount;
  NSUInteger _lastMassPointCount;
  double _lastApplyDurationMs;
}

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _generation = 1;
    _camera = [[LynxMapCamera alloc] initWithCenter:nil zoom:nil];
    _viewOptions = [[LynxMapViewOptions alloc]
        initWithZoomEnabled:YES
               scrollEnabled:YES
               rotateEnabled:YES
         rotateCameraEnabled:YES
               showsCompass:NO
                 showsScale:NO
                showsLabels:YES
             showsBuildings:YES
             touchPOIEnabled:NO];
    _markers = @[];
    _polylines = @[];
    _massPoints = @[];
    _layerState = [[LynxMapLayerState alloc] initWithVisible:YES opacity:1.0 zIndex:0];
    _pendingOperations = [NSMutableSet setWithCapacity:LynxMapMaximumPendingOperationCount];
  }
  return self;
}

- (UIView *)createView {
  _mapContainer = [[LynxMapElementContainerView alloc] initWithFrame:CGRectZero];
  __weak LynxMapUI *weakSelf = self;
  _mapContainer.layoutObserver = ^{
    LynxMapUI *strongSelf = weakSelf;
    [strongSelf mapContainerDidLayout];
  };

  if (!_observingApplicationLifecycle) {
    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
    [notificationCenter addObserver:self
                           selector:@selector(handleApplicationDidEnterBackground:)
                               name:UIApplicationDidEnterBackgroundNotification
                             object:nil];
    [notificationCenter addObserver:self
                           selector:@selector(handleApplicationWillEnterForeground:)
                               name:UIApplicationWillEnterForegroundNotification
                             object:nil];
    _observingApplicationLifecycle = YES;
  }
  return _mapContainer;
}

- (void)onNodeReady {
  [super onNodeReady];
  [self ensureProviderMap];
}

- (void)frameDidChange {
  [super frameDidChange];
  [_mapContainer setNeedsLayout];
}

- (void)willMoveToWindow:(UIWindow *)window {
  [super willMoveToWindow:window];
  _windowAttached = window != nil;
  [self updateProviderPausedState];
}

LYNX_PROP_SETTER("center", setCenter, id) {
  if (requestReset) {
    _camera = [[LynxMapCamera alloc] initWithCenter:nil zoom:_camera.zoom];
    [self scheduleRender];
    return;
  }
  NSError *error = nil;
  LynxMapCoordinate *coordinate = [LynxMapCoordinate coordinateWithObject:value error:&error];
  if (coordinate == nil) {
    [self emitError:error ?: LynxMapMakeProviderError(LynxMapProviderErrorInvalidConfiguration,
                                                      @"center 坐标无效。")];
    return;
  }
  _camera = [[LynxMapCamera alloc] initWithCenter:coordinate zoom:_camera.zoom];
  [self scheduleRender];
}

LYNX_PROP_SETTER("zoom", setZoom, CGFloat) {
  if (requestReset) {
    _camera = [[LynxMapCamera alloc] initWithCenter:_camera.center zoom:nil];
    [self scheduleRender];
    return;
  }
  if (!isfinite((double)value) || value < LynxMapMinimumZoom || value > LynxMapMaximumZoom) {
    [self emitErrorCode:LynxMapProviderErrorInvalidConfiguration message:@"zoom 必须在 0 到 24 之间。"];
    return;
  }
  _camera = [[LynxMapCamera alloc] initWithCenter:_camera.center zoom:@((double)value)];
  [self scheduleRender];
}

LYNX_PROP_SETTER("bearing", setBearing, CGFloat) {
  if (requestReset) {
    _camera = [[LynxMapCamera alloc] initWithCenter:_camera.center
                                               zoom:_camera.zoom
                                            bearing:nil
                                               pitch:_camera.pitch
                                              anchor:_camera.anchor];
    [self scheduleRender];
    return;
  }
  if (!isfinite((double)value) || value < 0.0 || value >= 360.0) {
    [self emitErrorCode:LynxMapProviderErrorInvalidConfiguration
                message:@"bearing 必须在 0 到 360 之间（不含 360）。"];
    return;
  }
  _camera = [[LynxMapCamera alloc] initWithCenter:_camera.center
                                             zoom:_camera.zoom
                                          bearing:@((double)value)
                                             pitch:_camera.pitch
                                            anchor:_camera.anchor];
  [self scheduleRender];
}

LYNX_PROP_SETTER("pitch", setPitch, CGFloat) {
  if (requestReset) {
    _camera = [[LynxMapCamera alloc] initWithCenter:_camera.center
                                               zoom:_camera.zoom
                                            bearing:_camera.bearing
                                               pitch:nil
                                              anchor:_camera.anchor];
    [self scheduleRender];
    return;
  }
  if (!isfinite((double)value) || value < 0.0 || value > 60.0) {
    [self emitErrorCode:LynxMapProviderErrorInvalidConfiguration
                message:@"pitch 必须在 0 到 60 之间。"];
    return;
  }
  _camera = [[LynxMapCamera alloc] initWithCenter:_camera.center
                                             zoom:_camera.zoom
                                          bearing:_camera.bearing
                                             pitch:@((double)value)
                                            anchor:_camera.anchor];
  [self scheduleRender];
}

LYNX_PROP_SETTER("anchor", setAnchor, NSDictionary *) {
  if (requestReset) {
    _camera = [[LynxMapCamera alloc] initWithCenter:_camera.center
                                               zoom:_camera.zoom
                                            bearing:_camera.bearing
                                               pitch:_camera.pitch
                                              anchor:nil];
    [self scheduleRender];
    return;
  }
  NSError *error = nil;
  LynxMapCamera *patch = [LynxMapCamera cameraWithObject:@{ @"anchor" : value ?: @{} }
                                                         error:&error];
  if (patch == nil) {
    [self emitError:error ?: LynxMapMakeProviderError(
                               LynxMapProviderErrorInvalidConfiguration,
                               @"anchor 参数无效。")];
    return;
  }
  _camera = [self cameraByApplyingPatch:patch];
  [self scheduleRender];
}

LYNX_PROP_SETTER("markers", setMarkers, NSArray *) {
  if (requestReset) {
    _markers = @[];
    [self scheduleRender];
    return;
  }
  if (![value isKindOfClass:[NSArray class]] || value.count > LynxMapMaximumMarkerCount) {
    [self emitErrorCode:LynxMapProviderErrorInvalidConfiguration
                message:@"markers 必须是有界数组，数量不能超过 200。"];
    return;
  }

  NSMutableArray<LynxMapMarker *> *markers = [NSMutableArray arrayWithCapacity:value.count];
  NSMutableSet<NSString *> *markerIDs = [NSMutableSet setWithCapacity:value.count];
  for (NSUInteger index = 0; index < value.count; index++) {
    NSError *error = nil;
    LynxMapMarker *marker = [LynxMapMarker markerWithObject:value[index] index:index error:&error];
    if (marker == nil) {
      [self emitError:error ?: LynxMapMakeProviderError(LynxMapProviderErrorInvalidConfiguration,
                                                        @"markers 配置无效。")];
      return;
    }
    if ([markerIDs containsObject:marker.identifier]) {
      [self emitErrorCode:LynxMapProviderErrorInvalidConfiguration
                  message:@"markers.id 不能重复。"];
      return;
    }
    [markerIDs addObject:marker.identifier];
    [markers addObject:marker];
  }
  _markers = markers.copy;
  [self scheduleRender];
}

LYNX_PROP_SETTER("polylines", setPolylines, NSArray *) {
  if (requestReset) {
    _polylines = @[];
    [self scheduleRender];
    return;
  }
  if (![value isKindOfClass:[NSArray class]] || value.count > LynxMapMaximumPolylineCount) {
    [self emitErrorCode:LynxMapProviderErrorInvalidConfiguration
                message:@"polylines 必须是有界数组，数量不能超过 50。"];
    return;
  }

  NSMutableArray<LynxMapPolyline *> *polylines = [NSMutableArray arrayWithCapacity:value.count];
  NSMutableSet<NSString *> *polylineIDs = [NSMutableSet setWithCapacity:value.count];
  NSUInteger totalPointCount = 0;
  for (NSUInteger index = 0; index < value.count; index++) {
    NSError *error = nil;
    LynxMapPolyline *polyline =
        [LynxMapPolyline polylineWithObject:value[index] index:index error:&error];
    if (polyline == nil) {
      [self emitError:error ?: LynxMapMakeProviderError(LynxMapProviderErrorInvalidConfiguration,
                                                        @"polylines 配置无效。")];
      return;
    }
    if ([polylineIDs containsObject:polyline.identifier]) {
      [self emitErrorCode:LynxMapProviderErrorInvalidConfiguration
                  message:@"polylines.id 不能重复。"];
      return;
    }
    [polylineIDs addObject:polyline.identifier];
    totalPointCount += polyline.points.count;
    if (totalPointCount > LynxMapMaximumTotalPolylinePointCount) {
      [self emitErrorCode:LynxMapProviderErrorInvalidConfiguration
                  message:@"polylines 总点数不能超过 5000。"];
      return;
    }
    [polylines addObject:polyline];
  }
  _polylines = polylines.copy;
  [self scheduleRender];
}

LYNX_PROP_SETTER("mass-points", setMassPoints, NSArray *) {
  if (requestReset) {
    _massPoints = @[];
    [self scheduleRender];
    return;
  }
  if (![value isKindOfClass:[NSArray class]] || value.count > LynxMapMaximumMassPointCount) {
    [self emitErrorCode:LynxMapProviderErrorInvalidConfiguration
                message:@"mass-points 必须是有界数组，数量不能超过 5000。"];
    return;
  }
  NSMutableArray<LynxMapMassPoint *> *points = [NSMutableArray arrayWithCapacity:value.count];
  NSMutableSet<NSString *> *identifiers = [NSMutableSet setWithCapacity:value.count];
  for (NSUInteger index = 0; index < value.count; index++) {
    NSError *error = nil;
    LynxMapMassPoint *point = [LynxMapMassPoint massPointWithObject:value[index]
                                                                 index:index
                                                                 error:&error];
    if (point == nil) {
      [self emitError:error ?: LynxMapMakeProviderError(LynxMapProviderErrorInvalidConfiguration,
                                                        @"mass-points 配置无效。")];
      return;
    }
    if ([identifiers containsObject:point.identifier]) {
      [self emitErrorCode:LynxMapProviderErrorInvalidConfiguration
                  message:@"mass-points.id 不能重复。"];
      return;
    }
    [identifiers addObject:point.identifier];
    [points addObject:point];
  }
  _massPoints = points.copy;
  [self scheduleRender];
}

LYNX_PROP_SETTER("layer-visible", setLayerVisible, BOOL) {
  BOOL visible = requestReset ? YES : value;
  _layerState = [[LynxMapLayerState alloc] initWithVisible:visible
                                                   opacity:_layerState.opacity
                                                    zIndex:_layerState.zIndex
                                                   mapType:_layerState.mapType
                                            trafficEnabled:_layerState.trafficEnabled];
  [self scheduleRender];
}

LYNX_PROP_SETTER("layer-opacity", setLayerOpacity, CGFloat) {
  if (requestReset) {
    _layerState = [[LynxMapLayerState alloc] initWithVisible:_layerState.visible
                                                     opacity:1.0
                                                      zIndex:_layerState.zIndex
                                                     mapType:_layerState.mapType
                                              trafficEnabled:_layerState.trafficEnabled];
    [self scheduleRender];
    return;
  }
  if (!isfinite((double)value) || value < 0.0 || value > 1.0) {
    [self emitErrorCode:LynxMapProviderErrorInvalidConfiguration
                message:@"layer-opacity 必须在 0 到 1 之间。"];
    return;
  }
  _layerState = [[LynxMapLayerState alloc] initWithVisible:_layerState.visible
                                                   opacity:(double)value
                                                    zIndex:_layerState.zIndex
                                                   mapType:_layerState.mapType
                                            trafficEnabled:_layerState.trafficEnabled];
  [self scheduleRender];
}

LYNX_PROP_SETTER("layer-z-index", setLayerZIndex, NSInteger) {
  if (!requestReset &&
      (value < -LynxMapMaximumZIndexMagnitude || value > LynxMapMaximumZIndexMagnitude)) {
    [self emitErrorCode:LynxMapProviderErrorInvalidConfiguration
                message:@"layer-z-index 超出允许范围。"];
    return;
  }
  _layerState = [[LynxMapLayerState alloc] initWithVisible:_layerState.visible
                                                   opacity:_layerState.opacity
                                                    zIndex:requestReset ? 0 : value
                                                   mapType:_layerState.mapType
                                            trafficEnabled:_layerState.trafficEnabled];
  [self scheduleRender];
}

LYNX_PROP_SETTER("map-type", setMapType, NSString *) {
  NSString *mapType = requestReset ? @"standard" : value;
  if (![mapType isKindOfClass:[NSString class]]) {
    [self emitErrorCode:LynxMapProviderErrorInvalidConfiguration
                message:@"map-type 必须是字符串。"];
    return;
  }
  mapType = mapType.lowercaseString;
  NSSet<NSString *> *supportedTypes =
      [NSSet setWithArray:@[@"standard", @"satellite", @"night", @"navi", @"bus", @"navi-night"]];
  if (![supportedTypes containsObject:mapType]) {
    [self emitErrorCode:LynxMapProviderErrorUnsupportedCapability
                message:@"当前地图 provider 不支持该 map-type。"];
    return;
  }
  _layerState = [[LynxMapLayerState alloc] initWithVisible:_layerState.visible
                                                   opacity:_layerState.opacity
                                                    zIndex:_layerState.zIndex
                                                   mapType:mapType
                                            trafficEnabled:_layerState.trafficEnabled];
  [self scheduleRender];
}

LYNX_PROP_SETTER("traffic-enabled", setTrafficEnabled, BOOL) {
  _layerState = [[LynxMapLayerState alloc] initWithVisible:_layerState.visible
                                                   opacity:_layerState.opacity
                                                    zIndex:_layerState.zIndex
                                                   mapType:_layerState.mapType
                                            trafficEnabled:requestReset ? NO : value];
  [self scheduleRender];
}

LYNX_PROP_SETTER("zoom-enabled", setZoomEnabled, BOOL) {
  [self updateViewOptionsWithZoomEnabled:requestReset ? YES : value
                           scrollEnabled:_viewOptions.scrollEnabled
                           rotateEnabled:_viewOptions.rotateEnabled
                     rotateCameraEnabled:_viewOptions.rotateCameraEnabled
                           showsCompass:_viewOptions.showsCompass
                             showsScale:_viewOptions.showsScale
                            showsLabels:_viewOptions.showsLabels
                         showsBuildings:_viewOptions.showsBuildings
                         touchPOIEnabled:_viewOptions.touchPOIEnabled];
}

LYNX_PROP_SETTER("scroll-enabled", setScrollEnabled, BOOL) {
  [self updateViewOptionsWithZoomEnabled:_viewOptions.zoomEnabled
                           scrollEnabled:requestReset ? YES : value
                           rotateEnabled:_viewOptions.rotateEnabled
                     rotateCameraEnabled:_viewOptions.rotateCameraEnabled
                           showsCompass:_viewOptions.showsCompass
                             showsScale:_viewOptions.showsScale
                            showsLabels:_viewOptions.showsLabels
                         showsBuildings:_viewOptions.showsBuildings
                         touchPOIEnabled:_viewOptions.touchPOIEnabled];
}

LYNX_PROP_SETTER("rotate-enabled", setRotateEnabled, BOOL) {
  [self updateViewOptionsWithZoomEnabled:_viewOptions.zoomEnabled
                           scrollEnabled:_viewOptions.scrollEnabled
                           rotateEnabled:requestReset ? YES : value
                     rotateCameraEnabled:_viewOptions.rotateCameraEnabled
                           showsCompass:_viewOptions.showsCompass
                             showsScale:_viewOptions.showsScale
                            showsLabels:_viewOptions.showsLabels
                         showsBuildings:_viewOptions.showsBuildings
                         touchPOIEnabled:_viewOptions.touchPOIEnabled];
}

LYNX_PROP_SETTER("rotate-camera-enabled", setRotateCameraEnabled, BOOL) {
  [self updateViewOptionsWithZoomEnabled:_viewOptions.zoomEnabled
                           scrollEnabled:_viewOptions.scrollEnabled
                           rotateEnabled:_viewOptions.rotateEnabled
                     rotateCameraEnabled:requestReset ? YES : value
                           showsCompass:_viewOptions.showsCompass
                             showsScale:_viewOptions.showsScale
                            showsLabels:_viewOptions.showsLabels
                         showsBuildings:_viewOptions.showsBuildings
                         touchPOIEnabled:_viewOptions.touchPOIEnabled];
}

LYNX_PROP_SETTER("shows-compass", setShowsCompass, BOOL) {
  [self updateViewOptionsWithZoomEnabled:_viewOptions.zoomEnabled
                           scrollEnabled:_viewOptions.scrollEnabled
                           rotateEnabled:_viewOptions.rotateEnabled
                     rotateCameraEnabled:_viewOptions.rotateCameraEnabled
                           showsCompass:requestReset ? NO : value
                             showsScale:_viewOptions.showsScale
                            showsLabels:_viewOptions.showsLabels
                         showsBuildings:_viewOptions.showsBuildings
                         touchPOIEnabled:_viewOptions.touchPOIEnabled];
}

LYNX_PROP_SETTER("shows-scale", setShowsScale, BOOL) {
  [self updateViewOptionsWithZoomEnabled:_viewOptions.zoomEnabled
                           scrollEnabled:_viewOptions.scrollEnabled
                           rotateEnabled:_viewOptions.rotateEnabled
                     rotateCameraEnabled:_viewOptions.rotateCameraEnabled
                           showsCompass:_viewOptions.showsCompass
                             showsScale:requestReset ? NO : value
                            showsLabels:_viewOptions.showsLabels
                         showsBuildings:_viewOptions.showsBuildings
                         touchPOIEnabled:_viewOptions.touchPOIEnabled];
}

LYNX_PROP_SETTER("shows-labels", setShowsLabels, BOOL) {
  [self updateViewOptionsWithZoomEnabled:_viewOptions.zoomEnabled
                           scrollEnabled:_viewOptions.scrollEnabled
                           rotateEnabled:_viewOptions.rotateEnabled
                     rotateCameraEnabled:_viewOptions.rotateCameraEnabled
                           showsCompass:_viewOptions.showsCompass
                             showsScale:_viewOptions.showsScale
                            showsLabels:requestReset ? YES : value
                         showsBuildings:_viewOptions.showsBuildings
                         touchPOIEnabled:_viewOptions.touchPOIEnabled];
}

LYNX_PROP_SETTER("shows-buildings", setShowsBuildings, BOOL) {
  [self updateViewOptionsWithZoomEnabled:_viewOptions.zoomEnabled
                           scrollEnabled:_viewOptions.scrollEnabled
                           rotateEnabled:_viewOptions.rotateEnabled
                     rotateCameraEnabled:_viewOptions.rotateCameraEnabled
                           showsCompass:_viewOptions.showsCompass
                             showsScale:_viewOptions.showsScale
                            showsLabels:_viewOptions.showsLabels
                         showsBuildings:requestReset ? YES : value
                         touchPOIEnabled:_viewOptions.touchPOIEnabled];
}

LYNX_PROP_SETTER("touch-poi-enabled", setTouchPOIEnabled, BOOL) {
  [self updateViewOptionsWithZoomEnabled:_viewOptions.zoomEnabled
                           scrollEnabled:_viewOptions.scrollEnabled
                           rotateEnabled:_viewOptions.rotateEnabled
                     rotateCameraEnabled:_viewOptions.rotateCameraEnabled
                           showsCompass:_viewOptions.showsCompass
                             showsScale:_viewOptions.showsScale
                            showsLabels:_viewOptions.showsLabels
                         showsBuildings:_viewOptions.showsBuildings
                         touchPOIEnabled:requestReset ? NO : value];
}

LYNX_UI_METHOD(moveCamera) {
  if (_destroyed) {
    if (callback != nil) {
      callback(kUIMethodInvalidStateError,
               [self methodErrorData:LynxMapMakeProviderError(LynxMapProviderErrorCancelled,
                                                               @"地图 Element 已销毁。")]);
    }
    return;
  }
  NSDictionary *input = [params isKindOfClass:[NSDictionary class]] ? params : @{};
  id cameraObject = input[@"camera"];
  if (![cameraObject isKindOfClass:[NSDictionary class]]) {
    cameraObject = input;
  }
  NSError *error = nil;
  LynxMapCamera *camera = [LynxMapCamera cameraWithObject:cameraObject error:&error];
  BOOL animated = YES;
  if (camera == nil || !LynxMapReadAnimated(input, &animated, &error)) {
    if (callback != nil) {
      callback(kUIMethodParamInvalid, [self methodErrorData:error ?: LynxMapMakeProviderError(
                                                        LynxMapProviderErrorInvalidConfiguration,
                                                        @"moveCamera 参数无效。")]);
    }
    return;
  }
  if (_providerMapView == nil || !_providerReady) {
    if (callback != nil) {
      callback(kUIMethodInvalidStateError,
               [self methodErrorData:LynxMapMakeProviderError(LynxMapProviderErrorInvalidOperation,
                                                               @"地图尚未 ready。")]);
    }
    return;
  }
  if ((_adapter.capabilities & LynxMapProviderCapabilityCamera) == 0) {
    if (callback != nil) {
      callback(kUIMethodOperationError,
               [self methodErrorData:LynxMapMakeProviderError(
                                           LynxMapProviderErrorUnsupportedCapability,
                                           @"当前 provider 不支持 moveCamera。")]);
    }
    return;
  }

  NSUInteger generation = _generation;
  LynxMapPendingOperation *operation =
      [self beginPendingOperationWithCallback:callback generation:generation];
  if (operation == nil) {
    if (callback != nil) {
      callback(kUIMethodOperationError,
               [self methodErrorData:LynxMapMakeProviderError(
                                           LynxMapProviderErrorInvalidOperation,
                                           @"地图待处理操作已达到上限。")]);
    }
    return;
  }
  operation.cameraCommandSequence = ++_latestCameraCommandSequence;
  id<LynxMapProviderMapView> mapView = _providerMapView;
  __weak LynxMapUI *weakSelf = self;
  [_adapter moveCamera:camera
              mapView:mapView
             animated:animated
           completion:^(NSError *operationError) {
             LynxMapUI *strongSelf = weakSelf;
             if (strongSelf == nil) {
               return;
             }
             if (operationError == nil && operation.cameraCommandSequence ==
                                             strongSelf->_latestCameraCommandSequence &&
                 operation.generation == strongSelf->_generation && !strongSelf->_destroyed) {
               strongSelf->_camera = [strongSelf cameraByApplyingPatch:camera];
               [strongSelf scheduleRender];
             }
             [strongSelf finishPendingOperation:operation
                                      generation:generation
                                            error:operationError
                                  successData:@{ @"accepted" : @YES }];
           }];
}

LYNX_UI_METHOD(fitBounds) {
  if (_destroyed) {
    if (callback != nil) {
      callback(kUIMethodInvalidStateError,
               [self methodErrorData:LynxMapMakeProviderError(LynxMapProviderErrorCancelled,
                                                               @"地图 Element 已销毁。")]);
    }
    return;
  }
  NSDictionary *input = [params isKindOfClass:[NSDictionary class]] ? params : @{};
  id boundsObject = input[@"bounds"];
  if (![boundsObject isKindOfClass:[NSDictionary class]]) {
    boundsObject = input;
  }
  NSError *error = nil;
  LynxMapBounds *bounds = [LynxMapBounds boundsWithObject:boundsObject error:&error];
  UIEdgeInsets padding = UIEdgeInsetsZero;
  BOOL animated = YES;
  if (bounds == nil || !LynxMapReadPadding(input[@"padding"], &padding, &error) ||
      !LynxMapReadAnimated(input, &animated, &error)) {
    if (callback != nil) {
      callback(kUIMethodParamInvalid, [self methodErrorData:error ?: LynxMapMakeProviderError(
                                                        LynxMapProviderErrorInvalidConfiguration,
                                                        @"fitBounds 参数无效。")]);
    }
    return;
  }
  if (_providerMapView == nil || !_providerReady) {
    if (callback != nil) {
      callback(kUIMethodInvalidStateError,
               [self methodErrorData:LynxMapMakeProviderError(LynxMapProviderErrorInvalidOperation,
                                                               @"地图尚未 ready。")]);
    }
    return;
  }
  if ((_adapter.capabilities & LynxMapProviderCapabilityFitBounds) == 0) {
    if (callback != nil) {
      callback(kUIMethodOperationError,
               [self methodErrorData:LynxMapMakeProviderError(
                                           LynxMapProviderErrorUnsupportedCapability,
                                           @"当前 provider 不支持 fitBounds。")]);
    }
    return;
  }

  NSUInteger generation = _generation;
  LynxMapPendingOperation *operation =
      [self beginPendingOperationWithCallback:callback generation:generation];
  if (operation == nil) {
    if (callback != nil) {
      callback(kUIMethodOperationError,
               [self methodErrorData:LynxMapMakeProviderError(
                                           LynxMapProviderErrorInvalidOperation,
                                           @"地图待处理操作已达到上限。")]);
    }
    return;
  }
  id<LynxMapProviderMapView> mapView = _providerMapView;
  __weak LynxMapUI *weakSelf = self;
  [_adapter fitBounds:bounds
              mapView:mapView
              padding:padding
             animated:animated
           completion:^(NSError *operationError) {
             LynxMapUI *strongSelf = weakSelf;
             if (strongSelf == nil) {
               return;
             }
             if (operationError == nil && operation.generation == strongSelf->_generation &&
                 !strongSelf->_destroyed) {
               // fitBounds 改变的是 provider 的实际可见区域；同步回 Element 状态，避免
               // 后续只更新图层时用旧 camera 把地图跳回去。
               NSError *cameraError = nil;
               LynxMapCamera *currentCamera =
                   [strongSelf->_adapter currentCameraForMapView:mapView error:&cameraError];
               if (currentCamera != nil) {
                 strongSelf->_camera = currentCamera;
               }
             }
             [strongSelf finishPendingOperation:operation
                                      generation:generation
                                            error:operationError
                                  successData:@{ @"accepted" : @YES }];
           }];
}

LYNX_UI_METHOD(selectMarker) {
  [self setMarkerSelectionWithParams:params callback:callback selected:YES];
}

LYNX_UI_METHOD(deselectMarker) {
  [self setMarkerSelectionWithParams:params callback:callback selected:NO];
}

- (void)setMarkerSelectionWithParams:(id)params
                            callback:(LynxUIMethodCallbackBlock)callback
                            selected:(BOOL)selected {
  if (_destroyed) {
    if (callback != nil) {
      callback(kUIMethodInvalidStateError,
               [self methodErrorData:LynxMapMakeProviderError(LynxMapProviderErrorCancelled,
                                                               @"地图 Element 已销毁。")]);
    }
    return;
  }
  NSDictionary *input = [params isKindOfClass:[NSDictionary class]] ? params : @{};
  NSString *identifier = input[@"id"] ?: input[@"identifier"];
  if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0 ||
      identifier.length > LynxMapMaximumIdentifierLength) {
    if (callback != nil) {
      callback(kUIMethodParamInvalid,
               [self methodErrorData:LynxMapMakeProviderError(
                                           LynxMapProviderErrorInvalidConfiguration,
                                           @"marker id 无效。")]);
    }
    return;
  }
  BOOL animated = YES;
  NSError *error = nil;
  if (!LynxMapReadAnimated(input, &animated, &error)) {
    if (callback != nil) callback(kUIMethodParamInvalid, [self methodErrorData:error]);
    return;
  }
  if (_providerMapView == nil || !_providerReady || _adapter == nil) {
    if (callback != nil) {
      callback(kUIMethodInvalidStateError,
               [self methodErrorData:LynxMapMakeProviderError(LynxMapProviderErrorInvalidOperation,
                                                               @"地图尚未 ready。")]);
    }
    return;
  }
  if ((_adapter.capabilities & LynxMapProviderCapabilityMarkerSelection) == 0) {
    if (callback != nil) {
      callback(kUIMethodOperationError,
               [self methodErrorData:LynxMapMakeProviderError(
                                           LynxMapProviderErrorUnsupportedCapability,
                                           @"当前 provider 不支持 marker 选择。")]);
    }
    return;
  }
  NSUInteger generation = _generation;
  LynxMapPendingOperation *operation =
      [self beginPendingOperationWithCallback:callback generation:generation];
  if (operation == nil) {
    if (callback != nil) {
      callback(kUIMethodOperationError,
               [self methodErrorData:LynxMapMakeProviderError(
                                           LynxMapProviderErrorInvalidOperation,
                                           @"地图待处理操作已达到上限。")]);
    }
    return;
  }
  __weak LynxMapUI *weakSelf = self;
  [_adapter setMarkerWithIdentifier:identifier
                             selected:selected
                              mapView:_providerMapView
                             animated:animated
                           completion:^(NSError *operationError) {
    LynxMapUI *strongSelf = weakSelf;
    if (strongSelf == nil) return;
    [strongSelf finishPendingOperation:operation
                              generation:generation
                                    error:operationError
                          successData:@{ @"accepted" : @YES, @"id" : identifier }];
  }];
}

LYNX_UI_METHOD(showMarkers) {
  if (_destroyed) {
    if (callback != nil) {
      callback(kUIMethodInvalidStateError,
               [self methodErrorData:LynxMapMakeProviderError(LynxMapProviderErrorCancelled,
                                                               @"地图 Element 已销毁。")]);
    }
    return;
  }
  NSDictionary *input = [params isKindOfClass:[NSDictionary class]] ? params : @{};
  NSArray *identifiers = input[@"ids"] ?: input[@"identifiers"];
  if (![identifiers isKindOfClass:[NSArray class]] || identifiers.count == 0 ||
      identifiers.count > LynxMapMaximumMarkerCount) {
    if (callback != nil) {
      callback(kUIMethodParamInvalid,
               [self methodErrorData:LynxMapMakeProviderError(
                                           LynxMapProviderErrorInvalidConfiguration,
                                           @"showMarkers.ids 必须是非空有界数组。")]);
    }
    return;
  }
  for (id identifier in identifiers) {
    if (![identifier isKindOfClass:[NSString class]] || [identifier length] == 0 ||
        [identifier length] > LynxMapMaximumIdentifierLength) {
      if (callback != nil) {
        callback(kUIMethodParamInvalid,
                 [self methodErrorData:LynxMapMakeProviderError(
                                             LynxMapProviderErrorInvalidConfiguration,
                                             @"showMarkers.ids 包含无效 id。")]);
      }
      return;
    }
  }
  UIEdgeInsets padding = UIEdgeInsetsZero;
  BOOL animated = YES;
  NSError *error = nil;
  if (!LynxMapReadPadding(input[@"padding"], &padding, &error) ||
      !LynxMapReadAnimated(input, &animated, &error)) {
    if (callback != nil) callback(kUIMethodParamInvalid, [self methodErrorData:error]);
    return;
  }
  if (_providerMapView == nil || !_providerReady || _adapter == nil) {
    if (callback != nil) {
      callback(kUIMethodInvalidStateError,
               [self methodErrorData:LynxMapMakeProviderError(LynxMapProviderErrorInvalidOperation,
                                                               @"地图尚未 ready。")]);
    }
    return;
  }
  NSUInteger generation = _generation;
  LynxMapPendingOperation *operation =
      [self beginPendingOperationWithCallback:callback generation:generation];
  if (operation == nil) {
    if (callback != nil) {
      callback(kUIMethodOperationError,
               [self methodErrorData:LynxMapMakeProviderError(
                                           LynxMapProviderErrorInvalidOperation,
                                           @"地图待处理操作已达到上限。")]);
    }
    return;
  }
  __weak LynxMapUI *weakSelf = self;
  [_adapter showMarkersWithIdentifiers:identifiers
                              mapView:_providerMapView
                              padding:padding
                             animated:animated
                           completion:^(NSError *operationError) {
    LynxMapUI *strongSelf = weakSelf;
    if (strongSelf == nil) return;
    [strongSelf finishPendingOperation:operation
                              generation:generation
                                    error:operationError
                          successData:@{ @"accepted" : @YES, @"count" : @(identifiers.count) }];
  }];
}

LYNX_UI_METHOD(getCapabilities) {
  id<LynxMapProviderAdapter> adapter = _adapter ?: [LynxMapProviderRegistry makeAdapter];
  LynxMapProviderCapabilities capabilities = adapter.capabilities;
  LynxMapProviderConfiguration *hostConfiguration = [LynxMapProviderRegistry defaultConfiguration];
  BOOL hostConfigured = hostConfiguration.providerKey.length > 0 && hostConfiguration.privacyAgreed;
  BOOL available = adapter.available && hostConfigured;
  NSMutableDictionary *features = [NSMutableDictionary dictionaryWithDictionary:@{
    @"camera.move" : @((capabilities & LynxMapProviderCapabilityCamera) != 0),
    @"camera.read" : @((capabilities & LynxMapProviderCapabilityCamera) != 0),
    @"camera.fitBounds" : @((capabilities & LynxMapProviderCapabilityFitBounds) != 0),
    @"map.projectCoordinate" : @((capabilities & LynxMapProviderCapabilityCamera) != 0),
    @"camera.bearing" : @((capabilities & LynxMapProviderCapabilityCamera3D) != 0),
    @"camera.pitch" : @((capabilities & LynxMapProviderCapabilityCamera3D) != 0),
    @"camera.anchor" : @((capabilities & LynxMapProviderCapabilityCamera3D) != 0),
    @"map.tap" : @((capabilities & LynxMapProviderCapabilityMapTap) != 0),
    @"map.longPress" : @((capabilities & LynxMapProviderCapabilityLongPress) != 0),
    @"overlay.marker" : @((capabilities & LynxMapProviderCapabilityMarkers) != 0),
    @"overlay.polyline" : @((capabilities & LynxMapProviderCapabilityPolylines) != 0),
    @"overlay.massPoints" : @((capabilities & LynxMapProviderCapabilityMassPoints) != 0),
    @"overlay.layerVisibility" : @((capabilities & LynxMapProviderCapabilityLayerVisibility) != 0),
    @"overlay.layerOpacity" : @((capabilities & LynxMapProviderCapabilityLayerOpacity) != 0),
    @"overlay.layerZIndex" : @((capabilities & LynxMapProviderCapabilityLayerZIndexWithinTier) != 0),
    @"overlay.markerZIndex" : @((capabilities & LynxMapProviderCapabilityMarkerZIndex) != 0),
    @"marker.selection" : @((capabilities & LynxMapProviderCapabilityMarkerSelection) != 0),
    @"marker.drag" : @((capabilities & LynxMapProviderCapabilityMarkerLongPress) != 0),
    @"marker.icon" : @((capabilities & LynxMapProviderCapabilityMarkerIcon) != 0),
    @"marker.view" : @((capabilities & LynxMapProviderCapabilityMarkerView) != 0),
    @"massPoints" : @((capabilities & LynxMapProviderCapabilityMassPoints) != 0),
    @"amap.traffic" : @((capabilities & LynxMapProviderCapabilityTrafficLayer) != 0),
    @"lifecycle.pauseResume" : @((capabilities & LynxMapProviderCapabilityPauseResume) != 0),
    @"interaction.gestures" : @((capabilities & LynxMapProviderCapabilityGestureOptions) != 0),
    @"controls.native" : @((capabilities & LynxMapProviderCapabilityMapControls) != 0),
  }];
  if ((capabilities & LynxMapProviderCapabilityLayerZIndexWithinTier) != 0) {
    features[@"amap.overlayLevels"] = @[ @"aboveRoads", @"aboveLabels" ];
  }
  if ((capabilities & LynxMapProviderCapabilityLayerVisibility) != 0) {
    features[@"amap.layers"] = @[ @"base", @"traffic", @"marker", @"polyline" ];
  }
  NSMutableDictionary *snapshot = [NSMutableDictionary dictionaryWithDictionary:@{
    @"schemaVersion" : @1,
    @"contractVersion" : @3,
    @"available" : @(available),
    @"provider" : adapter.providerIdentifier ?: @"unavailable",
    @"features" : features.copy,
    @"apiCatalog" : @{
      @"element" : @[
        @"camera.center", @"camera.zoom", @"camera.bearing", @"camera.pitch",
        @"camera.anchor", @"camera.fitBounds", @"map.projectCoordinate", @"map.tap", @"map.regionChange",
        @"overlay.marker", @"marker.icon", @"marker.view", @"overlay.polyline", @"overlay.massPoints", @"overlay.visibility",
        @"overlay.opacity", @"overlay.zIndex", @"map.mapType", @"map.traffic",
        @"interaction.gestures", @"controls.native", @"lifecycle.pauseResume",
      ],
      @"service" : @[ @"poi.search", @"geocode", @"route.plan", @"route.transit", @"location.getCurrent", @"location.start/stop" ],
      @"nativePage" : @[ @"navigation", @"massPoints", @"indoor", @"offlineMap" ],
    },
    @"limits" : @{
      @"markers" : @(LynxMapMaximumMarkerCount),
      @"identifierLength" : @(LynxMapMaximumIdentifierLength),
      @"markerTextLength" : @(LynxMapMaximumMarkerTextLength),
      @"colorLength" : @(LynxMapMaximumColorLength),
      @"polylines" : @(LynxMapMaximumPolylineCount),
      @"massPoints" : @(LynxMapMaximumMassPointCount),
      @"polylinePointsPerPath" : @(LynxMapMaximumPolylinePointCount),
      @"polylinePointsTotal" : @(LynxMapMaximumTotalPolylinePointCount),
      @"zoomMin" : @(LynxMapMinimumZoom),
      @"zoomMax" : @(LynxMapMaximumZoom),
      @"polylineWidthMax" : @(LynxMapMaximumPolylineWidth),
      @"fitBoundsPaddingMax" : @(LynxMapMaximumPadding),
      @"zIndexMagnitudeMax" : @(LynxMapMaximumZIndexMagnitude),
    },
  }];
  if (adapter.availabilityError != nil) {
    snapshot[@"reasonCode"] = LynxMapProviderErrorName(adapter.availabilityError);
  } else if (!hostConfiguration.privacyAgreed) {
    snapshot[@"reasonCode"] = LynxMapProviderErrorName(
        LynxMapMakeProviderError(LynxMapProviderErrorPrivacyNotConfigured, @"地图隐私配置未完成。"));
  } else if (hostConfiguration.providerKey.length == 0) {
    snapshot[@"reasonCode"] = LynxMapProviderErrorName(
        LynxMapMakeProviderError(LynxMapProviderErrorMissingAPIKey, @"地图 Key 未配置。"));
  }
  if (callback != nil) {
    callback(kUIMethodSuccess, snapshot.copy);
  }
}

LYNX_UI_METHOD(getCamera) {
  if (_destroyed || _providerMapView == nil || !_providerReady || _adapter == nil) {
    if (callback != nil) {
      callback(kUIMethodInvalidStateError,
               [self methodErrorData:LynxMapMakeProviderError(LynxMapProviderErrorInvalidOperation,
                                                               @"地图尚未 ready。")]);
    }
    return;
  }
  NSError *error = nil;
  LynxMapCamera *camera = [_adapter currentCameraForMapView:_providerMapView error:&error];
  if (camera == nil) {
    if (callback != nil) {
      callback(kUIMethodOperationError,
               [self methodErrorData:error ?: LynxMapMakeProviderError(
                                           LynxMapProviderErrorInvalidOperation,
                                           @"地图相机读取失败。")]);
    }
    return;
  }
  if (callback != nil) {
    callback(kUIMethodSuccess, camera.dictionaryValue);
  }
}

LYNX_UI_METHOD(getCameraState) {
  // 保留 getCamera 的 v1 名称，同时提供语义明确的完整 camera 状态读取入口。
  if (_destroyed || _providerMapView == nil || !_providerReady || _adapter == nil) {
    if (callback != nil) {
      callback(kUIMethodInvalidStateError,
               [self methodErrorData:LynxMapMakeProviderError(LynxMapProviderErrorInvalidOperation,
                                                               @"地图尚未 ready。")]);
    }
    return;
  }
  NSError *error = nil;
  LynxMapCamera *camera = [_adapter currentCameraForMapView:_providerMapView error:&error];
  if (camera == nil) {
    if (callback != nil) {
      callback(kUIMethodOperationError,
               [self methodErrorData:error ?: LynxMapMakeProviderError(
                                           LynxMapProviderErrorInvalidOperation,
                                           @"地图相机状态读取失败。")]);
    }
    return;
  }
  if (callback != nil) {
    callback(kUIMethodSuccess, camera.dictionaryValue);
  }
}

LYNX_UI_METHOD(projectCoordinate) {
  if (_destroyed || _providerMapView == nil || !_providerReady || _adapter == nil) {
    if (callback != nil) {
      callback(kUIMethodInvalidStateError,
               [self methodErrorData:LynxMapMakeProviderError(LynxMapProviderErrorInvalidOperation,
                                                               @"地图尚未 ready。")]);
    }
    return;
  }
  id coordinateObject = [params isKindOfClass:[NSDictionary class]] ? params[@"coordinate"] : params;
  NSError *error = nil;
  LynxMapCoordinate *coordinate = [LynxMapCoordinate coordinateWithObject:coordinateObject error:&error];
  if (coordinate == nil) {
    if (callback != nil) callback(kUIMethodParamInvalid, [self methodErrorData:error]);
    return;
  }
  NSDictionary *point = [_adapter screenPointForCoordinate:coordinate mapView:_providerMapView error:&error];
  if (point == nil) {
    if (callback != nil) callback(kUIMethodOperationError, [self methodErrorData:error]);
    return;
  }
  if (callback != nil) callback(kUIMethodSuccess, point);
}

LYNX_UI_METHOD(getPerformanceSnapshot) {
  if (callback != nil) {
    callback(kUIMethodSuccess, @{
      @"schemaVersion" : @1,
      @"applyCount" : @(_applyCount),
      @"lastApplyDurationMs" : @(_lastApplyDurationMs),
      @"markerCount" : @(_lastMarkerCount),
      @"polylineCount" : @(_lastPolylineCount),
      @"massPointCount" : @(_lastMassPointCount),
      @"pendingRender" : @(_pendingRenderTask != nil),
      @"providerReady" : @(_providerReady),
      @"fps" : [NSNull null],
      @"frameTimeMs" : [NSNull null],
      @"note" : @"FPS/frame time 需要 CADisplayLink 或 Instruments Animation Hitches 采样。",
    });
  }
}

- (void)ensureProviderMap {
  if (_destroyed || _attemptedStart || _providerMapView != nil) {
    return;
  }
  _attemptedStart = YES;
  _adapter = [LynxMapProviderRegistry makeAdapter];
  if (_adapter == nil || !_adapter.available) {
    [self emitError:_adapter.availabilityError ?: LynxMapMakeProviderError(
                                           LynxMapProviderErrorUnavailable,
                                           @"地图 provider 不可用，请先接入对应 SDK。")];
    return;
  }

  LynxMapProviderEventSinkBridge *eventSink = [[LynxMapProviderEventSinkBridge alloc] init];
  eventSink.owner = self;
  eventSink.generation = _generation;
  _eventSink = eventSink;

  NSError *error = nil;
  id<LynxMapProviderMapView> mapView =
      [_adapter createMapViewWithConfiguration:[self providerConfiguration]
                                      eventSink:eventSink
                                          error:&error];
  if (mapView == nil) {
    eventSink.owner = nil;
    _eventSink = nil;
    [self emitError:error ?: LynxMapMakeProviderError(LynxMapProviderErrorUnavailable,
                                                      @"地图 provider 创建失败。")];
    return;
  }
  _providerMapView = mapView;
  if (![_mapContainer attachProviderMapView:mapView]) {
    [_adapter cancelPendingOperationsForMapView:mapView];
    [_adapter removeAllListenersFromMapView:mapView];
    [_adapter removeAllOverlaysFromMapView:mapView];
    [_adapter clearIconCacheForMapView:mapView];
    [_adapter destroyMapView:mapView];
    _providerMapView = nil;
    eventSink.owner = nil;
    _eventSink = nil;
    [self emitErrorCode:LynxMapProviderErrorInvalidConfiguration
                message:@"地图 provider 没有返回有效 UIView。"];
    return;
  }
  [_adapter startMapView:mapView];
  [self updateProviderPausedState];
}

- (void)updateViewOptionsWithZoomEnabled:(BOOL)zoomEnabled
                           scrollEnabled:(BOOL)scrollEnabled
                           rotateEnabled:(BOOL)rotateEnabled
                     rotateCameraEnabled:(BOOL)rotateCameraEnabled
                           showsCompass:(BOOL)showsCompass
                             showsScale:(BOOL)showsScale
                            showsLabels:(BOOL)showsLabels
                         showsBuildings:(BOOL)showsBuildings
                         touchPOIEnabled:(BOOL)touchPOIEnabled {
  _viewOptions = [[LynxMapViewOptions alloc]
      initWithZoomEnabled:zoomEnabled
             scrollEnabled:scrollEnabled
             rotateEnabled:rotateEnabled
       rotateCameraEnabled:rotateCameraEnabled
             showsCompass:showsCompass
               showsScale:showsScale
              showsLabels:showsLabels
           showsBuildings:showsBuildings
           touchPOIEnabled:touchPOIEnabled];
  [self scheduleRender];
}

- (LynxMapProviderConfiguration *)providerConfiguration {
  LynxMapProviderConfiguration *defaults = [LynxMapProviderRegistry defaultConfiguration];
  return [[LynxMapProviderConfiguration alloc] initWithProviderKey:defaults.providerKey
                                                     privacyAgreed:defaults.privacyAgreed
                                                     initialCamera:_camera];
}

- (void)updateProviderPausedState {
  if (_providerMapView == nil || _adapter == nil) {
    return;
  }
  BOOL paused = _applicationInBackground || !_windowAttached;
  [_adapter setMapView:_providerMapView paused:paused];
}

- (void)mapContainerDidLayout {
  if (_destroyed || _providerMapView == nil || _adapter == nil) {
    return;
  }
  [_adapter mapViewDidLayout:_providerMapView];
}

- (void)scheduleRender {
  if (_destroyed || _providerMapView == nil || !_providerReady || _adapter == nil) {
    return;
  }
  if (_pendingRenderTask != nil) {
    dispatch_block_cancel(_pendingRenderTask);
    _pendingRenderTask = nil;
  }
  NSUInteger generation = _generation;
  __weak LynxMapUI *weakSelf = self;
  dispatch_block_t task = dispatch_block_create(0, ^{
    LynxMapUI *strongSelf = weakSelf;
    if (strongSelf == nil || strongSelf->_destroyed || strongSelf->_generation != generation) {
      return;
    }
    strongSelf->_pendingRenderTask = nil;
    [strongSelf applyCurrentStateForGeneration:generation];
  });
  _pendingRenderTask = task;
  dispatch_async(dispatch_get_main_queue(), task);
}

- (void)applyCurrentStateForGeneration:(NSUInteger)generation {
  if (_destroyed || generation != _generation || _providerMapView == nil || !_providerReady) {
    return;
  }
  NSError *error = nil;
  CFTimeInterval startedAt = CACurrentMediaTime();
  if (![_adapter updateMapView:_providerMapView
                        camera:_camera
                      markers:_markers
                    polylines:_polylines
                   massPoints:_massPoints
                   layerState:_layerState
                   viewOptions:_viewOptions
                         error:&error]) {
    [self emitError:error ?: LynxMapMakeProviderError(LynxMapProviderErrorInvalidOperation,
                                                      @"地图状态更新失败。")];
  }
  _lastApplyDurationMs = (CACurrentMediaTime() - startedAt) * 1000.0;
  _applyCount += 1;
  _lastMarkerCount = _markers.count;
  _lastPolylineCount = _polylines.count;
  _lastMassPointCount = _massPoints.count;
}

- (void)emitEvent:(NSString *)name params:(NSDictionary *)params {
  LynxEventEmitter *eventEmitter = self.context.eventEmitter;
  if (eventEmitter == nil) {
    return;
  }
  LynxCustomEvent *event = [[LynxCustomEvent alloc] initWithName:name
                                                      targetSign:self.sign
                                                          params:params ?: @{}];
  [eventEmitter sendCustomEvent:event];
}

- (void)emitError:(NSError *)error {
  if (error == nil) {
    error = LynxMapMakeProviderError(LynxMapProviderErrorInvalidOperation, @"地图 provider 操作失败。");
  }
  [self emitEvent:@"error"
            params:@{
              @"code" : LynxMapProviderErrorName(error),
              @"message" : LynxMapProviderSafeErrorMessage(error),
            }];
}

- (void)emitErrorCode:(LynxMapProviderErrorCode)code message:(NSString *)message {
  [self emitError:LynxMapMakeProviderError(code, message)];
}

- (NSDictionary *)methodErrorData:(NSError *)error {
  return @{
    @"code" : LynxMapProviderErrorName(error),
    @"message" : LynxMapProviderSafeErrorMessage(error),
  };
}

- (void)handleProviderReadyForMapView:(id<LynxMapProviderMapView>)mapView
                           generation:(NSUInteger)generation {
  if (![self isCurrentMapView:mapView generation:generation] || _providerReady) {
    return;
  }
  _providerReady = YES;
  [self emitEvent:@"ready"
            params:@{
              @"provider" : _adapter.providerIdentifier ?: @"",
            }];
  [self scheduleRender];
}

- (void)handleProviderFailureForMapView:(id<LynxMapProviderMapView>)mapView
                              generation:(NSUInteger)generation
                                  error:(NSError *)error {
  if (![self isCurrentMapView:mapView generation:generation]) {
    return;
  }
  // 地图已经 ready 后的瓦片/网络失败是可恢复错误，保留 ready 状态，避免后续
  // UI Method 永久被锁在 not-ready；首次加载失败本来就保持未 ready。
  [self emitError:error ?: LynxMapMakeProviderError(LynxMapProviderErrorInvalidOperation,
                                                    @"地图 provider 操作失败。")];
}

- (void)handleProviderMapTapForMapView:(id<LynxMapProviderMapView>)mapView
                             generation:(NSUInteger)generation
                            coordinate:(LynxMapCoordinate *)coordinate {
  if (![self isCurrentMapView:mapView generation:generation] || !_providerReady ||
      coordinate == nil) {
    return;
  }
  [self emitEvent:@"maptap" params:@{ @"coordinate" : coordinate.dictionaryValue }];
}

- (void)handleProviderMarkerTapForMapView:(id<LynxMapProviderMapView>)mapView
                                generation:(NSUInteger)generation
                                identifier:(NSString *)identifier
                                coordinate:(LynxMapCoordinate *)coordinate {
  if (![self isCurrentMapView:mapView generation:generation] || !_providerReady ||
      identifier.length == 0 || coordinate == nil) {
    return;
  }
  [self emitEvent:@"markertap"
            params:@{
              @"id" : identifier,
              @"coordinate" : coordinate.dictionaryValue,
            }];
}

- (void)handleProviderMassPointTapForMapView:(id<LynxMapProviderMapView>)mapView
                                   generation:(NSUInteger)generation
                                   identifier:(NSString *)identifier
                                   coordinate:(LynxMapCoordinate *)coordinate {
  if (![self isCurrentMapView:mapView generation:generation] || !_providerReady ||
      identifier.length == 0 || coordinate == nil) {
    return;
  }
  [self emitEvent:@"masspointtap"
            params:@{
              @"id" : identifier,
              @"coordinate" : coordinate.dictionaryValue,
            }];
}

- (void)handleProviderMarkerSelectionForMapView:(id<LynxMapProviderMapView>)mapView
                                      generation:(NSUInteger)generation
                                      identifier:(NSString *)identifier
                                      coordinate:(LynxMapCoordinate *)coordinate
                                        selected:(BOOL)selected {
  if (![self isCurrentMapView:mapView generation:generation] || !_providerReady ||
      identifier.length == 0 || coordinate == nil) {
    return;
  }
  [self emitEvent:selected ? @"markerselected" : @"markerdeselected"
            params:@{
              @"id" : identifier,
              @"coordinate" : coordinate.dictionaryValue,
              @"selected" : @(selected),
            }];
}

- (void)handleProviderMarkerDragForMapView:(id<LynxMapProviderMapView>)mapView
                                  generation:(NSUInteger)generation
                                  identifier:(NSString *)identifier
                                  coordinate:(LynxMapCoordinate *)coordinate
                                       phase:(NSString *)phase {
  if (![self isCurrentMapView:mapView generation:generation] || !_providerReady ||
      identifier.length == 0 || coordinate == nil || phase.length == 0) {
    return;
  }
  [self emitEvent:@"markerdrag"
            params:@{
              @"id" : identifier,
              @"coordinate" : coordinate.dictionaryValue,
              @"phase" : phase,
            }];
}

- (void)handleProviderLongPressForMapView:(id<LynxMapProviderMapView>)mapView
                                generation:(NSUInteger)generation
                               coordinate:(LynxMapCoordinate *)coordinate {
  if (![self isCurrentMapView:mapView generation:generation] || !_providerReady ||
      coordinate == nil) {
    return;
  }
  [self emitEvent:@"longpress" params:@{ @"coordinate" : coordinate.dictionaryValue }];
}

- (void)handleProviderRegionChangeForMapView:(id<LynxMapProviderMapView>)mapView
                                   generation:(NSUInteger)generation
                                      center:(LynxMapCoordinate *)center
                                      zoom:(NSNumber *)zoom
                                      reason:(NSString *)reason {
  if (![self isCurrentMapView:mapView generation:generation] || !_providerReady) {
    return;
  }
  NSMutableDictionary *params = [NSMutableDictionary dictionary];
  if (center != nil) {
    params[@"center"] = center.dictionaryValue;
  }
  if ([zoom isKindOfClass:[NSNumber class]] && isfinite(zoom.doubleValue)) {
    params[@"zoom"] = zoom;
  }
  if (center != nil || ([zoom isKindOfClass:[NSNumber class]] && isfinite(zoom.doubleValue))) {
    _camera = [[LynxMapCamera alloc] initWithCenter:center ?: _camera.center
                                               zoom:zoom ?: _camera.zoom
                                            bearing:_camera.bearing
                                               pitch:_camera.pitch
                                              anchor:_camera.anchor];
  }
  if ([reason isKindOfClass:[NSString class]] && reason.length != 0) {
    params[@"reason"] = reason;
    NSArray<NSString *> *components = [reason componentsSeparatedByString:@":"];
    if (components.count == 2) {
      params[@"source"] = components[0];
      params[@"phase"] = components[1];
    }
  }
  [self emitEvent:@"regionchange" params:params.copy];
}

- (BOOL)isCurrentMapView:(id<LynxMapProviderMapView>)mapView generation:(NSUInteger)generation {
  return !_destroyed && generation == _generation && mapView == _providerMapView;
}

- (LynxMapCamera *)cameraByApplyingPatch:(LynxMapCamera *)patch {
  LynxMapCoordinate *center = patch.hasCenter ? patch.center : _camera.center;
  NSNumber *zoom = patch.hasZoom ? patch.zoom : _camera.zoom;
  NSNumber *bearing = patch.hasBearing ? patch.bearing : _camera.bearing;
  NSNumber *pitch = patch.hasPitch ? patch.pitch : _camera.pitch;
  NSDictionary *anchor = patch.hasAnchor ? patch.anchor : _camera.anchor;
  return [[LynxMapCamera alloc] initWithCenter:center
                                         zoom:zoom
                                      bearing:bearing
                                         pitch:pitch
                                        anchor:anchor];
}

- (LynxMapPendingOperation *)beginPendingOperationWithCallback:(LynxUIMethodCallbackBlock)callback
                                                     generation:(NSUInteger)generation {
  if (_pendingOperations.count >= LynxMapMaximumPendingOperationCount) {
    return nil;
  }
  LynxMapPendingOperation *operation = [[LynxMapPendingOperation alloc] init];
  operation.callback = callback;
  operation.generation = generation;
  [_pendingOperations addObject:operation];
  return operation;
}

- (void)finishPendingOperation:(LynxMapPendingOperation *)operation
                    generation:(NSUInteger)generation
                          error:(NSError *)error
                successData:(NSDictionary *)successData {
  if (operation == nil) {
    return;
  }
  if (![NSThread isMainThread]) {
    __weak LynxMapUI *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      LynxMapUI *strongSelf = weakSelf;
      [strongSelf finishPendingOperation:operation
                              generation:generation
                                    error:error
                          successData:successData];
    });
    return;
  }
  if (operation.completed) {
    return;
  }
  int code = kUIMethodSuccess;
  id data = successData;
  if (error != nil) {
    code = (error.code == LynxMapProviderErrorUnavailable ||
            error.code == LynxMapProviderErrorMissingAPIKey ||
            error.code == LynxMapProviderErrorPrivacyNotConfigured)
               ? kUIMethodInvalidStateError
               : kUIMethodOperationError;
    data = [self methodErrorData:error];
  } else if (_destroyed || operation.generation != _generation || generation != _generation) {
    code = kUIMethodInvalidStateError;
    data = [self methodErrorData:LynxMapMakeProviderError(LynxMapProviderErrorCancelled,
                                                           @"地图操作已取消。")];
  }
  [self finishPendingOperation:operation code:code data:data];
}

- (void)finishPendingOperation:(LynxMapPendingOperation *)operation
                          code:(int)code
                          data:(id)data {
  if (operation == nil || operation.completed) {
    return;
  }
  operation.completed = YES;
  [_pendingOperations removeObject:operation];
  LynxUIMethodCallbackBlock callback = operation.callback;
  operation.callback = nil;
  if (callback != nil) {
    callback(code, data);
  }
}

- (void)handleApplicationDidEnterBackground:(NSNotification *)notification {
  (void)notification;
  _applicationInBackground = YES;
  [self updateProviderPausedState];
}

- (void)handleApplicationWillEnterForeground:(NSNotification *)notification {
  (void)notification;
  _applicationInBackground = NO;
  [self updateProviderPausedState];
}

- (void)teardownMap {
  if (_destroyed) {
    return;
  }
  _destroyed = YES;
  _providerReady = NO;
  _generation = LynxMapNextGeneration(_generation);

  if (_pendingRenderTask != nil) {
    dispatch_block_cancel(_pendingRenderTask);
    _pendingRenderTask = nil;
  }

  NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
  if (_observingApplicationLifecycle) {
    [notificationCenter removeObserver:self
                                  name:UIApplicationDidEnterBackgroundNotification
                                object:nil];
    [notificationCenter removeObserver:self
                                  name:UIApplicationWillEnterForegroundNotification
                                object:nil];
    _observingApplicationLifecycle = NO;
  }

  id<LynxMapProviderAdapter> adapter = _adapter;
  id<LynxMapProviderMapView> mapView = _providerMapView;
  if (adapter != nil && mapView != nil) {
    // 先取消 provider 内部异步任务，再清 listener、overlay、icon cache，最后销毁 MapView。
    [adapter cancelPendingOperationsForMapView:mapView];
    NSArray<LynxMapPendingOperation *> *operations = _pendingOperations.allObjects;
    for (LynxMapPendingOperation *operation in operations) {
      [self finishPendingOperation:operation
                              code:kUIMethodInvalidStateError
                              data:[self methodErrorData:LynxMapMakeProviderError(
                                                               LynxMapProviderErrorCancelled,
                                                               @"地图操作已取消。")]];
    }
    [adapter setMapView:mapView paused:YES];
    [adapter removeAllListenersFromMapView:mapView];
    [adapter removeAllOverlaysFromMapView:mapView];
    [adapter clearIconCacheForMapView:mapView];
    [_mapContainer detachProviderMapView];
    if (_eventSink != nil) {
      _eventSink.owner = nil;
    }
    [adapter destroyMapView:mapView];
  } else {
    NSArray<LynxMapPendingOperation *> *operations = _pendingOperations.allObjects;
    for (LynxMapPendingOperation *operation in operations) {
      [self finishPendingOperation:operation
                              code:kUIMethodInvalidStateError
                              data:[self methodErrorData:LynxMapMakeProviderError(
                                                               LynxMapProviderErrorCancelled,
                                                               @"地图操作已取消。")]];
    }
    [_mapContainer detachProviderMapView];
    if (_eventSink != nil) {
      _eventSink.owner = nil;
    }
  }

  _providerMapView = nil;
  _eventSink = nil;
  _adapter = nil;
  _camera = nil;
  _markers = @[];
  _polylines = @[];
  _massPoints = @[];
  _layerState = nil;
  _viewOptions = nil;
  _mapContainer.layoutObserver = nil;
  _mapContainer = nil;
  _windowAttached = NO;
}

- (void)onNodeRemoved {
  // Lynx 节点移除时立刻解除 MapView、delegate 和异步回调；dealloc 只作为兜底。
  [self teardownMap];
  [super onNodeRemoved];
}

- (void)dealloc {
  [self teardownMap];
}

@end
