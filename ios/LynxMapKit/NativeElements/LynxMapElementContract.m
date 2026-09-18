#import "LynxMapElementContract.h"

#import <math.h>

NSString *const LynxMapProviderErrorDomain = @"com.lynxshell.map-provider";

const NSUInteger LynxMapMaximumMarkerCount = 200;
const NSUInteger LynxMapMaximumIdentifierLength = 128;
const NSUInteger LynxMapMaximumMarkerTextLength = 256;
const NSUInteger LynxMapMaximumMarkerIconURLLength = 2048;
const NSUInteger LynxMapMaximumColorLength = 16;
const NSUInteger LynxMapMaximumPolylineCount = 50;
const NSUInteger LynxMapMaximumPolylinePointCount = 512;
const NSUInteger LynxMapMaximumTotalPolylinePointCount = 5000;
const NSUInteger LynxMapMaximumMassPointCount = 5000;
const double LynxMapMinimumZoom = 0.0;
const double LynxMapMaximumZoom = 24.0;
const double LynxMapMaximumPolylineWidth = 128.0;
const double LynxMapMaximumPadding = 4096.0;
const NSInteger LynxMapMaximumZIndexMagnitude = 100000;

static void LynxMapSetError(NSError * _Nullable * _Nullable error,
                            LynxMapProviderErrorCode code,
                            NSString *message) {
  if (error != NULL) {
    *error = LynxMapMakeProviderError(code, message);
  }
}

static BOOL LynxMapIsNumber(id object) {
  return [object isKindOfClass:[NSNumber class]];
}

static BOOL LynxMapGetFiniteDouble(id object, double *result) {
  if (!LynxMapIsNumber(object)) {
    return NO;
  }
  double value = [object doubleValue];
  if (!isfinite(value)) {
    return NO;
  }
  if (result != NULL) {
    *result = value;
  }
  return YES;
}

static BOOL LynxMapGetBoolean(id object, BOOL *result) {
  if (![object isKindOfClass:[NSNumber class]]) {
    return NO;
  }
  if (result != NULL) {
    *result = [object boolValue];
  }
  return YES;
}

static BOOL LynxMapIsPresent(id object) {
  return object != nil && object != [NSNull null];
}

static NSString * _Nullable LynxMapOptionalString(id object, BOOL *valid) {
  if (!LynxMapIsPresent(object)) {
    if (valid != NULL) {
      *valid = YES;
    }
    return nil;
  }
  if (![object isKindOfClass:[NSString class]]) {
    if (valid != NULL) {
      *valid = NO;
    }
    return nil;
  }
  if (valid != NULL) {
    *valid = YES;
  }
  return [(NSString *)object length] == 0 ? nil : (NSString *)object;
}

static BOOL LynxMapReadVisualNumber(NSDictionary *dictionary,
                                    NSString *key,
                                    double minimum,
                                    double maximum,
                                    NSNumber **output) {
  id value = dictionary[key];
  if (!LynxMapIsPresent(value)) {
    return YES;
  }
  double number = 0;
  if (!LynxMapGetFiniteDouble(value, &number) || number < minimum || number > maximum) {
    return NO;
  }
  if (output != NULL) {
    *output = @(number);
  }
  return YES;
}

static NSDictionary * _Nullable LynxMapMarkerIconFromObject(
    id object,
    NSError * _Nullable * _Nullable error) {
  if (![object isKindOfClass:[NSDictionary class]]) {
    LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration,
                    @"marker.icon 必须是对象。");
    return nil;
  }
  NSDictionary *input = (NSDictionary *)object;
  BOOL valid = NO;
  NSString *uri = LynxMapOptionalString(input[@"uri"], &valid);
  NSURL *url = uri.length > 0 ? [NSURL URLWithString:uri] : nil;
  if (!valid || uri.length == 0 || uri.length > LynxMapMaximumMarkerIconURLLength ||
      url == nil || ![url.scheme.lowercaseString isEqualToString:@"https"]) {
    LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration,
                    @"marker.icon.uri 必须是 HTTPS URL 且不能超过 2048 个字符。");
    return nil;
  }

  NSNumber *width = nil;
  NSNumber *height = nil;
  NSNumber *cornerRadius = nil;
  if (!LynxMapReadVisualNumber(input, @"width", 16, 128, &width) ||
      !LynxMapReadVisualNumber(input, @"height", 16, 128, &height) ||
      !LynxMapReadVisualNumber(input, @"cornerRadius", 0, 64, &cornerRadius)) {
    LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration,
                    @"marker.icon 的尺寸或圆角超出允许范围。");
    return nil;
  }

  NSDictionary *anchor = input[@"anchor"];
  NSNumber *anchorX = nil;
  NSNumber *anchorY = nil;
  if (LynxMapIsPresent(anchor)) {
    if (![anchor isKindOfClass:[NSDictionary class]] ||
        !LynxMapReadVisualNumber(anchor, @"x", 0, 1, &anchorX) ||
        !LynxMapReadVisualNumber(anchor, @"y", 0, 1, &anchorY)) {
      LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration,
                      @"marker.icon.anchor 必须是 0 到 1 之间的 x/y。");
      return nil;
    }
  }

  NSMutableDictionary *result = [@{ @"uri" : uri } mutableCopy];
  if (width != nil) result[@"width"] = width;
  if (height != nil) result[@"height"] = height;
  if (cornerRadius != nil) result[@"cornerRadius"] = cornerRadius;
  if (anchorX != nil && anchorY != nil) result[@"anchor"] = @{ @"x" : anchorX, @"y" : anchorY };
  return result.copy;
}

