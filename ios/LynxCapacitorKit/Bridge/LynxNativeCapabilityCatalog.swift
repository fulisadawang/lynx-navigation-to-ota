import Foundation

struct LynxNativeCapabilitySpec {
    let id: String
    let methods: [String]
    let implementedMethods: [String]
    let stateOverride: String?

    var state: String {
        if let stateOverride { return stateOverride }
        if implementedMethods.isEmpty { return "unsupported" }
        return implementedMethods.count == methods.count ? "native" : "partial"
    }

    /** 对外暴露的 canonical 语义状态，兼容旧的 state 字段。 */
    var semanticState: String { LynxCapabilitySemantics.semanticState(state) }
    var reasonCode: String { LynxCapabilitySemantics.reasonCode(for: id, state: state) }
    var reason: String { LynxCapabilitySemantics.reason(for: id, state: state) }
    var methodStatus: [[String: Any]] {
        LynxCapabilitySemantics.methodStatus(id: id, methods: methods, implementedMethods: implementedMethods)
    }
}

/** Android 当前 Module 的协议目录；iOS 必须沿用同一组 pluginId/methodName。 */
enum LynxNativeCapabilityCatalog {
    static let specs: [LynxNativeCapabilitySpec] = [
        spec("Device", "getInfo,getId,getBatteryInfo,getLanguageCode,getLanguageTag"),
        spec("Biometrics", "isAvailable,getBiometryType,authenticate"),
        spec("App", "getInfo,getState,getLaunchUrl"),
        spec("AppLauncher", "canOpenUrl,openUrl"),
        spec("Contacts", "checkPermissions,requestPermissions,save,find,remove"),
        spec("Preferences", "set,get,keys,remove"),
        spec("Dialog", "alert,confirm,prompt"),
        spec("ActionSheet", "showActions"),
        spec("Toast", "show,getCapabilities,cancel"),
        spec("Haptics", "impact,notification,selection,vibrate,vibrateLong,vibrateWaveform,vibratePredefined,vibrateComposition,getCapabilities,cancel", state: "partial"),
        spec("Share", "canShare,share"),
        spec("Clipboard", "write,read"),
        spec("Filesystem", "writeFile,readFile,readdir,stat,mkdir,getUri", state: "partial"),
        spec("Camera", "checkPermissions,requestPermissions,getPhoto,pickImages,chooseFromGallery,takePhoto,recordVideo,playVideo", state: "partial"),
        spec("Audio", "checkPermissions,requestPermissions,record,stopRecording,play,stopPlayback,getState"),
        spec("FileTransfer", "downloadFile,getStatus,cancel", state: "partial"),
        spec("FileViewer", "openDocumentFromLocalPath", state: "partial"),
        spec("Network", "getStatus", state: "partial"),
        spec("CapacitorHttp", "request,get,post", state: "partial"),
        spec("CapacitorCookies", "setCookie,getCookies,clearAllCookies", state: "partial"),
        spec("Browser", "open,close", implemented: "open", state: "partial"),
        spec("InAppBrowser", "openInWebView,close", state: "partial"),
        spec("Geolocation", "checkPermissions,requestPermissions,getCurrentPosition", state: "partial"),
        spec("Motion", "addListener,removeListener,removeAllListeners,start,stop", state: "partial"),
        spec("StatusBar", "getInfo,setStyle,hide,show"),
        spec("SystemBars", "setStyle"),
        spec("ScreenOrientation", "orientation,lock,unlock", state: "partial"),
        spec("ScreenReader", "isEnabled,speak", state: "partial"),
        spec("TextZoom", "getPreferred,get,set", implemented: "getPreferred,get", state: "partial"),
        spec("Keyboard", "getResizeMode,setStyle,hide", implemented: "getResizeMode,hide", state: "partial"),
        spec("SplashScreen", "hide,show"),
        spec("PrivacyScreen", "isEnabled,enable,disable", state: "partial"),
        spec("Calendar", "createCalendar,createEvent,findEvents,deleteEvent,deleteCalendar,checkPermissions,requestPermissions,listCalendars", state: "partial"),
        spec("LocalNotifications", "checkPermissions,requestPermissions,schedule,getPending,cancel,getDeliveredNotifications,createChannel,listChannels", implemented: "checkPermissions,requestPermissions,schedule,getPending,cancel,getDeliveredNotifications", state: "partial"),
        spec("PushNotifications", "checkPermissions,requestPermissions,register", implemented: "checkPermissions,requestPermissions"),
        spec("CapacitorBarcodeScanner", "scanBarcode"),
        spec("BackgroundRunner", "checkPermissions,requestPermissions,dispatchEvent", implemented: "checkPermissions,requestPermissions", state: "partial"),
        spec("KeepAwake", "isSupported,isKeptAwake,keepAwake,allowSleep"),
        spec("SafeArea", "setSystemBarsStyle,hideSystemBars,showSystemBars"),
        spec("CapacitorSQLite", "echo,createConnection,open,execute,run,query,close,isAvailable"),
    ]

