package com.example.lynxcapacitormodule

import org.json.JSONArray
import org.json.JSONObject

/**
 * 三端共用的能力语义字段和错误分类。
 *
 * 这里不决定平台 API 是否可用，只把实现状态、平台差异和验证层级
 * 用稳定字段暴露给页面，避免页面解析自然语言 reason。
 */
object LynxCapabilitySemantics {
    const val CONTRACT_VERSION = "1.1"
    const val SOURCE_VERIFICATION = "verified"
    const val BUILD_VERIFICATION = "not_run"
    const val HOST_VERIFICATION = "not_integrated"
    const val DEVICE_VERIFICATION = "not_run"

    fun semanticState(state: String): String = when (state) {
        "implemented" -> "native"
        "native", "partial", "unsupported" -> state
        else -> "partial"
    }

    fun reasonCode(id: String, state: String): String {
        if (state == "native" || state == "implemented") return "NONE"
        return when (id) {
            "Biometrics" -> "PLATFORM_UNSUPPORTED"
            "Browser" -> "EXTERNAL_OWNER"
            "Keyboard" -> "PLATFORM_UNSUPPORTED"
            "PushNotifications", "BackgroundRunner" -> "HOST_PROVIDER_REQUIRED"
            "Haptics" -> "APPROXIMATE_IMPLEMENTATION"
            "Share" -> "SEMANTIC_VARIANT"
            "Filesystem", "CapacitorCookies" -> "SECURITY_SCOPE_RESTRICTED"
            "ScreenOrientation" -> "HOST_INTEGRATION_REQUIRED"
            "InAppBrowser", "FileViewer", "SplashScreen" -> "RUNTIME_CONTEXT_REQUIRED"
            "Camera", "Geolocation", "Motion", "ScreenReader", "Calendar", "LocalNotifications", "CapacitorBarcodeScanner" -> "DEVICE_FEATURE_REQUIRED"
            "FileTransfer", "CapacitorHttp" -> "SEMANTIC_VARIANT"
            else -> "RUNTIME_VERIFICATION_REQUIRED"
        }
    }

    fun reason(id: String, state: String): String = when (reasonCode(id, state)) {
        "NONE" -> "公共最小语义在源码中已实现。"
        "METHOD_GAP" -> "能力目录中仍有方法没有实现。"
        "PLATFORM_UNSUPPORTED" -> "当前平台没有可安全承诺的等价实现。"
        "SEMANTIC_VARIANT" -> "方法存在，但作用范围、结果或完成时机存在平台差异。"
        "APPROXIMATE_IMPLEMENTATION" -> "使用平台近似机制，不能承诺硬件或系统行为完全等价。"
        "EXTERNAL_OWNER" -> "动作由外部系统或第三方应用管理，宿主无法控制完整生命周期。"
        "HOST_INTEGRATION_REQUIRED" -> "需要宿主注册、窗口协议或生命周期转发。"
        "HOST_PROVIDER_REQUIRED" -> "需要宿主配置或厂商服务 Provider。"
        "RUNTIME_CONTEXT_REQUIRED" -> "需要有效 Activity、窗口或前台页面上下文。"
        "DEVICE_FEATURE_REQUIRED" -> "需要系统权限、设备硬件或系统服务，并且还需要运行验收。"
        "SECURITY_SCOPE_RESTRICTED" -> "目录、URI、Cookie 或其他安全边界限制了公共语义。"
        else -> "源码分支存在，但还没有完整运行证据。"
    }

    fun methodReasonCode(id: String, method: String, implemented: Boolean): String {
        if (implemented) return "NONE"
        return when {
            id == "Browser" && method == "close" -> "EXTERNAL_OWNER"
            id == "Keyboard" && method == "setStyle" -> "PLATFORM_UNSUPPORTED"
            id == "PushNotifications" && method == "register" -> "HOST_PROVIDER_REQUIRED"
            id == "BackgroundRunner" && method == "dispatchEvent" -> "HOST_PROVIDER_REQUIRED"
            id == "Biometrics" -> "PLATFORM_UNSUPPORTED"
            else -> "METHOD_GAP"
        }
    }

    fun methodStatus(id: String, methods: List<String>, implementedMethods: List<String>): JSONArray = JSONArray().apply {
        methods.forEach { method ->
            val implemented = method in implementedMethods
            put(JSONObject()
                .put("name", method)
                .put("state", if (implemented) "native" else "unsupported")
                .put("reasonCode", methodReasonCode(id, method, implemented)))
        }
    }

    fun verification(): JSONObject = JSONObject()
        .put("source", SOURCE_VERIFICATION)
        .put("build", BUILD_VERIFICATION)
        .put("host", HOST_VERIFICATION)
        .put("device", DEVICE_VERIFICATION)

    fun errorReasonCode(code: String): String = when (code) {
        "INVALID_PAYLOAD" -> "INVALID_PAYLOAD"
        "INVALID_ARGUMENT" -> "INVALID_ARGUMENT"
        "UNIMPLEMENTED" -> "METHOD_GAP"
        "UNSUPPORTED" -> "PLATFORM_UNSUPPORTED"
        "PERMISSION_NOT_DECLARED" -> "HOST_PERMISSION_CONFIGURATION_REQUIRED"
        "PERMISSION_DENIED" -> "RUNTIME_PERMISSION_DENIED"
        "MODULE_UNAVAILABLE", "SCENE_UNAVAILABLE", "HOST_UNAVAILABLE" -> "RUNTIME_CONTEXT_REQUIRED"
        "CANCELLED" -> "CANCELLED"
        "ACTIVITY_DESTROYED", "HOST_DESTROYED" -> "HOST_DESTROYED"
        else -> "NATIVE_ERROR"
    }
}
