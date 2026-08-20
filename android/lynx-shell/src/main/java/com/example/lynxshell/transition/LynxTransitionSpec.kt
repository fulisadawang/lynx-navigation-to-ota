package com.example.lynxshell.transition

import org.json.JSONArray
import org.json.JSONObject

/**
 * Android 真实 Activity 切换还包含 Window 首帧交接；300ms 在部分厂商系统上只剩下
 * 很短的可见区间。默认值只影响未显式传 duration 的便捷预设，业务显式配置仍优先。
 */
private const val DEFAULT_ANDROID_TRANSITION_DURATION_MS = 420L

/**
 * 目标 LynxView 首屏、目标 Window 首帧和原生快照需要在同一个门禁内收口。
 * 350ms 在真机繁忙或抓帧时会让 shared/open-container 误降级为 target_not_ready。
 */
private const val DEFAULT_ANDROID_READY_TIMEOUT_MS = 1_000L

/** 原生转场类型；wireName 与 Lynx 页面侧冻结协议保持一致。 */
enum class LynxTransitionStyle(val wireName: String) {
    DEFAULT("default"),
    FADE("fade"),
    SLIDE("slide"),
    SLIDE_UP("slideUp"),
    ZOOM("zoom"),
    SHARED_ELEMENT("sharedElement"),
    OPEN_CONTAINER("openContainer"),
    NONE("none");

    companion object {
        fun fromWireName(value: String): LynxTransitionStyle =
            entries.firstOrNull { it.wireName.equals(value, ignoreCase = true) }
                ?: throw IllegalArgumentException(
                    "transition.style 只支持 ${entries.joinToString { it.wireName }}",
                )
    }
}

/**
 * Skyline preset-route 的官方预设与壳扩展 heroSheet。
 *
 * 这里保留独立身份，绝不能只映射成 slide/zoom 后丢失语义；真正的 renderer 会按该
 * 枚举选择不同的布局、遮罩、圆角和反向动画。
 */
enum class LynxRoutePreset(val wireName: String) {
    BOTTOM_SHEET("wx://bottom-sheet"),
    HERO_SHEET("wx://hero-sheet"),
    UPWARDS("wx://upwards"),
    ZOOM("wx://zoom"),
    CUPERTINO_MODAL("wx://cupertino-modal"),
    CUPERTINO_MODAL_INSIDE("wx://cupertino-modal-inside"),
    MODAL_NAVIGATION("wx://modal-navigation"),
    MODAL("wx://modal");

    companion object {
        fun fromWireName(value: String): LynxRoutePreset =
            entries.firstOrNull { it.wireName == value }
                ?: throw IllegalArgumentException("不支持的 routeType: $value")
    }

    val isSheet: Boolean
        get() = this == BOTTOM_SHEET || this == HERO_SHEET
}

/** 共享元素或容器的矩形外观；单位均为 Android 逻辑像素。 */
data class LynxRectStyle(
    val backgroundColor: String? = null,
    val cornerRadius: Float? = null,
    val elevation: Float? = null,
)

enum class LynxSharedElementShuttle(val wireName: String) {
    FROM("from"),
    TO("to");

    companion object {
        fun fromWireName(value: String): LynxSharedElementShuttle =
            entries.firstOrNull { it.wireName.equals(value, ignoreCase = true) }
                ?: throw IllegalArgumentException("shuttle 只支持 from 或 to")
    }
}

/**
 * 共享元素矩形轨迹。
 *
 * Module-only 架构不会让 JS 在每一帧回调；这些曲线全部由原生 ValueAnimator 计算。
 */
