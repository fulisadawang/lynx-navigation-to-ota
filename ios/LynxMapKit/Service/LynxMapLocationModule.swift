import CoreLocation
import Foundation
import Lynx
import AMapLocationKit

/**
 * AMapLocationKit 的 Lynx 服务边界。
 *
 * 页面只收到可序列化的位置字典和结构化错误；定位管理器、CLLocation 和逆地理对象
 * 都由当前 LynxContext 独占。连续定位通过 GlobalEventEmitter 发送 lynxMapLocation，
 * 页面销毁时会主动停止并解除 delegate，避免后台定位和闭包持有页面。
 */
@objc(LynxMapLocationModule)
@objcMembers
public final class LynxMapLocationModule: NSObject, LynxContextModule, AMapLocationManagerDelegate {
    public static var name: String { "LynxMapLocationModule" }

    public static var methodLookup: [String: String] {
        [
            "getCurrentLocation": NSStringFromSelector(
                #selector(getCurrentLocation(_:completion:))
            ),
            "startLocation": NSStringFromSelector(
                #selector(startLocation(_:completion:))
            ),
            "stopLocation": NSStringFromSelector(
                #selector(stopLocation(_:))
            ),
            "getAuthorizationStatus": NSStringFromSelector(
                #selector(getAuthorizationStatus(_:))
            ),
        ]
    }

    private struct LocationOptions {
        let withReGeocode: Bool
        let desiredAccuracy: CLLocationAccuracy
        let distanceFilter: CLLocationDistance
        let locationTimeout: Int
        let reGeocodeTimeout: Int

        static func parse(_ optionsJSON: String) throws -> LocationOptions {
            let trimmed = optionsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            var object: [String: Any] = [:]
            if !trimmed.isEmpty {
                let value = try JSONSerialization.jsonObject(
                    with: Data(trimmed.utf8),
                    options: [.fragmentsAllowed]
                )
                guard let dictionary = value as? [String: Any] else {
                    throw LocationError.invalidOptions("定位 options 必须是 JSON Object")
                }
                object = dictionary
            }

            let withReGeocode = object["withReGeocode"] as? Bool ?? false
            let desiredAccuracy = (object["desiredAccuracy"] as? NSNumber)?.doubleValue
                ?? kCLLocationAccuracyHundredMeters
            let distanceFilter = (object["distanceFilter"] as? NSNumber)?.doubleValue
                ?? kCLDistanceFilterNone
            let locationTimeout = (object["locationTimeout"] as? NSNumber)?.intValue ?? 8
            let reGeocodeTimeout = (object["reGeocodeTimeout"] as? NSNumber)?.intValue ?? 5

            let isAppleAccuracyConstant = desiredAccuracy == kCLLocationAccuracyBestForNavigation ||
                desiredAccuracy == kCLLocationAccuracyBest
            guard desiredAccuracy.isFinite,
                  isAppleAccuracyConstant || (desiredAccuracy >= 1 && desiredAccuracy <= 10_000) else {
                throw LocationError.invalidOptions("desiredAccuracy 必须是 Apple 精度常量或 1 到 10000 米")
            }
            guard distanceFilter == kCLDistanceFilterNone ||
                    (distanceFilter.isFinite && distanceFilter >= 0 && distanceFilter <= 10_000) else {
                throw LocationError.invalidOptions("distanceFilter 必须为 -1 或 0 到 10000")
            }
            guard (2...60).contains(locationTimeout) else {
                throw LocationError.invalidOptions("locationTimeout 必须在 2 到 60 秒之间")
            }
            guard (2...60).contains(reGeocodeTimeout) else {
                throw LocationError.invalidOptions("reGeocodeTimeout 必须在 2 到 60 秒之间")
            }

            return LocationOptions(
                withReGeocode: withReGeocode,
                desiredAccuracy: desiredAccuracy,
                distanceFilter: distanceFilter,
                locationTimeout: locationTimeout,
                reGeocodeTimeout: reGeocodeTimeout
            )
        }
    }

    private enum LocationError: LocalizedError {
        case invalidOptions(String)
        case privacyNotConfigured
        case servicesDisabled
        case authorizationDenied
        case requestRejected
        case cancelled

        var errorDescription: String? {
            switch self {
            case let .invalidOptions(message): return message
            case .privacyNotConfigured: return "高德定位隐私配置未完成"
            case .servicesDisabled: return "系统定位服务未开启"
            case .authorizationDenied: return "应用没有定位权限"
            case .requestRejected: return "高德定位请求未被接受"
            case .cancelled: return "定位请求已取消"
            }
        }
    }