static NSDictionary * _Nullable LynxMapMarkerViewFromObject(
    id object,
    NSError * _Nullable * _Nullable error) {
  if (![object isKindOfClass:[NSDictionary class]]) {
    LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration,
                    @"marker.view 必须是对象。");
    return nil;
  }
  NSDictionary *input = (NSDictionary *)object;
  BOOL valid = NO;
  NSString *text = LynxMapOptionalString(input[@"text"], &valid);
  if (!valid || text.length > 128) {
    LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration,
                    @"marker.view.text 不能超过 128 个字符。");
    return nil;
  }
  NSNumber *width = nil;
  NSNumber *height = nil;
  NSNumber *borderWidth = nil;
  NSNumber *cornerRadius = nil;
  if (!LynxMapReadVisualNumber(input, @"width", 20, 160, &width) ||
      !LynxMapReadVisualNumber(input, @"height", 20, 160, &height) ||
      !LynxMapReadVisualNumber(input, @"borderWidth", 0, 8, &borderWidth) ||
      !LynxMapReadVisualNumber(input, @"cornerRadius", 0, 80, &cornerRadius)) {
    LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration,
                    @"marker.view 的尺寸、边框或圆角超出允许范围。");
    return nil;
  }

  NSMutableDictionary *result = [NSMutableDictionary dictionary];
  if (text != nil) result[@"text"] = text;
  if (width != nil) result[@"width"] = width;
  if (height != nil) result[@"height"] = height;
  if (borderWidth != nil) result[@"borderWidth"] = borderWidth;
  if (cornerRadius != nil) result[@"cornerRadius"] = cornerRadius;
  for (NSString *key in @[ @"backgroundColor", @"foregroundColor", @"borderColor" ]) {
    NSString *color = LynxMapOptionalString(input[key], &valid);
    if (!valid || color.length > 32) {
      LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration,
                      @"marker.view 颜色必须是短字符串。");
      return nil;
    }
    if (color != nil) result[key] = color;
  }
  return result.copy;
}

NSError *LynxMapMakeProviderError(LynxMapProviderErrorCode code, NSString *message) {
  return [NSError errorWithDomain:LynxMapProviderErrorDomain
                              code:code
                          userInfo:@{NSLocalizedDescriptionKey : message}];
}

NSString *LynxMapProviderErrorName(NSError *error) {
  switch ((LynxMapProviderErrorCode)error.code) {
    case LynxMapProviderErrorUnavailable:
      return @"MAP_PROVIDER_UNAVAILABLE";
    case LynxMapProviderErrorMissingAPIKey:
      return @"MAP_PROVIDER_MISSING_API_KEY";
    case LynxMapProviderErrorPrivacyNotConfigured:
      return @"MAP_PROVIDER_PRIVACY_NOT_CONFIGURED";
    case LynxMapProviderErrorInvalidConfiguration:
      return @"MAP_INVALID_CONFIGURATION";
    case LynxMapProviderErrorInvalidOperation:
      return @"MAP_INVALID_OPERATION";
    case LynxMapProviderErrorUnsupportedCapability:
      return @"MAP_UNSUPPORTED_CAPABILITY";
    case LynxMapProviderErrorCancelled:
      return @"MAP_OPERATION_CANCELLED";
  }
  return @"MAP_PROVIDER_OPERATION_FAILED";
}

NSString *LynxMapProviderSafeErrorMessage(NSError *error) {
  switch ((LynxMapProviderErrorCode)error.code) {
    case LynxMapProviderErrorUnavailable:
      return @"地图 provider 不可用，请先接入对应 SDK。";
    case LynxMapProviderErrorMissingAPIKey:
      return @"地图 provider 缺少 Key。";
    case LynxMapProviderErrorPrivacyNotConfigured:
      return @"地图 provider 隐私配置未完成。";
    case LynxMapProviderErrorInvalidConfiguration:
      return @"地图配置无效。";
    case LynxMapProviderErrorInvalidOperation:
      return @"地图操作无效。";
    case LynxMapProviderErrorUnsupportedCapability:
      return @"当前地图 provider 不支持该能力。";
    case LynxMapProviderErrorCancelled:
      return @"地图操作已取消。";
  }
  return @"地图 provider 操作失败。";
}

@implementation LynxMapCoordinate

- (instancetype)initWithLatitude:(double)latitude longitude:(double)longitude {
  self = [super init];
  if (self != nil) {
    _latitude = latitude;
    _longitude = longitude;
  }
  return self;
}

+ (instancetype)coordinateWithObject:(id)object error:(NSError * _Nullable * _Nullable)error {
  if ([object isKindOfClass:[LynxMapCoordinate class]]) {
    LynxMapCoordinate *coordinate = (LynxMapCoordinate *)object;
    return [[self alloc] initWithLatitude:coordinate.latitude longitude:coordinate.longitude];
  }

  id latitudeObject = nil;
  id longitudeObject = nil;
  if ([object isKindOfClass:[NSDictionary class]]) {
    NSDictionary *dictionary = (NSDictionary *)object;
    latitudeObject = dictionary[@"latitude"] ?: dictionary[@"lat"];
    longitudeObject = dictionary[@"longitude"] ?: dictionary[@"lng"];
  } else if ([object isKindOfClass:[NSArray class]]) {
    NSArray *array = (NSArray *)object;
    if (array.count >= 2) {
      latitudeObject = array[0];
      longitudeObject = array[1];
    }
  }

  double latitude = 0;
  double longitude = 0;
  if (!LynxMapGetFiniteDouble(latitudeObject, &latitude) ||
      !LynxMapGetFiniteDouble(longitudeObject, &longitude) || latitude < -90.0 ||
      latitude > 90.0 || longitude < -180.0 || longitude > 180.0) {
    LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration, @"center 坐标无效。请使用 latitude/longitude。");
    return nil;
  }
  return [[self alloc] initWithLatitude:latitude longitude:longitude];
}

