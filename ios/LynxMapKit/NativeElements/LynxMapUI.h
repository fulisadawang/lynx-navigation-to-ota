// Lynx 4.1 `lynx-map` Custom Native Element。
//
// 公开给 Lynx 的只有 tag、props、events 和 UI Methods；地图厂商对象全部留在
// LynxMapProviderAdapter 内部。Key 与隐私状态由宿主配置，不通过页面 props 设置。
//
// Props：center={latitude, longitude}（也接受 lat/lng 或 [lat, lng]）、zoom、bearing、pitch、anchor、
// markers、polylines、layer-visible、layer-opacity、layer-z-index、map-type、traffic-enabled，
// 以及 zoom/scroll/rotate、compass/scale/labels/buildings/POI 等交互和控件开关。
// markers/polyline 的 id 与坐标必须有效；列表和 polyline 点数有固定上限，错误会发送 error。
// Events：ready、error、maptap、longpress、markertap、markerselected、markerdeselected、markerdrag、regionchange。
// 事件 detail 只包含可序列化坐标、
// id、zoom、source、phase、reason 和错误字符串，不包含 MAMapView、MAAnnotation 或 MAPolyline。
// UI Methods：moveCamera({center?, zoom?, bearing?, pitch?, anchor?, animated?})、getCamera()、
// getCameraState()、fitBounds({bounds, padding?, animated?})、selectMarker()、deselectMarker()、
// showMarkers()、projectCoordinate()、getCapabilities()、getPerformanceSnapshot()。
// callback 使用 Lynx 4.1 kUIMethod* code。

#import <Lynx/LynxUI.h>

NS_ASSUME_NONNULL_BEGIN

@interface LynxMapUI : LynxUI <UIView *>
@end

NS_ASSUME_NONNULL_END