    private weak var lynxContext: LynxContext?
    private var locationManager: AMapLocationManager?
    private var pendingCompletion: ((NSDictionary) -> Void)?
    private var requestGeneration: UInt = 0
    private var continuousLocation = false
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
        continuousLocation = false
        locationManager?.stopUpdatingLocation()
        locationManager?.delegate = nil
        locationManager = nil
        requestGeneration &+= 1
        finishPending(with: LocationError.cancelled)
        lynxContext = nil
    }

    /** 单次定位；optionsJSON 可设置逆地理、精度和超时。 */
    public func getCurrentLocation(
        _ optionsJSON: String,
        completion: @escaping (NSDictionary) -> Void
    ) {
        onMain { [weak self] in
            guard let self else {
                completion(Self.result(code: 1207, message: "定位服务实例已销毁"))
                return
            }
            self.requestCurrentLocation(optionsJSON: optionsJSON, completion: completion)
        }
    }

    /** 开始连续定位；位置通过 lynxMapLocation GlobalEvent 发送。 */
    public func startLocation(
        _ optionsJSON: String,
        completion: @escaping (NSDictionary) -> Void
    ) {
        onMain { [weak self] in
            guard let self else {
                completion(Self.result(code: 1207, message: "定位服务实例已销毁"))
                return
            }
            do {
                let options = try LocationOptions.parse(optionsJSON)
                try self.requireLocationReady()
                let manager = self.configuredManager(options)
                self.continuousLocation = true
                manager.startUpdatingLocation()
                completion(Self.result(
                    code: 0,
                    message: "连续定位已启动",
                    data: ["status": "running"]
                ))
            } catch {
                completion(Self.result(code: Self.code(for: error), message: error.localizedDescription))
            }
        }
    }

    /** 停止连续定位；若有未完成的单次请求也会返回取消。 */
    public func stopLocation(_ completion: @escaping (NSDictionary) -> Void) {
        onMain { [weak self] in
            guard let self else {
                completion(Self.result(code: 1207, message: "定位服务实例已销毁"))
                return
            }
            self.continuousLocation = false
            self.locationManager?.stopUpdatingLocation()
            self.requestGeneration &+= 1
            self.finishPending(with: LocationError.cancelled)
            completion(Self.result(code: 0, message: "定位已停止", data: ["status": "stopped"]))
        }
    }

    /** 返回系统定位权限和精确定位状态，不包含设备标识。 */
    public func getAuthorizationStatus(_ completion: @escaping (NSDictionary) -> Void) {
        onMain {
            let status = CLLocationManager().authorizationStatus
            let accuracy: String
            if #available(iOS 14.0, *) {
                accuracy = status == .authorizedAlways || status == .authorizedWhenInUse
                    ? (CLLocationManager().accuracyAuthorization == .fullAccuracy ? "full" : "reduced")
                    : "unknown"
            } else {
                accuracy = "unknown"
            }
            completion(Self.result(
                code: 0,
                message: "定位权限状态已获取",
                data: [
                    "status": Self.authorizationName(status),
                    "accuracy": accuracy,
                    "servicesEnabled": CLLocationManager.locationServicesEnabled(),
                ]
            ))
        }
    }

    // MARK: - AMapLocationManagerDelegate

    public func amapLocationManager(
        _ manager: AMapLocationManager,
        didUpdate location: CLLocation,
        reGeocode: AMapLocationReGeocode?
    ) {
        guard !destroyed, continuousLocation else { return }
        emitLocation(location, reGeocode: reGeocode)
    }

    public func amapLocationManager(
        _ manager: AMapLocationManager,
        didFailWithError error: Error
    ) {
        guard !destroyed else { return }
        if pendingCompletion != nil {
            finishPending(with: error)
        } else if continuousLocation {
            emit("lynxMapLocationError", payload: [
                "code": "LOCATION_PROVIDER_ERROR",
                "message": "连续定位失败",
                "providerCode": (error as NSError).code,
            ])
        }
    }

    public func amapLocationManager(
        _ manager: AMapLocationManager,
        doRequireLocationAuth locationManager: CLLocationManager
    ) {
        locationManager.requestWhenInUseAuthorization()
    }

    @available(iOS 14.0, *)
    public func amapLocationManager(
        _ manager: AMapLocationManager,
        locationManagerDidChangeAuthorization locationManager: CLLocationManager
    ) {
        emit("lynxMapLocationAuthorization", payload: [
            "status": Self.authorizationName(locationManager.authorizationStatus),
            "accuracy": locationManager.accuracyAuthorization == .fullAccuracy ? "full" : "reduced",
        ])
    }

    // MARK: - Request lifecycle

    private func requestCurrentLocation(
        optionsJSON: String,
        completion: @escaping (NSDictionary) -> Void
    ) {
        do {
            let options = try LocationOptions.parse(optionsJSON)
            try requireLocationReady()
            let manager = configuredManager(options)
            requestGeneration &+= 1
            let generation = requestGeneration
            finishPending(with: LocationError.cancelled)
            pendingCompletion = completion
            let accepted = manager.requestLocation(
                withReGeocode: options.withReGeocode
            ) { [weak self] location, reGeocode, error in
                self?.onMain { [weak self] in
                    guard let self, self.requestGeneration == generation, !self.destroyed else {
                        return
                    }
                    if let error {
                        self.finishPending(with: error)
                    } else if let location {
                        self.finishPending(
                            with: nil,
                            data: self.locationData(location, reGeocode: reGeocode)
                        )
                    } else {
                        self.finishPending(with: LocationError.requestRejected)
                    }
                }
            }
            if !accepted {
                finishPending(with: LocationError.requestRejected)
            }
        } catch {
            completion(Self.result(code: Self.code(for: error), message: error.localizedDescription))
        }
    }

    private func requireLocationReady() throws {
        guard LynxMapModuleRuntime.isAMapPrivacyAgreed() else {
            throw LocationError.privacyNotConfigured
        }
        guard CLLocationManager.locationServicesEnabled() else {
            throw LocationError.servicesDisabled
        }
        let status = CLLocationManager().authorizationStatus
        guard status != .denied, status != .restricted else {
            throw LocationError.authorizationDenied
        }
    }

    private func configuredManager(_ options: LocationOptions) -> AMapLocationManager {
        let manager = locationManager ?? AMapLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = options.desiredAccuracy
        manager.distanceFilter = options.distanceFilter
        manager.locationTimeout = options.locationTimeout
        manager.reGeocodeTimeout = options.reGeocodeTimeout
        manager.locatingWithReGeocode = options.withReGeocode
        locationManager = manager
        return manager
    }

    private func finishPending(
        with error: Error?,
        data: [String: Any] = [:]
    ) {
        guard let completion = pendingCompletion else { return }
        pendingCompletion = nil
        if let error {
            completion(Self.result(code: Self.code(for: error), message: error.localizedDescription))
        } else {
            completion(Self.result(code: 0, message: "定位成功", data: data))
        }
    }

    private func locationData(
        _ location: CLLocation,
        reGeocode: AMapLocationReGeocode?
    ) -> [String: Any] {
        var data: [String: Any] = [
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "timestamp": location.timestamp.timeIntervalSince1970 * 1000,
        ]
        if location.horizontalAccuracy >= 0 && location.horizontalAccuracy.isFinite {
            data["accuracy"] = location.horizontalAccuracy
        }
        if location.verticalAccuracy >= 0 && location.verticalAccuracy.isFinite {
            data["altitude"] = location.altitude
        }
        if location.speed >= 0 && location.speed.isFinite {
            data["speed"] = location.speed
        }
        if location.course >= 0 && location.course.isFinite {
            data["course"] = location.course
        }
        if let reGeocode, !reGeocode.formattedAddress.isEmpty {
            data["reGeocode"] = ["formattedAddress": reGeocode.formattedAddress]
        }
        return data
    }

    private func emitLocation(_ location: CLLocation, reGeocode: AMapLocationReGeocode?) {
        emit("lynxMapLocation", payload: locationData(location, reGeocode: reGeocode))
    }

    private func emit(_ eventName: String, payload: [String: Any]) {
        guard let view = lynxContext?.getLynxView() else { return }
        if Thread.isMainThread {
            view.sendGlobalEvent(eventName, withParams: [payload])
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.lynxContext?.getLynxView()?.sendGlobalEvent(eventName, withParams: [payload])
            }
        }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private static func authorizationName(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "authorizedAlways"
        case .authorizedWhenInUse: return "authorizedWhenInUse"
        @unknown default: return "unknown"
        }
    }

    private static func code(for error: Error) -> Int {
        if let locationError = error as? LocationError {
            switch locationError {
            case .invalidOptions: return 1201
            case .privacyNotConfigured: return 1202
            case .servicesDisabled: return 1203
            case .authorizationDenied: return 1204
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
}