- (NSDictionary<NSString *, NSNumber *> *)dictionaryValue {
  return @{
    @"latitude" : @(self.latitude),
    @"longitude" : @(self.longitude),
  };
}

- (id)copyWithZone:(NSZone *)zone {
  return [[[self class] allocWithZone:zone] initWithLatitude:self.latitude
                                                   longitude:self.longitude];
}

- (BOOL)isEqual:(id)object {
  if (self == object) {
    return YES;
  }
  if (![object isKindOfClass:[LynxMapCoordinate class]]) {
    return NO;
  }
  LynxMapCoordinate *other = (LynxMapCoordinate *)object;
  return self.latitude == other.latitude && self.longitude == other.longitude;
}

- (NSUInteger)hash {
  return @(self.latitude).hash ^ @(self.longitude).hash;
}

@end

@implementation LynxMapCamera

- (instancetype)initWithCenter:(LynxMapCoordinate *)center zoom:(NSNumber *)zoom {
  return [self initWithCenter:center
                         zoom:zoom
                      bearing:nil
                         pitch:nil
                        anchor:nil];
}

- (instancetype)initWithCenter:(LynxMapCoordinate *)center
                           zoom:(NSNumber *)zoom
                        bearing:(NSNumber *)bearing
                           pitch:(NSNumber *)pitch
                          anchor:(NSDictionary<NSString *, NSNumber *> *)anchor {
  self = [super init];
  if (self != nil) {
    _center = [center copy];
    _zoom = [zoom copy];
    _bearing = [bearing copy];
    _pitch = [pitch copy];
    _anchor = [anchor copy];
    _hasCenter = center != nil;
    _hasZoom = zoom != nil;
    _hasBearing = bearing != nil;
    _hasPitch = pitch != nil;
    _hasAnchor = anchor != nil;
  }
  return self;
}

+ (instancetype)cameraWithObject:(id)object error:(NSError * _Nullable * _Nullable)error {
  if ([object isKindOfClass:[LynxMapCamera class]]) {
    LynxMapCamera *camera = (LynxMapCamera *)object;
    return [[self alloc] initWithCenter:camera.center
                                   zoom:camera.zoom
                                bearing:camera.bearing
                                   pitch:camera.pitch
                                  anchor:camera.anchor];
  }
  if (![object isKindOfClass:[NSDictionary class]]) {
    LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration, @"camera 必须是对象。");
    return nil;
  }

  NSDictionary *dictionary = (NSDictionary *)object;
  id centerObject = dictionary[@"center"];
  id zoomObject = dictionary[@"zoom"];
  id bearingObject = dictionary[@"bearing"] ?: dictionary[@"rotationDegree"];
  id pitchObject = dictionary[@"pitch"] ?: dictionary[@"cameraDegree"];
  id anchorObject = dictionary[@"anchor"] ?: dictionary[@"screenAnchor"];
  BOOL hasCenter = LynxMapIsPresent(centerObject);
  BOOL hasZoom = LynxMapIsPresent(zoomObject);
  BOOL hasBearing = LynxMapIsPresent(bearingObject);
  BOOL hasPitch = LynxMapIsPresent(pitchObject);
  BOOL hasAnchor = LynxMapIsPresent(anchorObject);
  if (!hasCenter && !hasZoom && !hasBearing && !hasPitch && !hasAnchor) {
    LynxMapSetError(error, LynxMapProviderErrorInvalidOperation,
                    @"camera 至少需要 center、zoom、bearing、pitch 或 anchor。");
    return nil;
  }

  LynxMapCoordinate *center = nil;
  if (hasCenter) {
    center = [LynxMapCoordinate coordinateWithObject:centerObject error:error];
    if (center == nil) {
      return nil;
    }
  }

  NSNumber *zoom = nil;
  if (hasZoom) {
    double zoomValue = 0;
    if (!LynxMapGetFiniteDouble(zoomObject, &zoomValue) || zoomValue < LynxMapMinimumZoom ||
        zoomValue > LynxMapMaximumZoom) {
      LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration,
                      @"zoom 必须在 0 到 24 之间。");
      return nil;
    }
    zoom = @(zoomValue);
  }

  NSNumber *bearing = nil;
  if (hasBearing) {
    double bearingValue = 0;
    if (!LynxMapGetFiniteDouble(bearingObject, &bearingValue) || bearingValue < 0.0 ||
        bearingValue >= 360.0) {
      LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration,
                      @"bearing 必须在 0 到 360 之间（不含 360）。");
      return nil;
    }
    bearing = @(bearingValue);
  }

  NSNumber *pitch = nil;
  if (hasPitch) {
    double pitchValue = 0;
    if (!LynxMapGetFiniteDouble(pitchObject, &pitchValue) || pitchValue < 0.0 ||
        pitchValue > 60.0) {
      LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration,
                      @"pitch 必须在 0 到 60 之间。");
      return nil;
    }
    pitch = @(pitchValue);
  }

  NSDictionary<NSString *, NSNumber *> *anchor = nil;
  if (hasAnchor) {
    if (![anchorObject isKindOfClass:[NSDictionary class]]) {
      LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration,
                      @"anchor 必须是包含 x/y 的对象。");
      return nil;
    }
    NSDictionary *anchorDictionary = (NSDictionary *)anchorObject;
    double anchorX = 0;
    double anchorY = 0;
    if (!LynxMapGetFiniteDouble(anchorDictionary[@"x"], &anchorX) ||
        !LynxMapGetFiniteDouble(anchorDictionary[@"y"], &anchorY) || anchorX < 0.0 ||
        anchorX > 1.0 || anchorY < 0.0 || anchorY > 1.0) {
      LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration,
                      @"anchor.x 和 anchor.y 必须在 0 到 1 之间。");
      return nil;
    }
    anchor = @{ @"x" : @(anchorX), @"y" : @(anchorY) };
  }
  return [[self alloc] initWithCenter:center
                                 zoom:zoom
                              bearing:bearing
                                 pitch:pitch
                                anchor:anchor];
}