sealed class LynxRectTweenSpec(val wireName: String) {
    data object Linear : LynxRectTweenSpec("linear")
    data object MaterialRectArc : LynxRectTweenSpec("materialRectArc")
    data object MaterialRectCenterArc : LynxRectTweenSpec("materialRectCenterArc")
    data object ElasticIn : LynxRectTweenSpec("elasticIn")
    data object ElasticOut : LynxRectTweenSpec("elasticOut")
    data object ElasticInOut : LynxRectTweenSpec("elasticInOut")
    data object BounceIn : LynxRectTweenSpec("bounceIn")
    data object BounceOut : LynxRectTweenSpec("bounceOut")
    data object BounceInOut : LynxRectTweenSpec("bounceInOut")
    data class CubicBezier(
        val x1: Float,
        val y1: Float,
        val x2: Float,
        val y2: Float,
    ) : LynxRectTweenSpec("cubic-bezier($x1,$y1,$x2,$y2)")

    companion object {
        private val cubicPattern = Regex(
            """^cubic-bezier\(\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*\)$""",
            RegexOption.IGNORE_CASE,
        )

        fun fromWireName(value: String): LynxRectTweenSpec {
            return when (value.trim().lowercase()) {
                "linear" -> Linear
                "materialrectarc" -> MaterialRectArc
                "materialrectcenterarc" -> MaterialRectCenterArc
                "elasticin" -> ElasticIn
                "elasticout" -> ElasticOut
                "elasticinout" -> ElasticInOut
                "bouncein" -> BounceIn
                "bounceout" -> BounceOut
                "bounceinout" -> BounceInOut
                else -> {
                    val match = cubicPattern.matchEntire(value.trim())
                        ?: throw IllegalArgumentException(
                            "rectTweenType 不受支持: $value",
                        )
                    val values = match.groupValues.drop(1).map(String::toFloat)
                    require(values[0] in 0f..1f && values[2] in 0f..1f) {
                        "cubic-bezier 的 x1、x2 必须在 0..1"
                    }
                    require(values[1] in -4f..4f && values[3] in -4f..4f) {
                        "cubic-bezier 的 y1、y2 必须在 -4..4"
                    }
                    CubicBezier(values[0], values[1], values[2], values[3])
                }
            }
        }
    }
}

/** 源页和目标页只交换 selector，不接受 JS 传入屏幕坐标。 */
data class LynxSharedElementSpec(
    val key: String,
    val sourceSelector: String,
    val targetSelector: String,
    /** Skyline 底层默认 false；便捷 helper 可以显式传 true。 */
    val transitionOnGesture: Boolean = false,
    val shuttleOnPush: LynxSharedElementShuttle = LynxSharedElementShuttle.TO,
    val shuttleOnPop: LynxSharedElementShuttle = LynxSharedElementShuttle.TO,
    val rectTween: LynxRectTweenSpec = LynxRectTweenSpec.MaterialRectArc,
    val sourceStyle: LynxRectStyle = LynxRectStyle(),
    val targetStyle: LynxRectStyle = LynxRectStyle(),
)

enum class LynxContainerContentTransition(val wireName: String) {
    FADE("fade"),
    FADE_THROUGH("fadeThrough");

    companion object {
        fun fromWireName(value: String): LynxContainerContentTransition =
            entries.firstOrNull { it.wireName.equals(value, ignoreCase = true) }
                ?: throw IllegalArgumentException(
                    "transitionType/contentTransition 只支持 fade 或 fadeThrough",
                )
    }
}

/** open-container 的关闭态来自源卡片，打开态为目标 Lynx 页面完整可见区域。 */
data class LynxOpenContainerSpec(
    val sourceSelector: String,
    /** 微信公开默认值：white / 0 / 300ms / fade。 */
    val closedColor: String = "white",
    val middleColor: String? = null,
    val openColor: String = "white",
    val closedCornerRadius: Float = 0f,
    val openCornerRadius: Float = 0f,
    val closedElevation: Float = 0f,
    val openElevation: Float = 0f,
    val transitionType: LynxContainerContentTransition =
        LynxContainerContentTransition.FADE,
    val transitionDurationMs: Long = 300L,
) {
    /** 兼容旧 Android 调用点；新 wire 字段统一使用 transitionType。 */
    val contentTransition: LynxContainerContentTransition get() = transitionType
}