    static func find(_ id: String) -> LynxNativeCapabilitySpec? {
        specs.first { $0.id == id }
    }

    static func headersJSON() -> String {
        let value = specs.map { spec in
            [
                "name": spec.id,
                "methods": spec.methods.map { ["name": $0, "rtype": "promise"] },
            ] as [String: Any]
        }
        return LynxNativeJSON.encode(value) ?? "[]"
    }

    static let hostRequirements: [String: [String]] = [
        "StatusBar": ["setStyle", "hide", "show"],
        "SystemBars": ["setStyle"],
        "SafeArea": ["setSystemBarsStyle", "hideSystemBars", "showSystemBars"],
        "ScreenOrientation": ["orientation", "lock", "unlock"],
        "Keyboard": ["setStyle"],
    ]

    static func statusJSON(platform: String = "ios", hostMethods: [String: [String]] = [:]) -> String {
        let value = specs.map { spec in
            let required = hostRequirements[spec.id] ?? []
            let provided = hostMethods[spec.id] ?? []
            let actual = spec.methods.filter { method in
                required.contains(method) ? provided.contains(method) : spec.implementedMethods.contains(method)
            }
            let usesHost = !required.isEmpty
            let configured = required.contains { provided.contains($0) }
            let state = usesHost ? (actual.isEmpty ? "unsupported" : "partial") : spec.state
            let methodStatus = spec.methods.map { method -> [String: Any] in
                let implemented = actual.contains(method)
                if required.contains(method) {
                    return ["name": method, "state": implemented ? "partial" : "unsupported",
                            "reasonCode": implemented ? "RUNTIME_CONTEXT_REQUIRED" : "HOST_PROVIDER_REQUIRED",
                            "hostConfigured": implemented,
                            "runtimeAvailability": implemented ? "checkRequired" : "unavailable"]
                }
                return ["name": method, "state": implemented ? "native" : "unsupported",
                        "reasonCode": LynxCapabilitySemantics.methodReasonCode(for: spec.id, method: method, implemented: implemented)]
            }
            var entry: [String: Any] = [
                "name": spec.id,
                "methods": spec.methods,
                "implementedMethods": actual,
                "state": state,
                "contractVersion": LynxCapabilitySemantics.contractVersion,
                "semanticState": LynxCapabilitySemantics.semanticState(state),
                "reasonCode": usesHost ? (configured ? "RUNTIME_CONTEXT_REQUIRED" : "HOST_PROVIDER_REQUIRED") : spec.reasonCode,
                "reason": usesHost ? (configured ? "宿主已配置；当前页面、窗口和执行状态在调用时检查。" : "当前宿主尚未安装该容器控制能力。") : spec.reason,
                "methodStatus": methodStatus,
                "verification": LynxCapabilitySemantics.verification(),
                "platform": platform,
            ]
            if usesHost {
                entry["hostConfigured"] = configured
                entry["runtimeAvailability"] = actual.isEmpty ? "unavailable" : "checkRequired"
            }
            if spec.id == "SystemBars" {
                entry["scope"] = "status_bar_only"
                if configured {
                    entry["reasonCode"] = "SEMANTIC_VARIANT"
                    entry["reason"] = "iOS 仅控制状态栏样式；Home Indicator 由系统管理，当前页面可用性在调用时检查。"
                }
            }
            return entry
        }
        return LynxNativeJSON.encode(value) ?? "[]"
    }

    private static func spec(
        _ id: String,
        _ methods: String,
        implemented: String? = nil,
        state: String? = nil
    ) -> LynxNativeCapabilitySpec {
        let all = methods.split(separator: ",").map(String.init)
        let implementedMethods = (implemented ?? methods).split(separator: ",").map(String.init)
        return LynxNativeCapabilitySpec(
            id: id,
            methods: all,
            implementedMethods: implementedMethods,
            stateOverride: state
        )
    }
}