- (NSDictionary<NSString *, id> *)dictionaryValue {
  NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
  if (self.hasCenter) {
    dictionary[@"center"] = self.center.dictionaryValue;
  }
  if (self.hasZoom) {
    dictionary[@"zoom"] = self.zoom;
  }
  if (self.hasBearing) {
    dictionary[@"bearing"] = self.bearing;
  }
  if (self.hasPitch) {
    dictionary[@"pitch"] = self.pitch;
  }
  if (self.hasAnchor) {
    dictionary[@"anchor"] = self.anchor;
  }
  return dictionary.copy;
}

- (id)copyWithZone:(NSZone *)zone {
  return [[[self class] allocWithZone:zone] initWithCenter:self.center
                                                       zoom:self.zoom
                                                    bearing:self.bearing
                                                       pitch:self.pitch
                                                      anchor:self.anchor];
}

@end

@implementation LynxMapMarker

+ (instancetype)markerWithObject:(id)object
                            index:(NSUInteger)index
                            error:(NSError * _Nullable * _Nullable)error {
  if (![object isKindOfClass:[NSDictionary class]]) {
    LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration,
                    [NSString stringWithFormat:@"markers[%lu] 必须是对象。", (unsigned long)index]);
    return nil;
  }
  NSDictionary *dictionary = (NSDictionary *)object;
  id identifierObject = dictionary[@"id"] ?: dictionary[@"identifier"];
  if (![identifierObject isKindOfClass:[NSString class]] || [identifierObject length] == 0 ||
      [identifierObject length] > LynxMapMaximumIdentifierLength) {
    LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration,
                    [NSString stringWithFormat:@"markers[%lu].id 不能为空。", (unsigned long)index]);
    return nil;
  }

  id coordinateObject = dictionary[@"coordinate"];
  if (!LynxMapIsPresent(coordinateObject)) {
    coordinateObject = dictionary;
  }
  LynxMapCoordinate *coordinate = [LynxMapCoordinate coordinateWithObject:coordinateObject error:error];
  if (coordinate == nil) {
    return nil;
  }

  BOOL valid = NO;
  NSString *title = LynxMapOptionalString(dictionary[@"title"], &valid);
  if (!valid || title.length > LynxMapMaximumMarkerTextLength) {
    LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration, @"marker.title 必须是字符串。");
    return nil;
  }
  NSString *subtitle = LynxMapOptionalString(dictionary[@"subtitle"], &valid);
  if (!valid || subtitle.length > LynxMapMaximumMarkerTextLength) {
    LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration, @"marker.subtitle 必须是字符串。");
    return nil;
  }
  NSDictionary *icon = nil;
  if (LynxMapIsPresent(dictionary[@"icon"])) {
    icon = LynxMapMarkerIconFromObject(dictionary[@"icon"], error);
    if (icon == nil) return nil;
  }
  NSDictionary *viewConfiguration = nil;
  if (LynxMapIsPresent(dictionary[@"view"])) {
    viewConfiguration = LynxMapMarkerViewFromObject(dictionary[@"view"], error);
    if (viewConfiguration == nil) return nil;
  }
  BOOL visible = YES;
  if (LynxMapIsPresent(dictionary[@"visible"]) &&
      !LynxMapGetBoolean(dictionary[@"visible"], &visible)) {
    LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration, @"marker.visible 必须是布尔值。");
    return nil;
  }

  BOOL selected = NO;
  if (LynxMapIsPresent(dictionary[@"selected"]) &&
      !LynxMapGetBoolean(dictionary[@"selected"], &selected)) {
    LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration,
                    @"marker.selected 必须是布尔值。");
    return nil;
  }

  BOOL draggable = NO;
  if (LynxMapIsPresent(dictionary[@"draggable"]) &&
      !LynxMapGetBoolean(dictionary[@"draggable"], &draggable)) {
    LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration,
                    @"marker.draggable 必须是布尔值。");
    return nil;
  }

  double opacity = 1.0;
  if (LynxMapIsPresent(dictionary[@"opacity"]) &&
      (!LynxMapGetFiniteDouble(dictionary[@"opacity"], &opacity) || opacity < 0.0 || opacity > 1.0)) {
    LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration, @"marker.opacity 必须在 0 到 1 之间。");
    return nil;
  }

  NSInteger zIndex = 0;
  if (LynxMapIsPresent(dictionary[@"zIndex"] ?: dictionary[@"z-index"])) {
    id zIndexObject = dictionary[@"zIndex"] ?: dictionary[@"z-index"];
    if (![zIndexObject isKindOfClass:[NSNumber class]]) {
      LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration, @"marker.zIndex 必须是数字。");
      return nil;
    }
    zIndex = [zIndexObject integerValue];
    if (zIndex < -LynxMapMaximumZIndexMagnitude || zIndex > LynxMapMaximumZIndexMagnitude) {
      LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration,
                      @"marker.zIndex 超出允许范围。");
      return nil;
    }
  }

  LynxMapMarker *marker = [[self alloc] init];
  marker->_identifier = [identifierObject copy];
  marker->_coordinate = [coordinate copy];
  marker->_title = [title copy];
  marker->_subtitle = [subtitle copy];
  marker->_icon = [icon copy];
  marker->_viewConfiguration = [viewConfiguration copy];
  marker->_visible = visible;
  marker->_selected = selected;
  marker->_draggable = draggable;
  marker->_opacity = opacity;
  marker->_zIndex = zIndex;
  return marker;
}