enum class LynxPopGestureDirection(val wireName: String) {
    HORIZONTAL("horizontal"),
    VERTICAL("vertical"),
    MULTI("multi");

    companion object {
        fun fromWireName(value: String): LynxPopGestureDirection =
            entries.firstOrNull { it.wireName.equals(value, ignoreCase = true) }
                ?: throw IllegalArgumentException(
                    "popGesture.direction 只支持 horizontal、vertical 或 multi",
                )
    }
}

data class LynxPopGestureSpec(
    val enabled: Boolean = true,
    val direction: LynxPopGestureDirection = LynxPopGestureDirection.HORIZONTAL,
    val fullScreen: Boolean = false,
    val edgeWidth: Float = 28f,
)

/** Skyline preset-route 的页面级配置。未提供时由原生 renderer 使用稳定默认值。 */
data class LynxRouteConfig(
    val opaque: Boolean = true,
    val maintainState: Boolean = true,
    val barrierColor: String = "#66000000",
    val barrierDismissible: Boolean = false,
    val barrierLabel: String? = null,
    val canTransitionTo: Boolean = true,
    val canTransitionFrom: Boolean = true,
    val allowEnterRouteSnapshotting: Boolean = true,
    val allowExitRouteSnapshotting: Boolean = true,
    val fullscreenDrag: Boolean = false,
    val popGestureDirection: LynxPopGestureDirection =
        LynxPopGestureDirection.HORIZONTAL,
    val transitionDurationMs: Long? = null,
    val reverseTransitionDurationMs: Long? = null,
)

/** 当前 Skyline bottom-sheet 暴露的动态参数；height 单位为 vh。 */
data class LynxRouteOptions(
    val round: Boolean = true,
    val heightVh: Float = LynxBottomSheetMotion.DEFAULT_HEIGHT_VH,
    val detentsVh: List<Float> = listOf(LynxBottomSheetMotion.DEFAULT_HEIGHT_VH),
    val initialDetentVh: Float = LynxBottomSheetMotion.DEFAULT_HEIGHT_VH,
    val initialDetentIndex: Int = 0,
) {
    val isMultiDetent: Boolean get() = detentsVh.size > 1

    companion object {
        fun forPreset(routePreset: LynxRoutePreset?): LynxRouteOptions =
            if (routePreset == LynxRoutePreset.HERO_SHEET) {
                LynxRouteOptions(
                    heightVh = LynxHeroSheetMotion.DEFAULT_INITIAL_DETENT_VH,
                    detentsVh = LynxHeroSheetMotion.DEFAULT_DETENTS_VH,
                    initialDetentVh = LynxHeroSheetMotion.DEFAULT_INITIAL_DETENT_VH,
                    initialDetentIndex = LynxHeroSheetMotion.nearestDetentIndex(
                        LynxHeroSheetMotion.DEFAULT_INITIAL_DETENT_VH,
                        LynxHeroSheetMotion.DEFAULT_DETENTS_VH,
                    ),
                )
            } else {
                LynxRouteOptions()
            }
    }
}

/**
 * Android 端冻结后的完整转场配置。
 *
 * [explicitlyRequested] 是关键隔离线：只有既未传 transition 也未传 routeType 的旧页面，
 * 才允许继续使用系统 Window 动画。其余请求全部由内容层 renderer 绘制。
 */
