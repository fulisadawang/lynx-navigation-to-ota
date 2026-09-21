import AMapFoundationKit
import AMapSearchKit
import CoreLocation
import Foundation
import Lynx

/**
 * AMapSearchKit 的 Lynx service 边界。
 *
 * 页面只接收 JSON 化的 POI、地理编码和路线结果；AMapSearchAPI、request/response 以及
 * delegate 都由当前 LynxContext 独占。路线 polyline 可直接回填给 lynx-map 渲染。
 */
@objc(LynxMapSearchModule)
@objcMembers
public final class LynxMapSearchModule: NSObject, LynxContextModule, AMapSearchDelegate {
    public static var name: String { "LynxMapSearchModule" }

    public static var methodLookup: [String: String] {
        [
            "searchPOI": NSStringFromSelector(#selector(searchPOI(_:completion:))),
            "reverseGeocode": NSStringFromSelector(#selector(reverseGeocode(_:completion:))),
            "geocode": NSStringFromSelector(#selector(geocode(_:completion:))),
            "searchRoute": NSStringFromSelector(#selector(searchRoute(_:completion:))),
            "searchTransit": NSStringFromSelector(#selector(searchTransit(_:completion:))),
            "cancelSearch": NSStringFromSelector(#selector(cancelSearch(_:))),
        ]
    }

    private enum SearchError: LocalizedError {
        case invalidOptions(String)
        case privacyNotConfigured
        case requestRejected
        case cancelled

        var errorDescription: String? {
            switch self {
            case let .invalidOptions(message): return message
            case .privacyNotConfigured: return "高德搜索隐私配置未完成"
            case .requestRejected: return "高德搜索请求未被接受"
            case .cancelled: return "搜索请求已取消"
            }
        }
    }

    private enum RequestKind {
        case poi
        case reverseGeocode
        case geocode
        case route
    }

    private final class PendingRequest {
        let kind: RequestKind
        let completion: (NSDictionary) -> Void

        init(kind: RequestKind, completion: @escaping (NSDictionary) -> Void) {
            self.kind = kind
            self.completion = completion
        }
    }

    private weak var lynxContext: LynxContext?
    private var searchAPI: AMapSearchAPI?
    private var pending: [ObjectIdentifier: PendingRequest] = [:]
    private var destroyed = false

    public init(param: Any) {
        super.init()
    }

    public override init() {
        super.init()
    }

    public required init(lynxContext: LynxContext) {
        self.lynxContext = lynxContext
        super.init()
    }

    public required init(lynxContext: LynxContext, withParam param: Any) {
        self.lynxContext = lynxContext
        super.init()
    }

    public func destroy() {
        destroyed = true
        searchAPI?.cancelAllRequests()
        let requests = pending.values
        pending.removeAll()
        requests.forEach { $0.completion(Self.result(code: 1207, message: SearchError.cancelled.localizedDescription)) }
        searchAPI?.delegate = nil
        searchAPI = nil
        lynxContext = nil
    }

    /** 关键词 POI 搜索。options: keyword、city、page、offset、types、cityLimit。 */
    public func searchPOI(
        _ optionsJSON: String,
        completion: @escaping (NSDictionary) -> Void
    ) {
        onMain { [weak self] in
            guard let self else {
                completion(Self.result(code: 1207, message: "搜索服务实例已销毁"))
                return
            }
            do {
                let options = try Self.object(from: optionsJSON)
                try self.requireReady()
                let keyword = try Self.requiredString(options, key: "keyword", maxLength: 128)
                let request = AMapPOIKeywordsSearchRequest()
                request.keywords = keyword
                request.city = Self.optionalString(options, key: "city", maxLength: 64)
                request.types = Self.optionalString(options, key: "types", maxLength: 256)
                request.cityLimit = (options["cityLimit"] as? Bool) ?? false
                request.page = try Self.integer(options, key: "page", defaultValue: 1, range: 1...100)
                request.offset = try Self.integer(options, key: "offset", defaultValue: 20, range: 1...25)
                if let location = try Self.optionalCoordinate(options["location"], key: "location") {
                    request.location = AMapGeoPoint.location(
                        withLatitude: CGFloat(location.latitude), longitude: CGFloat(location.longitude)
                    )
                }
                self.submit(request, kind: .poi, completion: completion)
                self.searchAPI?.aMapPOIKeywordsSearch(request)
            } catch {
                completion(Self.result(code: Self.code(for: error), message: error.localizedDescription))
            }
        }
    }

    /** 逆地理编码。options: latitude、longitude、radius、requireExtension。 */
    public func reverseGeocode(
        _ optionsJSON: String,
        completion: @escaping (NSDictionary) -> Void
    ) {
        onMain { [weak self] in
            guard let self else {
                completion(Self.result(code: 1207, message: "搜索服务实例已销毁"))
                return
            }
            do {
                let options = try Self.object(from: optionsJSON)
                try self.requireReady()
                let coordinate = try Self.requiredCoordinate(options, key: "coordinate")
                let request = AMapReGeocodeSearchRequest()
                request.location = AMapGeoPoint.location(
                    withLatitude: CGFloat(coordinate.latitude), longitude: CGFloat(coordinate.longitude)
                )
                request.radius = try Self.integer(options, key: "radius", defaultValue: 1000, range: 0...3000)
                request.requireExtension = (options["requireExtension"] as? Bool) ?? true
                self.submit(request, kind: .reverseGeocode, completion: completion)
                self.searchAPI?.aMapReGoecodeSearch(request)
            } catch {
                completion(Self.result(code: Self.code(for: error), message: error.localizedDescription))
            }
        }
    }

    /** 地理编码。options: address、city。 */
    public func geocode(
        _ optionsJSON: String,
        completion: @escaping (NSDictionary) -> Void
    ) {
        onMain { [weak self] in
            guard let self else {
                completion(Self.result(code: 1207, message: "搜索服务实例已销毁"))
                return
            }
            do {
                let options = try Self.object(from: optionsJSON)
                try self.requireReady()
                let request = AMapGeocodeSearchRequest()
                request.address = try Self.requiredString(options, key: "address", maxLength: 256)
                request.city = Self.optionalString(options, key: "city", maxLength: 64)
                self.submit(request, kind: .geocode, completion: completion)
                self.searchAPI?.aMapGeocodeSearch(request)
            } catch {
                completion(Self.result(code: Self.code(for: error), message: error.localizedDescription))
            }
        }
    }

    /** 路线规划。options: mode(driving/walking/riding)、origin、destination、strategy。 */
    public func searchRoute(
        _ optionsJSON: String,
        completion: @escaping (NSDictionary) -> Void
    ) {
        onMain { [weak self] in
            guard let self else {
                completion(Self.result(code: 1207, message: "搜索服务实例已销毁"))
                return
            }
            do {
                let options = try Self.object(from: optionsJSON)
                try self.requireReady()
                let origin = try Self.requiredCoordinate(options, key: "origin")
                let destination = try Self.requiredCoordinate(options, key: "destination")
                let originPoint = AMapGeoPoint.location(
                    withLatitude: CGFloat(origin.latitude), longitude: CGFloat(origin.longitude)
                )
                let destinationPoint = AMapGeoPoint.location(
                    withLatitude: CGFloat(destination.latitude), longitude: CGFloat(destination.longitude)
                )
                let mode = (options["mode"] as? String ?? "driving").lowercased()
                let request: AMapRouteSearchBaseRequest
                let submitRoute: (AMapRouteSearchBaseRequest) -> Void
                switch mode {
                case "walking":
                    let walking = AMapWalkingRouteSearchRequest()
                    walking.origin = originPoint
                    walking.destination = destinationPoint
                    walking.showFieldsType = [.cost, .navi, .polyline]
                    request = walking
                    submitRoute = { [weak self] request in
                        self?.searchAPI?.aMapWalkingRouteSearch(request as! AMapWalkingRouteSearchRequest)
                    }
                case "riding", "cycling":
                    let riding = AMapRidingRouteSearchRequest()
                    riding.origin = originPoint
                    riding.destination = destinationPoint
                    riding.showFieldsType = [.cost, .navi, .polyline]
                    request = riding
                    submitRoute = { [weak self] request in
                        self?.searchAPI?.aMapRidingRouteSearch(request as! AMapRidingRouteSearchRequest)
                    }
                case "driving":
                    let driving = AMapDrivingCalRouteSearchRequest()
                    driving.origin = originPoint
                    driving.destination = destinationPoint
                    driving.strategy = try Self.integer(options, key: "strategy", defaultValue: 32, range: 0...100)
                    // V2 默认只返回基础字段；没有显式请求 polyline 时 AMapPath.polyline 为空，
                    // Lynx 路线页无法把高德结果转换成可渲染的 Polyline。
                    driving.showFieldType = [.cost, .tmcs, .navi, .polyline]
                    if let waypoints = try Self.coordinateArray(options["waypoints"], key: "waypoints", maxCount: 16) {
                        driving.waypoints = waypoints.map {
                            AMapGeoPoint.location(withLatitude: CGFloat($0.latitude), longitude: CGFloat($0.longitude))
                        }
                    }
                    request = driving
                    submitRoute = { [weak self] request in
                        self?.searchAPI?.aMapDrivingV2RouteSearch(request as! AMapDrivingCalRouteSearchRequest)
                    }
                default:
                    throw SearchError.invalidOptions("mode 只支持 driving、walking、riding")
                }
                self.submit(request, kind: .route, completion: completion)
                submitRoute(request)
            } catch {
                completion(Self.result(code: Self.code(for: error), message: error.localizedDescription))
            }
        }
    }

    /** 公交/地铁路径规划。options: origin、destination、city、destinationCity、strategy。 */
    public func searchTransit(
        _ optionsJSON: String,
        completion: @escaping (NSDictionary) -> Void
    ) {
        onMain { [weak self] in
            guard let self else {
                completion(Self.result(code: 1207, message: "搜索服务实例已销毁"))
                return
            }
            do {
                let options = try Self.object(from: optionsJSON)
                try self.requireReady()
                let origin = try Self.requiredCoordinate(options, key: "origin")
                let destination = try Self.requiredCoordinate(options, key: "destination")
                let city = try Self.requiredString(options, key: "city", maxLength: 32)
                let request = AMapTransitRouteSearchRequest()
                request.origin = AMapGeoPoint.location(withLatitude: CGFloat(origin.latitude), longitude: CGFloat(origin.longitude))
                request.destination = AMapGeoPoint.location(withLatitude: CGFloat(destination.latitude), longitude: CGFloat(destination.longitude))
                request.city = city
                request.destinationCity = Self.optionalString(options, key: "destinationCity", maxLength: 32) ?? city
                request.strategy = try Self.integer(options, key: "strategy", defaultValue: 0, range: 0...8)
                request.maxTrans = try Self.integer(options, key: "maxTrans", defaultValue: 4, range: 0...4)
                request.alternativeRoute = try Self.integer(options, key: "alternativeRoute", defaultValue: 5, range: 1...10)
                request.date = Self.optionalString(options, key: "date", maxLength: 16)
                request.time = Self.optionalString(options, key: "time", maxLength: 8)
                request.showFieldsType = [.cost, .navi, .polyline]
                self.submit(request, kind: .route, completion: completion)
                self.searchAPI?.aMapTransitRouteSearch(request)
            } catch {
                completion(Self.result(code: Self.code(for: error), message: error.localizedDescription))
            }
        }
    }

    /** 取消所有搜索并结束页面仍持有的 callback。 */
    public func cancelSearch(_ completion: @escaping (NSDictionary) -> Void) {
        onMain { [weak self] in
            guard let self else {
                completion(Self.result(code: 1207, message: "搜索服务实例已销毁"))
                return
            }
            self.searchAPI?.cancelAllRequests()
            let requests = self.pending.values
            self.pending.removeAll()
            requests.forEach { $0.completion(Self.result(code: 1207, message: SearchError.cancelled.localizedDescription)) }
            completion(Self.result(code: 0, message: "搜索已取消"))
        }
    }

    // MARK: - AMapSearchDelegate

    public func onPOISearchDone(
        _ request: AMapPOISearchBaseRequest,
        response: AMapPOISearchResponse
    ) {
        finish(request, data: [
            "count": response.count,
            "pois": response.pois.prefix(25).map(Self.poiData),
        ])
    }

    public func onGeocodeSearchDone(
        _ request: AMapGeocodeSearchRequest,
        response: AMapGeocodeSearchResponse
    ) {
        finish(request, data: [
            "count": response.count,
            "geocodes": response.geocodes.prefix(10).map(Self.geocodeData),
        ])
    }

    public func onReGeocodeSearchDone(
        _ request: AMapReGeocodeSearchRequest,
        response: AMapReGeocodeSearchResponse
    ) {
        finish(request, data: ["reGeocode": Self.reGeocodeData(response.regeocode)])
    }

    public func onRouteSearchDone(
        _ request: AMapRouteSearchBaseRequest,
        response: AMapRouteSearchResponse
    ) {
        let paths = (response.route?.paths ?? []).prefix(3).map(Self.routePathData)
        let transits = (response.route?.transits ?? []).prefix(10).map(Self.transitData)
        finish(request, data: [
            "count": response.count,
            "paths": paths,
            "distance": response.route?.distance ?? 0,
            "transits": transits,
        ])
    }

    public func aMapSearchRequest(_ request: Any, didFailWithError error: Error) {
        guard let request = request as AnyObject? else { return }
        finish(request, error: error)
    }

    // MARK: - Request and serialization

    private func requireReady() throws {
        guard !destroyed else { throw SearchError.cancelled }
        guard LynxMapModuleRuntime.isAMapPrivacyAgreed() else {
            throw SearchError.privacyNotConfigured
        }
        if searchAPI == nil {
            AMapSearchAPI.updatePrivacyShow(.didShow, privacyInfo: .didContain)
            AMapSearchAPI.updatePrivacyAgree(.didAgree)
            guard let api = AMapSearchAPI() else {
                throw SearchError.requestRejected
            }
            api.delegate = self
            api.timeout = 20
            searchAPI = api
        }
    }

    private func submit(
        _ request: AnyObject,
        kind: RequestKind,
        completion: @escaping (NSDictionary) -> Void
    ) {
        pending[ObjectIdentifier(request)] = PendingRequest(kind: kind, completion: completion)
    }

    private func finish(_ request: AnyObject, data: [String: Any] = [:]) {
        guard let pendingRequest = pending.removeValue(forKey: ObjectIdentifier(request)) else { return }
        pendingRequest.completion(Self.result(code: 0, message: "搜索成功", data: data))
    }

    private func finish(_ request: AnyObject, error: Error) {
        guard let pendingRequest = pending.removeValue(forKey: ObjectIdentifier(request)) else { return }
        pendingRequest.completion(Self.result(code: 1206, message: "高德搜索失败：\(error.localizedDescription)"))
    }

    private static func object(from json: String) throws -> [String: Any] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        let value = try JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed])
        guard let dictionary = value as? [String: Any] else {
            throw SearchError.invalidOptions("搜索 options 必须是 JSON Object")
        }
        return dictionary
    }

    private static func requiredString(_ object: [String: Any], key: String, maxLength: Int) throws -> String {
        guard let value = object[key] as? String else {
            throw SearchError.invalidOptions("\(key) 必须是字符串")
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= maxLength else {
            throw SearchError.invalidOptions("\(key) 不能为空且不能超过 \(maxLength) 个字符")
        }
        return normalized
    }

    private static func optionalString(_ object: [String: Any], key: String, maxLength: Int) -> String? {
        guard let value = object[key] as? String else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty || normalized.count > maxLength ? nil : normalized
    }

    private static func integer(
        _ object: [String: Any],
        key: String,
        defaultValue: Int,
        range: ClosedRange<Int>
    ) throws -> Int {
        let value = (object[key] as? NSNumber)?.intValue ?? defaultValue
        guard range.contains(value) else {
            throw SearchError.invalidOptions("\(key) 必须在 \(range.lowerBound) 到 \(range.upperBound) 之间")
        }
        return value
    }

    private static func requiredCoordinate(_ object: [String: Any], key: String) throws -> (latitude: Double, longitude: Double) {
        guard let value = object[key] else {
            throw SearchError.invalidOptions("\(key) 必须包含 latitude 和 longitude")
        }
        guard let coordinate = try optionalCoordinate(value, key: key) else {
            throw SearchError.invalidOptions("\(key) 坐标无效")
        }
        return coordinate
    }

    private static func optionalCoordinate(
        _ value: Any?,
        key: String
    ) throws -> (latitude: Double, longitude: Double)? {
        guard let value else { return nil }
        if let dictionary = value as? [String: Any],
           let latitude = (dictionary["latitude"] as? NSNumber)?.doubleValue,
           let longitude = (dictionary["longitude"] as? NSNumber)?.doubleValue,
           CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: latitude, longitude: longitude)) {
            return (latitude, longitude)
        }
        throw SearchError.invalidOptions("\(key) 坐标无效")
    }

    private static func coordinateArray(
        _ value: Any?,
        key: String,
        maxCount: Int
    ) throws -> [(latitude: Double, longitude: Double)]? {
        guard let values = value as? [Any] else { return nil }
        guard values.count <= maxCount else {
            throw SearchError.invalidOptions("\(key) 不能超过 \(maxCount) 个点")
        }
        return try values.map { value in
            guard let coordinate = try optionalCoordinate(value, key: key) else {
                throw SearchError.invalidOptions("\(key) 坐标无效")
            }
            return coordinate
        }
    }

    private static func poiData(_ poi: AMapPOI) -> [String: Any] {
        var data: [String: Any] = [
            "id": poi.uid ?? "",
            "name": poi.name ?? "",
            "type": poi.type ?? "",
            "typecode": poi.typecode ?? "",
            "address": poi.address ?? "",
            "tel": poi.tel ?? "",
            "distance": poi.distance,
            "city": poi.city ?? "",
            "district": poi.district ?? "",
        ]
        if let location = poi.location {
            data["coordinate"] = ["latitude": location.latitude, "longitude": location.longitude]
        }
        return data
    }

    private static func geocodeData(_ geocode: AMapGeocode) -> [String: Any] {
        var data: [String: Any] = [
            "formattedAddress": geocode.formattedAddress ?? "",
            "province": geocode.province ?? "",
            "city": geocode.city ?? "",
            "district": geocode.district ?? "",
            "adcode": geocode.adcode ?? "",
            "level": geocode.level ?? "",
        ]
        if let location = geocode.location {
            data["coordinate"] = ["latitude": location.latitude, "longitude": location.longitude]
        }
        return data
    }

    private static func reGeocodeData(_ value: AMapReGeocode?) -> [String: Any] {
        guard let value else { return [:] }
        let component = value.addressComponent
        var data: [String: Any] = [
            "formattedAddress": value.formattedAddress ?? "",
            "province": component?.province ?? "",
            "city": component?.city ?? "",
            "district": component?.district ?? "",
            "township": component?.township ?? "",
            "street": component?.streetNumber?.street ?? "",
            "number": component?.streetNumber?.number ?? "",
            "adcode": component?.adcode ?? "",
        ]
        if let poi = value.pois?.first, let location = poi.location {
            data["nearestPOI"] = [
                "id": poi.uid ?? "",
                "name": poi.name ?? "",
                "coordinate": ["latitude": location.latitude, "longitude": location.longitude],
            ]
        }
        return data
    }

    private static func routePathData(_ path: AMapPath) -> [String: Any] {
        [
            "distance": path.distance,
            "duration": path.duration,
            "tolls": path.tolls,
            "totalTrafficLights": path.totalTrafficLights,
            "polyline": parsePolyline(path.polyline),
            "steps": (path.steps ?? []).prefix(64).map { step in
                [
                    "instruction": step.instruction ?? "",
                    "road": step.road ?? "",
                    "distance": step.distance,
                    "duration": step.duration,
                    "polyline": parsePolyline(step.polyline),
                ]
            },
        ]
    }

    private static func transitData(_ transit: AMapTransit) -> [String: Any] {
        [
            "cost": transit.cost,
            "duration": transit.duration,
            "distance": transit.distance,
            "walkingDistance": transit.walkingDistance,
            "nightflag": transit.nightflag,
            "segments": (transit.segments ?? []).prefix(32).map(segmentData),
        ]
    }

    private static func segmentData(_ segment: AMapSegment) -> [String: Any] {
        var data: [String: Any] = [
            "enterName": segment.enterName ?? "",
            "exitName": segment.exitName ?? "",
            "lines": (segment.buslines ?? []).prefix(8).map(busLineData),
        ]
        if let walking = segment.walking {
            data["walking"] = [
                "distance": walking.distance,
                "duration": walking.duration,
                "polyline": (walking.steps ?? []).flatMap { parsePolyline($0.polyline) },
            ]
        }
        return data
    }

    private static func busLineData(_ line: AMapBusLine) -> [String: Any] {
        var data: [String: Any] = [
            "id": line.uid ?? "",
            "name": line.name ?? "",
            "type": line.type ?? "",
            "distance": line.distance,
            "duration": line.duration,
            "totalPrice": line.totalPrice,
            "polyline": parsePolyline(line.polyline),
        ]
        if let departure = line.departureStop?.name { data["departureStop"] = departure }
        if let arrival = line.arrivalStop?.name { data["arrivalStop"] = arrival }
        return data
    }

    private static func parsePolyline(_ value: String?) -> [[String: Double]] {
        guard let value, !value.isEmpty else { return [] }
        return value.split(separator: ";").compactMap { point in
            let pair = point.split(separator: ",")
            guard pair.count == 2,
                  let longitude = Double(pair[0]),
                  let latitude = Double(pair[1]),
                  CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
            else { return nil }
            return ["latitude": latitude, "longitude": longitude]
        }
    }

    private static func code(for error: Error) -> Int {
        if let error = error as? SearchError {
            switch error {
            case .invalidOptions: return 1201
            case .privacyNotConfigured: return 1202
            case .requestRejected: return 1205
            case .cancelled: return 1207
            }
        }
        return 1206
    }

    private static func result(
        code: Int,
        message: String,
        data: [String: Any] = [:]
    ) -> NSDictionary {
        ["code": code, "message": message, "data": data]
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