- (id)copyWithZone:(NSZone *)zone {
  LynxMapMarker *copy = [[[self class] allocWithZone:zone] init];
  copy->_identifier = [_identifier copy];
  copy->_coordinate = [_coordinate copy];
  copy->_title = [_title copy];
  copy->_subtitle = [_subtitle copy];
  copy->_icon = [_icon copy];
  copy->_viewConfiguration = [_viewConfiguration copy];
  copy->_visible = _visible;
  copy->_selected = _selected;
  copy->_draggable = _draggable;
  copy->_opacity = _opacity;
  copy->_zIndex = _zIndex;
  return copy;
}

@end

@implementation LynxMapPolyline

+ (instancetype)polylineWithObject:(id)object
                              index:(NSUInteger)index
                              error:(NSError * _Nullable * _Nullable)error {
  if (![object isKindOfClass:[NSDictionary class]]) {
    LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration,
                    [NSString stringWithFormat:@"polylines[%lu] 必须是对象。", (unsigned long)index]);
    return nil;
  }
  NSDictionary *dictionary = (NSDictionary *)object;
  id identifierObject = dictionary[@"id"] ?: dictionary[@"identifier"];
  if (![identifierObject isKindOfClass:[NSString class]] || [identifierObject length] == 0 ||
      [identifierObject length] > LynxMapMaximumIdentifierLength) {
    LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration,
                    [NSString stringWithFormat:@"polylines[%lu].id 不能为空。", (unsigned long)index]);
    return nil;
  }

  id pointsObject = dictionary[@"points"] ?: dictionary[@"coordinates"];
  if (![pointsObject isKindOfClass:[NSArray class]]) {
    LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration, @"polyline.points 必须是数组。");
    return nil;
  }
  NSArray *pointValues = (NSArray *)pointsObject;
  if (pointValues.count < 2 || pointValues.count > LynxMapMaximumPolylinePointCount) {
    LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration, @"polyline.points 数量超出允许范围。");
    return nil;
  }

  NSMutableArray<LynxMapCoordinate *> *points =
      [NSMutableArray arrayWithCapacity:pointValues.count];
  for (NSUInteger pointIndex = 0; pointIndex < pointValues.count; pointIndex++) {
    LynxMapCoordinate *coordinate =
        [LynxMapCoordinate coordinateWithObject:pointValues[pointIndex] error:error];
    if (coordinate == nil) {
      return nil;
    }
    [points addObject:coordinate];
  }

  BOOL visible = YES;
  if (LynxMapIsPresent(dictionary[@"visible"]) &&
      !LynxMapGetBoolean(dictionary[@"visible"], &visible)) {
    LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration, @"polyline.visible 必须是布尔值。");
    return nil;
  }

  double opacity = 1.0;
  if (LynxMapIsPresent(dictionary[@"opacity"]) &&
      (!LynxMapGetFiniteDouble(dictionary[@"opacity"], &opacity) || opacity < 0.0 || opacity > 1.0)) {
    LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration, @"polyline.opacity 必须在 0 到 1 之间。");
    return nil;
  }

  BOOL colorValid = NO;
  NSString *color = LynxMapOptionalString(dictionary[@"color"], &colorValid);
  if (!colorValid || color.length > LynxMapMaximumColorLength) {
    LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration, @"polyline.color 必须是字符串。");
    return nil;
  }

  CGFloat width = 1.0;
  if (LynxMapIsPresent(dictionary[@"width"])) {
    double widthValue = 0;
    if (!LynxMapGetFiniteDouble(dictionary[@"width"], &widthValue) || widthValue <= 0.0 ||
        widthValue > LynxMapMaximumPolylineWidth) {
      LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration,
                      @"polyline.width 必须在 0 到 128 之间。");
      return nil;
    }
    width = (CGFloat)widthValue;
  }

  NSInteger zIndex = 0;
  if (LynxMapIsPresent(dictionary[@"zIndex"] ?: dictionary[@"z-index"])) {
    id zIndexObject = dictionary[@"zIndex"] ?: dictionary[@"z-index"];
    if (![zIndexObject isKindOfClass:[NSNumber class]]) {
      LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration, @"polyline.zIndex 必须是数字。");
      return nil;
    }
    zIndex = [zIndexObject integerValue];
    if (zIndex < -LynxMapMaximumZIndexMagnitude || zIndex > LynxMapMaximumZIndexMagnitude) {
      LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration,
                      @"polyline.zIndex 超出允许范围。");
      return nil;
    }
  }

  LynxMapPolyline *polyline = [[self alloc] init];
  polyline->_identifier = [identifierObject copy];
  polyline->_points = points.copy;
  polyline->_visible = visible;
  polyline->_opacity = opacity;
  polyline->_width = width;
  polyline->_color = [color copy];
  polyline->_zIndex = zIndex;
  return polyline;
}

