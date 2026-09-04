package com.example.lynxcapacitormodule

/** 自有 Module 的能力目录；只描述协议，不依赖 Capacitor 的类或注册表。 */
data class NativeCapabilitySpec(
    val id: String,
    val methods: List<String>,
    val implementedMethods: List<String>,
    val stateOverride: String? = null,
) {
    val state: String = stateOverride ?: when {
        implementedMethods.isEmpty() -> "unsupported"
        implementedMethods.size == methods.size -> "native"
        else -> "partial"
    }
}

object NativeCapabilityCatalog {
    private fun spec(id: String, methods: String, implemented: String = "", state: String? = null) = NativeCapabilitySpec(
        id = id,
        methods = methods.split(',').filter(String::isNotBlank),
        implementedMethods = implemented.split(',').filter(String::isNotBlank),
        stateOverride = state,
    )

    val specs: List<NativeCapabilitySpec> = listOf(
        spec("Device", "getInfo,getId,getBatteryInfo,getLanguageCode,getLanguageTag", "getInfo,getId,getBatteryInfo,getLanguageCode,getLanguageTag"),
        spec("Biometrics", "isAvailable,getBiometryType,authenticate", "", "unsupported"),
        spec("App", "getInfo,getState,getLaunchUrl", "getInfo,getState,getLaunchUrl"),
        spec("AppLauncher", "canOpenUrl,openUrl", "canOpenUrl,openUrl"),
        spec("Contacts", "checkPermissions,requestPermissions,save,find,remove", "checkPermissions,requestPermissions,save,find,remove"),
        spec("Preferences", "set,get,keys,remove", "set,get,keys,remove"),
        spec("Dialog", "alert,confirm,prompt", "alert,confirm,prompt"),
        spec("ActionSheet", "showActions", "showActions"),
        spec("Toast", "show,getCapabilities,cancel", "show,getCapabilities,cancel"),
        spec("Haptics", "impact,notification,selection,vibrate,vibrateLong,vibrateWaveform,vibratePredefined,vibrateComposition,getCapabilities,cancel", "impact,notification,selection,vibrate,vibrateLong,vibrateWaveform,vibratePredefined,vibrateComposition,getCapabilities,cancel"),
        spec("Share", "canShare,share", "canShare,share", "partial"),
        spec("Clipboard", "write,read", "write,read"),
        spec("Filesystem", "writeFile,readFile,readdir,stat,mkdir,getUri", "writeFile,readFile,readdir,stat,mkdir,getUri", "partial"),
        spec("Camera", "checkPermissions,requestPermissions,getPhoto,pickImages,chooseFromGallery,takePhoto,recordVideo,playVideo", "checkPermissions,requestPermissions,getPhoto,pickImages,chooseFromGallery,takePhoto,recordVideo,playVideo", "partial"),
        spec("Audio", "checkPermissions,requestPermissions,record,stopRecording,play,stopPlayback,getState", "checkPermissions,requestPermissions,record,stopRecording,play,stopPlayback,getState"),
        spec("FileTransfer", "downloadFile,getStatus,cancel", "downloadFile,getStatus,cancel", "partial"),
        spec("FileViewer", "openDocumentFromLocalPath", "openDocumentFromLocalPath", "partial"),
        spec("Network", "getStatus", "getStatus", "partial"),
        spec("CapacitorHttp", "request,get,post", "request,get,post", "partial"),
        spec("CapacitorCookies", "setCookie,getCookies,clearAllCookies", "setCookie,getCookies,clearAllCookies", "partial"),
        spec("Browser", "open,close", "open", "partial"),
        spec("InAppBrowser", "openInWebView,close", "openInWebView,close", "partial"),
        spec("Geolocation", "checkPermissions,requestPermissions,getCurrentPosition", "checkPermissions,requestPermissions,getCurrentPosition", "partial"),
        spec("Motion", "addListener,removeListener,removeAllListeners,start,stop", "addListener,removeListener,removeAllListeners,start,stop", "partial"),
        spec("StatusBar", "getInfo,setStyle,hide,show", "getInfo,setStyle,hide,show"),
        spec("SystemBars", "setStyle", "setStyle"),
        spec("ScreenOrientation", "orientation,lock,unlock", "orientation,lock,unlock", "partial"),
        spec("ScreenReader", "isEnabled,speak", "isEnabled,speak", "partial"),
        spec("TextZoom", "getPreferred,get,set", "getPreferred,get,set", "native"),
        spec("Keyboard", "getResizeMode,setStyle,hide", "getResizeMode,hide", "partial"),
        spec("SplashScreen", "hide,show", "hide,show", "native"),
        spec("PrivacyScreen", "isEnabled,enable,disable", "isEnabled,enable,disable"),
        spec("Calendar", "createCalendar,createEvent,findEvents,deleteEvent,deleteCalendar,checkPermissions,requestPermissions,listCalendars", "createCalendar,createEvent,findEvents,deleteEvent,deleteCalendar,checkPermissions,requestPermissions,listCalendars", "partial"),
        spec("LocalNotifications", "checkPermissions,requestPermissions,schedule,getPending,cancel,getDeliveredNotifications,createChannel,listChannels", "checkPermissions,requestPermissions,schedule,getPending,cancel,getDeliveredNotifications,createChannel,listChannels", "partial"),
        spec("PushNotifications", "checkPermissions,requestPermissions,register", "checkPermissions,requestPermissions"),
        spec("CapacitorBarcodeScanner", "scanBarcode", "scanBarcode", "partial"),
        spec("BackgroundRunner", "checkPermissions,requestPermissions,dispatchEvent", "checkPermissions,requestPermissions", "partial"),
        spec("KeepAwake", "isSupported,isKeptAwake,keepAwake,allowSleep", "isSupported,isKeptAwake,keepAwake,allowSleep"),
        spec("SafeArea", "setSystemBarsStyle,hideSystemBars,showSystemBars", "setSystemBarsStyle,hideSystemBars,showSystemBars"),
        spec("CapacitorSQLite", "echo,createConnection,open,execute,run,query,close,isAvailable", "echo,createConnection,open,execute,run,query,close,isAvailable"),
    )

    fun find(id: String): NativeCapabilitySpec? = specs.firstOrNull { it.id == id }
}