data class LynxTransitionSpec(
    val style: LynxTransitionStyle = LynxTransitionStyle.DEFAULT,
    val fallbackStyle: LynxTransitionStyle = LynxTransitionStyle.FADE,
    val durationMs: Long = DEFAULT_ANDROID_TRANSITION_DURATION_MS,
    val reverseDurationMs: Long = DEFAULT_ANDROID_TRANSITION_DURATION_MS,
    val readyTimeoutMs: Long = DEFAULT_ANDROID_READY_TIMEOUT_MS,
    val sharedElements: List<LynxSharedElementSpec> = emptyList(),
    val openContainer: LynxOpenContainerSpec? = null,
    val popGesture: LynxPopGestureSpec = LynxPopGestureSpec(),
    val routePreset: LynxRoutePreset? = null,
    val routeConfig: LynxRouteConfig = LynxRouteConfig(),
    val routeOptions: LynxRouteOptions = LynxRouteOptions(),
    val explicitlyRequested: Boolean = false,
) {
    /** 旧单元素读取接口继续可用，wire 输入则由 parser 统一转成 sharedElements。 */
    val sharedElement: LynxSharedElementSpec? get() = sharedElements.firstOrNull()
    val routeType: String? get() = routePreset?.wireName
    val presetFallbackReason: String? get() = null

    companion object {
        private const val MAX_DURATION_MS = 5_000L
        private const val MIN_READY_TIMEOUT_MS = 80L
        private const val MAX_READY_TIMEOUT_MS = 1_500L
        private const val MAX_SHARED_ELEMENTS = 8

        fun fromOptions(options: JSONObject, animated: Boolean): LynxTransitionSpec {
            val routePreset = options.optionalString("routeType")
                ?.let(LynxRoutePreset::fromWireName)
            val transition = options.optionalObject("transition")
            val transparent = options.optBoolean("transparent", false)
            // animated=false 也是调用方明确要求“无动画”，必须进入 Runtime 的双重
            // Window suppress 通道，不能因为没写 transition 而落回系统默认 Window 动画。
            val explicitlyRequested =
                routePreset != null || transition != null || transparent || !animated
            val routeConfigValue = options.optionalObject("routeConfig")
            var routeConfig = routeConfigValue?.let(::parseRouteConfig)
                ?: LynxRouteConfig()
            if (routePreset?.isSheet == true || transparent) {
                routeConfig = routeConfig.copy(
                    opaque = if (routeConfigValue?.has("opaque") == true) {
                        if (transparent || routePreset == LynxRoutePreset.HERO_SHEET) {
                            false
                        } else {
                            routeConfig.opaque
                        }
                    } else {
                        false
                    },
                    barrierDismissible = if (
                        routeConfigValue?.has("barrierDismissible") == true
                    ) {
                        routeConfig.barrierDismissible
                    } else {
                        true
                    },
                )
            }
            val routeOptions = options.optionalObject("routeOptions")
                ?.let { parseRouteOptions(it, routePreset) }
                ?: LynxRouteOptions.forPreset(routePreset)

            val requestedStyle = transition?.optionalString("style")
                ?.let(LynxTransitionStyle::fromWireName)
                ?: routePreset?.let(::styleForPreset)
                ?: LynxTransitionStyle.DEFAULT
            val fallbackStyle = transition?.optionalString("fallbackStyle")
                ?.let(LynxTransitionStyle::fromWireName)
                ?: LynxTransitionStyle.FADE
            require(
                fallbackStyle == LynxTransitionStyle.FADE ||
                    fallbackStyle == LynxTransitionStyle.SLIDE ||
                    fallbackStyle == LynxTransitionStyle.NONE,
            ) { "fallbackStyle 只支持 fade、slide 或 none" }

            val openContainer = transition?.optionalObject("openContainer")
                ?.let(::parseOpenContainer)
            val defaultTransitionDuration = if (routePreset?.isSheet == true) {
                LynxBottomSheetMotion.DEFAULT_DURATION_MS
            } else {
                DEFAULT_ANDROID_TRANSITION_DURATION_MS
            }
            val transitionDuration = transition?.optionalLong("durationMs")
                ?: openContainer?.transitionDurationMs
                ?: defaultTransitionDuration
            val duration = routeConfig.transitionDurationMs ?: transitionDuration
            requireDuration(duration, "transitionDuration/durationMs")
            val reverseDuration = routeConfig.reverseTransitionDurationMs ?: duration
            requireDuration(reverseDuration, "reverseTransitionDuration")

            val readyTimeout = transition?.optionalLong("readyTimeoutMs")
                ?: DEFAULT_ANDROID_READY_TIMEOUT_MS
            require(readyTimeout in MIN_READY_TIMEOUT_MS..MAX_READY_TIMEOUT_MS) {
                "readyTimeoutMs 必须在 $MIN_READY_TIMEOUT_MS..$MAX_READY_TIMEOUT_MS 之间"
            }

            val sharedElements = parseSharedElements(transition)
            val popGestureValue = transition?.optionalObject("popGesture")
            var popGesture = popGestureValue?.let(::parsePopGesture)
                ?: LynxPopGestureSpec()
            if (
                routePreset?.isSheet == true &&
                popGestureValue?.has("direction") != true &&
                routeConfigValue?.has("popGestureDirection") != true
            ) {
                // bottom-sheet 的自然返回是向下拖拽；调用方仍可显式改成 multi/horizontal。
                popGesture = popGesture.copy(direction = LynxPopGestureDirection.VERTICAL)
            }
            if (
                routePreset?.isSheet == true &&
                popGestureValue?.has("fullScreen") != true &&
                routeConfigValue?.has("fullscreenDrag") != true
            ) {
                // 半屏卡片顶边不在 Window 顶边；默认允许从卡片内部向下拖，显式
                // fullscreenDrag=false 仍可关闭该行为。
                popGesture = popGesture.copy(fullScreen = true)
            }
            if (routeConfigValue?.has("popGestureDirection") == true) {
                popGesture = popGesture.copy(
                    direction = routeConfig.popGestureDirection,
                )
            }
            if (routeConfigValue?.has("fullscreenDrag") == true) {
                popGesture = popGesture.copy(
                    fullScreen = routeConfig.fullscreenDrag,
                )
            }

            if (requestedStyle == LynxTransitionStyle.SHARED_ELEMENT) {
                require(sharedElements.isNotEmpty()) {
                    "sharedElement 转场必须提供 transition.sharedElement 或 sharedElements"
                }
            }
            if (requestedStyle == LynxTransitionStyle.OPEN_CONTAINER) {
                requireNotNull(openContainer) {
                    "openContainer 转场必须提供 transition.openContainer"
                }
            }

            return LynxTransitionSpec(
                style = requestedStyle,
                fallbackStyle = fallbackStyle,
                durationMs = duration,
                reverseDurationMs = reverseDuration,
                readyTimeoutMs = readyTimeout,
                sharedElements = sharedElements,
                openContainer = openContainer,
                popGesture = popGesture,
                routePreset = routePreset,
                routeConfig = routeConfig,
                routeOptions = routeOptions,
                explicitlyRequested = explicitlyRequested,
            )
        }

        private fun styleForPreset(routePreset: LynxRoutePreset): LynxTransitionStyle =
            when (routePreset) {
                LynxRoutePreset.BOTTOM_SHEET,
                LynxRoutePreset.UPWARDS,
                -> LynxTransitionStyle.SLIDE_UP
                LynxRoutePreset.HERO_SHEET -> LynxTransitionStyle.SLIDE_UP
                LynxRoutePreset.ZOOM -> LynxTransitionStyle.ZOOM
                LynxRoutePreset.CUPERTINO_MODAL,
                LynxRoutePreset.MODAL,
                -> LynxTransitionStyle.ZOOM
                LynxRoutePreset.CUPERTINO_MODAL_INSIDE,
                LynxRoutePreset.MODAL_NAVIGATION,
                -> LynxTransitionStyle.SLIDE
            }

        private fun parseSharedElements(transition: JSONObject?): List<LynxSharedElementSpec> {
            if (transition == null) return emptyList()
            val array = transition.optionalArray("sharedElements")
            val result = when {
                array != null -> buildList {
                    require(array.length() in 1..MAX_SHARED_ELEMENTS) {
                        "sharedElements 数量必须在 1..$MAX_SHARED_ELEMENTS"
                    }
                    repeat(array.length()) { index ->
                        val item = array.get(index)
                        require(item is JSONObject) {
                            "sharedElements[$index] 必须是 JSON Object"
                        }
                        add(parseSharedElement(item, "sharedElements[$index]"))
                    }
                }
                transition.optionalObject("sharedElement") != null ->
                    listOf(
                        parseSharedElement(
                            requireNotNull(transition.optionalObject("sharedElement")),
                            "sharedElement",
                        ),
                    )
                else -> emptyList()
            }
            require(result.map { it.key }.toSet().size == result.size) {
                "sharedElements.key 在一次转场中必须唯一"
            }
            return result
        }

        private fun parseSharedElement(
            value: JSONObject,
            path: String,
        ): LynxSharedElementSpec {
            val key = requireIdentifier(value.getString("key"), "$path.key")
            val source = requireSelector(value.getString("sourceSelector"), "$path.sourceSelector")
            val target = requireSelector(value.getString("targetSelector"), "$path.targetSelector")
            return LynxSharedElementSpec(
                key = key,
                sourceSelector = source,
                targetSelector = target,
                transitionOnGesture = value.optBoolean("transitionOnGesture", false),
                shuttleOnPush = value.optionalString("shuttleOnPush")
                    ?.let(LynxSharedElementShuttle::fromWireName)
                    ?: LynxSharedElementShuttle.TO,
                shuttleOnPop = value.optionalString("shuttleOnPop")
                    ?.let(LynxSharedElementShuttle::fromWireName)
                    ?: LynxSharedElementShuttle.TO,
                rectTween = value.optionalString("rectTweenType")
                    ?.let(LynxRectTweenSpec::fromWireName)
                    ?: LynxRectTweenSpec.MaterialRectArc,
                sourceStyle = value.optionalObject("sourceStyle")
                    ?.let(::parseRectStyle)
                    ?: LynxRectStyle(),
                targetStyle = value.optionalObject("targetStyle")
                    ?.let(::parseRectStyle)
                    ?: LynxRectStyle(),
            )
        }

        private fun parseOpenContainer(value: JSONObject): LynxOpenContainerSpec {
            val transitionType = value.optionalString("transitionType")
                ?: value.optionalString("contentTransition")
            val transitionDuration = value.optionalLong("transitionDuration") ?: 300L
            requireDuration(transitionDuration, "openContainer.transitionDuration")
            return LynxOpenContainerSpec(
                sourceSelector = requireSelector(
                    value.getString("sourceSelector"),
                    "openContainer.sourceSelector",
                ),
                closedColor = value.optionalColor("closedColor") ?: "white",
                middleColor = value.optionalColor("middleColor"),
                openColor = value.optionalColor("openColor") ?: "white",
                closedCornerRadius = value.optionalFloat("closedCornerRadius", 0f)
                    .checkedRange("closedCornerRadius", 0f, 256f),
                openCornerRadius = value.optionalFloat("openCornerRadius", 0f)
                    .checkedRange("openCornerRadius", 0f, 256f),
                closedElevation = value.optionalFloat("closedElevation", 0f)
                    .checkedRange("closedElevation", 0f, 64f),
                openElevation = value.optionalFloat("openElevation", 0f)
                    .checkedRange("openElevation", 0f, 64f),
                transitionType = transitionType
                    ?.let(LynxContainerContentTransition::fromWireName)
                    ?: LynxContainerContentTransition.FADE,
                transitionDurationMs = transitionDuration,
            )
        }

        private fun parsePopGesture(value: JSONObject): LynxPopGestureSpec {
            val edgeWidth = value.optionalFloat("edgeWidth", 28f)
            require(edgeWidth in 16f..72f) { "popGesture.edgeWidth 必须在 16..72 之间" }
            return LynxPopGestureSpec(
                enabled = value.optBoolean("enabled", true),
                direction = value.optionalString("direction")
                    ?.let(LynxPopGestureDirection::fromWireName)
                    ?: LynxPopGestureDirection.HORIZONTAL,
                fullScreen = value.optBoolean("fullScreen", false),
                edgeWidth = edgeWidth,
            )
        }

        private fun parseRouteConfig(value: JSONObject): LynxRouteConfig =
            LynxRouteConfig(
                opaque = value.optBoolean("opaque", true),
                maintainState = value.optBoolean("maintainState", true),
                barrierColor = value.optionalColor("barrierColor") ?: "#66000000",
                barrierDismissible = value.optBoolean("barrierDismissible", false),
                barrierLabel = value.optionalString("barrierLabel"),
                canTransitionTo = value.optBoolean("canTransitionTo", true),
                canTransitionFrom = value.optBoolean("canTransitionFrom", true),
                allowEnterRouteSnapshotting =
                    value.optBoolean("allowEnterRouteSnapshotting", true),
                allowExitRouteSnapshotting =
                    value.optBoolean("allowExitRouteSnapshotting", true),
                fullscreenDrag = value.optBoolean("fullscreenDrag", false),
                popGestureDirection = value.optionalString("popGestureDirection")
                    ?.let(LynxPopGestureDirection::fromWireName)
                    ?: LynxPopGestureDirection.HORIZONTAL,
                transitionDurationMs = value.optionalLong("transitionDuration")
                    ?.also { requireDuration(it, "routeConfig.transitionDuration") },
                reverseTransitionDurationMs = value.optionalLong("reverseTransitionDuration")
                    ?.also { requireDuration(it, "routeConfig.reverseTransitionDuration") },
            )

        private fun parseRouteOptions(
            value: JSONObject,
            routePreset: LynxRoutePreset?,
        ): LynxRouteOptions {
            val explicitHeight = value.optionalFloatOrNull("height")?.also {
                require(it > 0f && it <= 100f) {
                    "routeOptions.height 必须在 (0, 100](vh)"
                }
            }
            val rawDetents = value.optionalArray("detents")
            val usesHeroDefaults = routePreset == LynxRoutePreset.HERO_SHEET &&
                rawDetents == null && explicitHeight == null
            val detents = rawDetents?.let { array ->
                require(array.length() in 1..LynxHeroSheetMotion.MAX_DETENTS) {
                    "routeOptions.detents 数量必须在 1..${LynxHeroSheetMotion.MAX_DETENTS}"
                }
                (0 until array.length()).map { index ->
                    val detent = when (val raw = array.get(index)) {
                        is Number -> raw.toFloat()
                        is String -> raw.toFloatOrNull()
                        else -> null
                    } ?: throw IllegalArgumentException(
                        "routeOptions.detents[$index] 必须是数字",
                    )
                    require(detent > 0f && detent <= 100f) {
                        "routeOptions.detents[$index] 必须在 (0, 100](vh)"
                    }
                    detent
                }.also { values ->
                    require(values.zipWithNext().all { (left, right) -> left < right }) {
                        "routeOptions.detents 必须严格递增"
                    }
                }
            } ?: when {
                explicitHeight != null -> listOf(explicitHeight)
                routePreset == LynxRoutePreset.HERO_SHEET ->
                    LynxHeroSheetMotion.DEFAULT_DETENTS_VH
                else -> listOf(LynxBottomSheetMotion.DEFAULT_HEIGHT_VH)
            }
            if (routePreset == LynxRoutePreset.HERO_SHEET) {
                require(detents.size >= 2) {
                    "heroSheet 至少需要两个 detent"
                }
                require(kotlin.math.abs(detents.last() - 100f) < 0.0001f) {
                    "heroSheet 的最后一个 detent 必须是 100vh 全屏"
                }
            }
            val requestedInitial = value.optionalFloatOrNull("initialDetent")
                ?: explicitHeight
                ?: if (usesHeroDefaults) {
                    LynxHeroSheetMotion.DEFAULT_INITIAL_DETENT_VH
                } else {
                    detents.last()
                }
            val initialIndex = detents.indexOfFirst {
                kotlin.math.abs(it - requestedInitial) < 0.0001f
            }
            require(initialIndex >= 0) {
                "routeOptions.initialDetent 必须是 detents 中的一个值"
            }
            return LynxRouteOptions(
                round = value.optBoolean("round", true),
                heightVh = requestedInitial,
                detentsVh = detents,
                initialDetentVh = requestedInitial,
                initialDetentIndex = initialIndex,
            )
        }

        private fun parseRectStyle(value: JSONObject): LynxRectStyle =
            LynxRectStyle(
                backgroundColor = value.optionalColor("backgroundColor"),
                cornerRadius = value.optionalFloatOrNull("cornerRadius")
                    ?.checkedRange("cornerRadius", 0f, 256f),
                elevation = value.optionalFloatOrNull("elevation")
                    ?.checkedRange("elevation", 0f, 64f),
            )

        private fun requireDuration(value: Long, name: String) {
            require(value in 0L..MAX_DURATION_MS) {
                "$name 必须在 0..$MAX_DURATION_MS 之间"
            }
        }

        private fun requireSelector(value: String, name: String): String {
            val normalized = value.trim().removePrefix("#")
            require(normalized.isNotEmpty() && normalized.length <= 128) {
                "$name 去掉 # 后必须非空且不超过 128 个字符"
            }
            return normalized
        }

        private fun requireIdentifier(value: String, name: String): String {
            val normalized = value.trim()
            require(normalized.isNotEmpty() && normalized.length <= 128) {
                "$name 必须非空且不超过 128 个字符"
            }
            return normalized
        }

        private fun Float.checkedRange(name: String, min: Float, max: Float): Float {
            require(this in min..max) { "$name 必须在 $min..$max 之间" }
            return this
        }

        private fun JSONObject.optionalObject(key: String): JSONObject? {
            if (!has(key) || isNull(key)) return null
            return when (val value = get(key)) {
                is JSONObject -> value
                is String -> JSONObject(value)
                else -> throw IllegalArgumentException("$key 必须是 JSON Object")
            }
        }

        private fun JSONObject.optionalArray(key: String): JSONArray? {
            if (!has(key) || isNull(key)) return null
            return when (val value = get(key)) {
                is JSONArray -> value
                is String -> JSONArray(value)
                else -> throw IllegalArgumentException("$key 必须是 JSON Array")
            }
        }

        private fun JSONObject.optionalString(key: String): String? =
            if (!has(key) || isNull(key)) null else get(key).toString().trim().takeIf {
                it.isNotEmpty()
            }

        private fun JSONObject.optionalLong(key: String): Long? =
            if (!has(key) || isNull(key)) null else when (val value = get(key)) {
                is Number -> value.toLong()
                is String -> value.toLongOrNull()
                else -> null
            } ?: throw IllegalArgumentException("$key 必须是整数")

        private fun JSONObject.optionalFloatOrNull(key: String): Float? =
            if (!has(key) || isNull(key)) null else when (val value = get(key)) {
                is Number -> value.toFloat()
                is String -> value.toFloatOrNull()
                else -> null
            } ?: throw IllegalArgumentException("$key 必须是数字")

        private fun JSONObject.optionalFloat(key: String, fallback: Float): Float =
            optionalFloatOrNull(key) ?: fallback

        private fun JSONObject.optionalColor(key: String): String? =
            optionalString(key)?.also {
                require(LynxColorParser.isValid(it)) {
                    "$key 必须为 #RRGGBB、#RRGGBBAA、rgb()/rgba() 或标准颜色名"
                }
            }
    }
}