- (id)copyWithZone:(NSZone *)zone {
  LynxMapPolyline *copy = [[[self class] allocWithZone:zone] init];
  copy->_identifier = [_identifier copy];
  copy->_points = [[NSArray alloc] initWithArray:_points copyItems:YES];
  copy->_visible = _visible;
  copy->_opacity = _opacity;
  copy->_width = _width;
  copy->_color = [_color copy];
  copy->_zIndex = _zIndex;
  return copy;
}

@end

@implementation LynxMapMassPoint

+ (instancetype)massPointWithObject:(id)object
                               index:(NSUInteger)index
                               error:(NSError * _Nullable * _Nullable)error {
  if (![object isKindOfClass:[NSDictionary class]]) {
    LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration,
                    [NSString stringWithFormat:@"massPoints[%lu] 必须是对象。", (unsigned long)index]);
    return nil;
  }
  NSDictionary *dictionary = (NSDictionary *)object;
  id identifierObject = dictionary[@"id"] ?: dictionary[@"identifier"];
  if (![identifierObject isKindOfClass:[NSString class]] || [identifierObject length] == 0 ||
      [identifierObject length] > LynxMapMaximumIdentifierLength) {
    LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration,
                    [NSString stringWithFormat:@"massPoints[%lu].id 无效。", (unsigned long)index]);
    return nil;
  }
  LynxMapCoordinate *coordinate = [LynxMapCoordinate coordinateWithObject:dictionary[@"coordinate"] error:error];
  if (coordinate == nil) return nil;
  BOOL valid = NO;
  NSString *title = LynxMapOptionalString(dictionary[@"title"], &valid);
  if (!valid || title.length > LynxMapMaximumMarkerTextLength) {
    LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration, @"massPoints.title 无效。");
    return nil;
  }
  NSString *subtitle = LynxMapOptionalString(dictionary[@"subtitle"], &valid);
  if (!valid || subtitle.length > LynxMapMaximumMarkerTextLength) {
    LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration, @"massPoints.subtitle 无效。");
    return nil;
  }
  LynxMapMassPoint *point = [[self alloc] init];
  point->_identifier = [identifierObject copy];
  point->_coordinate = [coordinate copy];
  point->_title = [title copy];
  point->_subtitle = [subtitle copy];
  return point;
}

- (id)copyWithZone:(NSZone *)zone {
  LynxMapMassPoint *copy = [[[self class] allocWithZone:zone] init];
  copy->_identifier = [_identifier copy];
  copy->_coordinate = [_coordinate copy];
  copy->_title = [_title copy];
  copy->_subtitle = [_subtitle copy];
  return copy;
}

@end

@implementation LynxMapLayerState

- (instancetype)initWithVisible:(BOOL)visible opacity:(double)opacity zIndex:(NSInteger)zIndex {
  return [self initWithVisible:visible
                        opacity:opacity
                         zIndex:zIndex
                        mapType:@"standard"
                 trafficEnabled:NO];
}

- (instancetype)initWithVisible:(BOOL)visible
                         opacity:(double)opacity
                          zIndex:(NSInteger)zIndex
                         mapType:(NSString *)mapType
                  trafficEnabled:(BOOL)trafficEnabled {
  self = [super init];
  if (self != nil) {
    _visible = visible;
    _opacity = opacity;
    _zIndex = zIndex;
    _mapType = [mapType copy] ?: @"standard";
    _trafficEnabled = trafficEnabled;
  }
  return self;
}

- (id)copyWithZone:(NSZone *)zone {
  return [[[self class] allocWithZone:zone] initWithVisible:self.visible
                                                   opacity:self.opacity
                                                    zIndex:self.zIndex
                                                   mapType:self.mapType
                                            trafficEnabled:self.trafficEnabled];
}

@end

@implementation LynxMapViewOptions

- (instancetype)initWithZoomEnabled:(BOOL)zoomEnabled
                       scrollEnabled:(BOOL)scrollEnabled
                       rotateEnabled:(BOOL)rotateEnabled
                 rotateCameraEnabled:(BOOL)rotateCameraEnabled
                       showsCompass:(BOOL)showsCompass
                         showsScale:(BOOL)showsScale
                        showsLabels:(BOOL)showsLabels
                     showsBuildings:(BOOL)showsBuildings
                     touchPOIEnabled:(BOOL)touchPOIEnabled {
  self = [super init];
  if (self != nil) {
    _zoomEnabled = zoomEnabled;
    _scrollEnabled = scrollEnabled;
    _rotateEnabled = rotateEnabled;
    _rotateCameraEnabled = rotateCameraEnabled;
    _showsCompass = showsCompass;
    _showsScale = showsScale;
    _showsLabels = showsLabels;
    _showsBuildings = showsBuildings;
    _touchPOIEnabled = touchPOIEnabled;
  }
  return self;
}

- (id)copyWithZone:(NSZone *)zone {
  return [[[self class] allocWithZone:zone]
      initWithZoomEnabled:self.zoomEnabled
             scrollEnabled:self.scrollEnabled
             rotateEnabled:self.rotateEnabled
       rotateCameraEnabled:self.rotateCameraEnabled
             showsCompass:self.showsCompass
               showsScale:self.showsScale
              showsLabels:self.showsLabels
           showsBuildings:self.showsBuildings
           touchPOIEnabled:self.touchPOIEnabled];
}

@end

@implementation LynxMapBounds

- (instancetype)initWithSouthWest:(LynxMapCoordinate *)southWest
                          northEast:(LynxMapCoordinate *)northEast {
  self = [super init];
  if (self != nil) {
    _southWest = [southWest copy];
    _northEast = [northEast copy];
  }
  return self;
}

+ (instancetype)boundsWithObject:(id)object error:(NSError * _Nullable * _Nullable)error {
  if ([object isKindOfClass:[LynxMapBounds class]]) {
    LynxMapBounds *bounds = (LynxMapBounds *)object;
    return [[self alloc] initWithSouthWest:bounds.southWest northEast:bounds.northEast];
  }
  if (![object isKindOfClass:[NSDictionary class]]) {
    LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration, @"bounds 必须是对象。");
    return nil;
  }
  NSDictionary *dictionary = (NSDictionary *)object;
  id southWestObject = dictionary[@"southwest"] ?: dictionary[@"southWest"] ?: dictionary[@"south-west"];
  id northEastObject = dictionary[@"northeast"] ?: dictionary[@"northEast"] ?: dictionary[@"north-east"];
  if (!LynxMapIsPresent(southWestObject) || !LynxMapIsPresent(northEastObject)) {
    LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration,
                    @"bounds 需要 southwest 和 northeast。");
    return nil;
  }
  LynxMapCoordinate *southWest =
      [LynxMapCoordinate coordinateWithObject:southWestObject error:error];
  LynxMapCoordinate *northEast =
      [LynxMapCoordinate coordinateWithObject:northEastObject error:error];
  if (southWest == nil || northEast == nil) {
    return nil;
  }
  if (southWest.latitude > northEast.latitude) {
    LynxMapSetError(error, LynxMapProviderErrorInvalidConfiguration,
                    @"bounds 的 southwest 纬度不能高于 northeast。");
    return nil;
  }
  return [[self alloc] initWithSouthWest:southWest northEast:northEast];
}

- (id)copyWithZone:(NSZone *)zone {
  return [[[self class] allocWithZone:zone] initWithSouthWest:self.southWest
                                                     northEast:self.northEast];
}

@end

@implementation LynxMapProviderConfiguration

- (instancetype)initWithProviderKey:(NSString *)providerKey
                       privacyAgreed:(BOOL)privacyAgreed
                       initialCamera:(LynxMapCamera *)initialCamera {
  self = [super init];
  if (self != nil) {
    _providerKey = [providerKey copy];
    _privacyAgreed = privacyAgreed;
    _initialCamera = [initialCamera copy];
  }
  return self;
}

- (id)copyWithZone:(NSZone *)zone {
  return [[[self class] allocWithZone:zone] initWithProviderKey:self.providerKey
                                                  privacyAgreed:self.privacyAgreed
                                                  initialCamera:self.initialCamera];
}

@end

@interface LynxMapUnavailableProviderAdapter ()
@property(nonatomic, readwrite, copy) NSString *providerIdentifier;
@property(nonatomic, readwrite) BOOL available;
@property(nonatomic, readwrite) LynxMapProviderCapabilities capabilities;
@property(nonatomic, readwrite, nullable) NSError *availabilityError;
@end

@implementation LynxMapUnavailableProviderAdapter

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _providerIdentifier = @"unavailable";
    _available = NO;
    _capabilities = 0;
    _availabilityError = LynxMapMakeProviderError(
        LynxMapProviderErrorUnavailable, @"地图 provider 不可用，请先接入对应 SDK。");
  }
  return self;
}

- (id<LynxMapProviderMapView>)createMapViewWithConfiguration:(LynxMapProviderConfiguration *)configuration
                                                    eventSink:(id<LynxMapProviderEventSink>)eventSink
                                                        error:(NSError * _Nullable * _Nullable)error {
  (void)configuration;
  (void)eventSink;
  LynxMapSetError(error, LynxMapProviderErrorUnavailable,
                  @"地图 provider 不可用，请先接入对应 SDK。");
  return nil;
}

- (void)startMapView:(id<LynxMapProviderMapView>)mapView {
  (void)mapView;
}

- (void)setMapView:(id<LynxMapProviderMapView>)mapView paused:(BOOL)paused {
  (void)mapView;
  (void)paused;
}

- (void)mapViewDidLayout:(id<LynxMapProviderMapView>)mapView {
  (void)mapView;
}

- (BOOL)updateMapView:(id<LynxMapProviderMapView>)mapView
   withConfiguration:(LynxMapProviderConfiguration *)configuration
               error:(NSError * _Nullable * _Nullable)error {
  (void)mapView;
  (void)configuration;
  LynxMapSetError(error, LynxMapProviderErrorUnavailable,
                  @"地图 provider 不可用，请先接入对应 SDK。");
  return NO;
}

- (BOOL)updateMapView:(id<LynxMapProviderMapView>)mapView
               camera:(LynxMapCamera *)camera
               markers:(NSArray<LynxMapMarker *> *)markers
             polylines:(NSArray<LynxMapPolyline *> *)polylines
            massPoints:(NSArray<LynxMapMassPoint *> *)massPoints
          layerState:(LynxMapLayerState *)layerState
         viewOptions:(LynxMapViewOptions *)viewOptions
               error:(NSError * _Nullable * _Nullable)error {
  (void)mapView;
  (void)camera;
  (void)markers;
  (void)polylines;
  (void)massPoints;
  (void)layerState;
  (void)viewOptions;
  LynxMapSetError(error, LynxMapProviderErrorUnavailable,
                  @"地图 provider 不可用，请先接入对应 SDK。");
  return NO;
}

- (LynxMapCamera * _Nullable)currentCameraForMapView:(id<LynxMapProviderMapView>)mapView
                                      error:(NSError * _Nullable * _Nullable)error {
  (void)mapView;
  LynxMapSetError(error, LynxMapProviderErrorUnavailable,
                  @"地图 provider 不可用，请先接入对应 SDK。");
  return nil;
}

- (NSDictionary<NSString *, NSNumber *> * _Nullable)screenPointForCoordinate:(LynxMapCoordinate *)coordinate
                                                                      mapView:(id<LynxMapProviderMapView>)mapView
                                                                        error:(NSError * _Nullable * _Nullable)error {
  (void)coordinate;
  (void)mapView;
  LynxMapSetError(error, LynxMapProviderErrorUnavailable,
                  @"地图 provider 不可用，请先接入对应 SDK。");
  return nil;
}

- (void)moveCamera:(LynxMapCamera *)camera
           mapView:(id<LynxMapProviderMapView>)mapView
          animated:(BOOL)animated
        completion:(LynxMapProviderOperationCompletion)completion {
  (void)camera;
  (void)mapView;
  (void)animated;
  if (completion != nil) {
    completion(self.availabilityError);
  }
}

- (void)fitBounds:(LynxMapBounds *)bounds
           mapView:(id<LynxMapProviderMapView>)mapView
           padding:(UIEdgeInsets)padding
          animated:(BOOL)animated
        completion:(LynxMapProviderOperationCompletion)completion {
  (void)bounds;
  (void)mapView;
  (void)padding;
  (void)animated;
  if (completion != nil) {
    completion(self.availabilityError);
  }
}

- (void)setMarkerWithIdentifier:(NSString *)identifier
                         selected:(BOOL)selected
                          mapView:(id<LynxMapProviderMapView>)mapView
                          animated:(BOOL)animated
                        completion:(LynxMapProviderOperationCompletion)completion {
  (void)identifier;
  (void)selected;
  (void)mapView;
  (void)animated;
  if (completion != nil) completion(self.availabilityError);
}

- (void)showMarkersWithIdentifiers:(NSArray<NSString *> *)identifiers
                           mapView:(id<LynxMapProviderMapView>)mapView
                           padding:(UIEdgeInsets)padding
                          animated:(BOOL)animated
                        completion:(LynxMapProviderOperationCompletion)completion {
  (void)identifiers;
  (void)mapView;
  (void)padding;
  (void)animated;
  if (completion != nil) completion(self.availabilityError);
}

- (void)cancelPendingOperationsForMapView:(id<LynxMapProviderMapView>)mapView {
  (void)mapView;
}

- (void)removeAllListenersFromMapView:(id<LynxMapProviderMapView>)mapView {
  (void)mapView;
}

- (void)removeAllOverlaysFromMapView:(id<LynxMapProviderMapView>)mapView {
  (void)mapView;
}

- (void)clearIconCacheForMapView:(id<LynxMapProviderMapView>)mapView {
  (void)mapView;
}

- (void)destroyMapView:(id<LynxMapProviderMapView>)mapView {
  (void)mapView;
}

@end

static LynxMapProviderAdapterFactory LynxMapCurrentAdapterFactory;
static LynxMapProviderConfiguration *LynxMapCurrentDefaultConfiguration;

@implementation LynxMapProviderRegistry

+ (void)setAdapterFactory:(LynxMapProviderAdapterFactory)factory {
  @synchronized(self) {
    LynxMapCurrentAdapterFactory = [factory copy];
  }
}

+ (void)setDefaultConfiguration:(LynxMapProviderConfiguration *)configuration {
  @synchronized(self) {
    LynxMapCurrentDefaultConfiguration = [configuration copy];
  }
}

+ (LynxMapProviderConfiguration *)defaultConfiguration {
  @synchronized(self) {
    if (LynxMapCurrentDefaultConfiguration != nil) {
      return [LynxMapCurrentDefaultConfiguration copy];
    }
  }
  return [[LynxMapProviderConfiguration alloc] initWithProviderKey:nil
                                                       privacyAgreed:NO
                                                       initialCamera:nil];
}

+ (id<LynxMapProviderAdapter>)makeAdapter {
  LynxMapProviderAdapterFactory factory = nil;
  @synchronized(self) {
    factory = [LynxMapCurrentAdapterFactory copy];
  }
  id<LynxMapProviderAdapter> adapter = factory != nil ? factory() : nil;
  if (adapter == nil || ![adapter conformsToProtocol:@protocol(LynxMapProviderAdapter)]) {
    return [[LynxMapUnavailableProviderAdapter alloc] init];
  }
  return adapter;
}

@end
