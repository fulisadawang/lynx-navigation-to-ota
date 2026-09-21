package com.example.lynxmap

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Point
import android.graphics.Typeface
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.MotionEvent
import com.amap.api.maps.AMap
import com.amap.api.maps.BaseMapView
import com.amap.api.maps.CameraUpdateFactory
import com.amap.api.maps.TextureMapView
import com.amap.api.maps.model.CameraPosition
import com.amap.api.maps.model.BitmapDescriptor
import com.amap.api.maps.model.BitmapDescriptorFactory
import com.amap.api.maps.model.LatLng
import com.amap.api.maps.model.LatLngBounds
import com.amap.api.maps.model.Marker
import com.amap.api.maps.model.MarkerOptions
import com.amap.api.maps.model.MultiPointItem
import com.amap.api.maps.model.MultiPointOverlay
import com.amap.api.maps.model.MultiPointOverlayOptions
import com.amap.api.maps.model.Polyline
import com.amap.api.maps.model.PolylineOptions
import com.lynx.react.bridge.Callback
import com.lynx.react.bridge.JavaOnlyArray
import com.lynx.react.bridge.JavaOnlyMap
import com.lynx.react.bridge.ReadableArray
import com.lynx.react.bridge.ReadableMap
import com.lynx.tasm.behavior.LynxContext
import com.lynx.tasm.behavior.LynxProp
import com.lynx.tasm.behavior.LynxUIMethod
import com.lynx.tasm.behavior.ui.LynxUI
import com.lynx.tasm.event.LynxCustomEvent
import java.net.HttpURLConnection
import java.net.URL
import java.util.Collections
import java.util.LinkedHashMap
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.roundToInt
import android.widget.FrameLayout

/** Android 原生 MapView 的 Lynx Element。 */
class LynxMapUI(context: LynxContext) : LynxUI<FrameLayout>(context) {
    private var map: AMap? = null
    private var mapView: TextureMapView? = null
    private val markers = LinkedHashMap<String, Marker>()
    private val polylines = LinkedHashMap<String, Polyline>()
    private var massPointOverlay: MultiPointOverlay? = null
    private var center = LatLng(DEFAULT_LATITUDE, DEFAULT_LONGITUDE)
    private var zoom = DEFAULT_ZOOM
    private var bearing = 0f
    private var pitch = 0f
    private var providerReady = false
    private var markerInput: ReadableArray? = null
    private var polylineInput: ReadableArray? = null
    private var massPointInput: ReadableArray? = null
    private var layerVisible = true
    private var layerOpacity = 1f
    private var layerZIndex = 0f
    private var mapTouchEnabled = true
    private var touchBlockTopRatio = 1f
    private var cameraChangeStarted = false
    private var cameraChangeSource = "gesture"
    private var applyCount = 0
    private var lastApplyDurationMs = 0.0
    private val mainHandler = Handler(Looper.getMainLooper())
    private val iconExecutor: ExecutorService = Executors.newFixedThreadPool(2)
    private val iconCache = Collections.synchronizedMap(object : LinkedHashMap<String, BitmapDescriptor>(32, .75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, BitmapDescriptor>?): Boolean = size > 32
    })
    private val pendingIconTasks = Collections.synchronizedMap(HashMap<String, java.util.concurrent.Future<*>>())

    override fun createView(context: Context): FrameLayout {
        val view = LynxTextureMapView(
            context = context,
            isTouchEnabled = { mapTouchEnabled },
            blockedTopRatio = { touchBlockTopRatio },
        )
        mapView = view
        view.onCreate(null)
        map = view.map.apply {
            uiSettings.isZoomControlsEnabled = false
            setOnMapLoadedListener {
                providerReady = LynxMapRuntime.isConfigured()
                if (providerReady) {
                    renderMarkers(markerInput)
                    renderPolylines(polylineInput)
                    renderMassPoints(massPointInput)
                    emit("ready", mapOf("provider" to "amap-android"))
                } else {
                    emit(
                        "error",
                        mapOf(
                            "code" to "MAP_PROVIDER_MISSING_API_KEY",
                            "message" to "Android 地图 provider 缺少 Key。",
                        ),
                    )
                }
            }
            setOnMapClickListener { coordinate ->
                emit(
                    "maptap",
                    mapOf("coordinate" to coordinateMap(coordinate.latitude, coordinate.longitude)),
                )
            }
            setOnMapLongClickListener { coordinate ->
                emit(
                    "longpress",
                    mapOf("coordinate" to coordinateMap(coordinate.latitude, coordinate.longitude)),
                )
            }
            setOnMarkerClickListener { marker ->
                val id = marker.getObject()?.toString() ?: marker.id
                updateMarkerSelection(id, true)
                emit(
                    "markertap",
                    mapOf(
                        "id" to id,
                        "coordinate" to coordinateMap(marker.position.latitude, marker.position.longitude),
                    ),
                )
                false
            }
            setOnMarkerDragListener(object : AMap.OnMarkerDragListener {
                override fun onMarkerDragStart(marker: Marker) = emitMarkerDrag(marker, "start")
                override fun onMarkerDrag(marker: Marker) = emitMarkerDrag(marker, "dragging")
                override fun onMarkerDragEnd(marker: Marker) = emitMarkerDrag(marker, "end")
            })
            setOnCameraChangeListener(object : AMap.OnCameraChangeListener {
                override fun onCameraChange(position: CameraPosition) {
                    if (!cameraChangeStarted) {
                        cameraChangeStarted = true
                        emitRegion(position, "begin")
                    }
                }

                override fun onCameraChangeFinish(position: CameraPosition) {
                    emitRegion(position, "end")
                    cameraChangeStarted = false
                    cameraChangeSource = "gesture"
                }
            })
            setOnMultiPointClickListener { item ->
                val id = item.customerId ?: item.getObject()?.toString() ?: ""
                emit("masspointtap", mapOf("id" to id, "coordinate" to coordinateMap(item.latLng.latitude, item.latLng.longitude)))
                true
            }
        }
        applyCamera(animated = false)
        if (!LynxMapRuntime.isConfigured()) {
            mainHandler.post { emit("error", mapOf("code" to "MAP_PROVIDER_MISSING_API_KEY", "message" to "Android 地图 provider 缺少 Key。")) }
        }
        return view
    }

    override fun onAttach() {
        super.onAttach()
        mapView?.onResume()
    }

    override fun onDetach() {
        mapView?.onPause()
        super.onDetach()
    }

    override fun onLayoutUpdated() {
        super.onLayoutUpdated()
        getView()?.post { getView()?.invalidate() }
    }

    override fun destroy() {
        markers.values.forEach { it.remove() }
        polylines.values.forEach { it.remove() }
        markers.clear()
        polylines.clear()
        massPointOverlay?.remove()
        massPointOverlay = null
        map?.clear()
        map = null
        pendingIconTasks.values.forEach { it.cancel(true) }
        pendingIconTasks.clear()
        iconExecutor.shutdownNow()
        iconCache.clear()
        mapView?.onDestroy()
        mapView = null
        super.destroy()
    }

    @LynxProp(name = "center")
    fun setCenter(value: ReadableMap?) {
        val latitude = value?.number("latitude") ?: return
        val longitude = value.number("longitude") ?: return
        if (!validCoordinate(latitude, longitude)) return
        center = LatLng(latitude, longitude)
        applyCamera(animated = false)
    }

    @LynxProp(name = "zoom")
    fun setZoom(value: Float) {
        zoom = value.coerceIn(0f, 24f)
        applyCamera(animated = false)
    }

    @LynxProp(name = "bearing")
    fun setBearing(value: Float) {
        bearing = value.coerceIn(0f, 360f)
        applyCamera(animated = false)
    }

    @LynxProp(name = "pitch")
    fun setPitch(value: Float) {
        pitch = value.coerceIn(0f, 60f)
        applyCamera(animated = false)
    }

    @LynxProp(name = "anchor")
    fun setAnchor(value: ReadableMap?) {
        val x = value?.number("x") ?: return
        val y = value.number("y") ?: return
        map?.setPointToCenter(((getView()?.width ?: 0) * x).roundToInt(), ((getView()?.height ?: 0) * y).roundToInt())
    }

    @LynxProp(name = "markers")
    fun setMarkers(value: ReadableArray?) {
        markerInput = value
        renderMarkers(value)
    }

    @LynxProp(name = "polylines")
    fun setPolylines(value: ReadableArray?) {
        polylineInput = value
        renderPolylines(value)
    }

    @LynxProp(name = "mass-points")
    fun setMassPoints(value: ReadableArray?) {
        massPointInput = value
        renderMassPoints(value)
    }

    @LynxProp(name = "layer-visible")
    fun setLayerVisible(value: Boolean) {
        layerVisible = value
        applyOverlayVisibility()
    }

    @LynxProp(name = "layer-opacity")
    fun setLayerOpacity(value: Float) {
        layerOpacity = value.coerceIn(0f, 1f)
        applyOverlayVisibility()
    }

    @LynxProp(name = "layer-z-index")
    fun setLayerZIndex(value: Float) {
        layerZIndex = value.coerceIn(-100000f, 100000f)
        applyOverlayVisibility()
    }

    @LynxProp(name = "map-type")
    fun setMapType(value: String?) {
        map?.mapType = when (value?.lowercase(Locale.ROOT)) {
            "satellite" -> AMap.MAP_TYPE_SATELLITE
            "night" -> AMap.MAP_TYPE_NIGHT
            "navi" -> AMap.MAP_TYPE_NAVI
            "bus" -> AMap.MAP_TYPE_BUS
            "navi-night" -> AMap.MAP_TYPE_NAVI_NIGHT
            else -> AMap.MAP_TYPE_NORMAL
        }
    }

    @LynxProp(name = "traffic-enabled")
    fun setTrafficEnabled(value: Boolean) {
        map?.isTrafficEnabled = value
    }

    @LynxProp(name = "zoom-enabled")
    fun setZoomEnabled(value: Boolean) {
        map?.uiSettings?.setZoomGesturesEnabled(value)
        updateMapTouchEnabled()
    }

    @LynxProp(name = "scroll-enabled")
    fun setScrollEnabled(value: Boolean) {
        map?.uiSettings?.setScrollGesturesEnabled(value)
        updateMapTouchEnabled()
    }

    @LynxProp(name = "rotate-enabled")
    fun setRotateEnabled(value: Boolean) {
        map?.uiSettings?.setRotateGesturesEnabled(value)
        updateMapTouchEnabled()
    }

    @LynxProp(name = "rotate-camera-enabled")
    fun setRotateCameraEnabled(value: Boolean) {
        map?.uiSettings?.setTiltGesturesEnabled(value)
        updateMapTouchEnabled()
    }

    @LynxProp(name = "shows-compass")
    fun setShowsCompass(value: Boolean) {
        map?.uiSettings?.setCompassEnabled(value)
    }

    @LynxProp(name = "shows-scale")
    fun setShowsScale(value: Boolean) {
        map?.uiSettings?.setScaleControlsEnabled(value)
    }

    @LynxProp(name = "shows-labels")
    fun setShowsLabels(value: Boolean) {
        map?.showMapText(value)
    }

    @LynxProp(name = "shows-buildings")
    fun setShowsBuildings(value: Boolean) {
        map?.showBuildings(value)
    }

    @LynxProp(name = "touch-poi-enabled")
    fun setTouchPoiEnabled(value: Boolean) {
        map?.setTouchPoiEnable(value)
    }

    /** Sheet 等 Lynx 覆盖层占据地图底部时，先在原生 View 分发阶段挡住这块区域。 */
    @LynxProp(name = "touch-block-top-ratio")
    fun setTouchBlockTopRatio(value: Float) {
        touchBlockTopRatio = value.coerceIn(0f, 1f)
    }

    private fun updateMapTouchEnabled() {
        val settings = map?.uiSettings ?: return
        mapTouchEnabled = settings.isZoomGesturesEnabled ||
            settings.isScrollGesturesEnabled ||
            settings.isRotateGesturesEnabled ||
            settings.isTiltGesturesEnabled
        if (!mapTouchEnabled) {
            mapView?.parent?.requestDisallowInterceptTouchEvent(false)
        }
    }

    @LynxUIMethod
    fun moveCamera(params: ReadableMap?, callback: Callback) {
        if (params == null) {
            callbackFailure(callback, LynxMapResult.invalid("moveCamera 参数不能为空"))
            return
        }
        params.map("center")?.let { value ->
            val lat = value.number("latitude")
            val lon = value.number("longitude")
            if (lat != null && lon != null && validCoordinate(lat, lon)) center = LatLng(lat, lon)
        }
        params.number("zoom")?.let { zoom = it.toFloat().coerceIn(0f, 24f) }
        params.number("bearing")?.let { bearing = it.toFloat().coerceIn(0f, 360f) }
        params.number("pitch")?.let { pitch = it.toFloat().coerceIn(0f, 60f) }
        val animated = params.boolean("animated") ?: true
        applyCamera(animated)
        callbackSuccess(callback, JavaOnlyMap().apply { putBoolean("accepted", true) })
    }

    @LynxUIMethod
    fun getCameraState(params: ReadableMap?, callback: Callback) {
        val position = map?.cameraPosition
        callbackSuccess(callback, JavaOnlyMap().apply {
            putMap("center", coordinateMap(position?.target?.latitude ?: center.latitude, position?.target?.longitude ?: center.longitude))
            putDouble("zoom", (position?.zoom ?: zoom).toDouble())
            putDouble("bearing", (position?.bearing ?: bearing).toDouble())
            putDouble("pitch", (position?.tilt ?: pitch).toDouble())
        })
    }

    @LynxUIMethod
    fun getCamera(params: ReadableMap?, callback: Callback) = getCameraState(params, callback)

    @LynxUIMethod
    fun projectCoordinate(params: ReadableMap?, callback: Callback) {
        val input = params?.map("coordinate") ?: params
        val latitude = input?.number("latitude")
        val longitude = input?.number("longitude")
        if (latitude == null || longitude == null || !validCoordinate(latitude, longitude)) {
            callbackFailure(callback, LynxMapResult.invalid("projectCoordinate.coordinate 参数无效"))
            return
        }
        val currentMap = map
        val view = getView()
        if (currentMap == null || view == null || !providerReady) {
            callbackFailure(callback, LynxMapResult.error(1002, "地图尚未 ready"))
            return
        }
        val point = currentMap.projection.toScreenLocation(LatLng(latitude, longitude))
        val visible = point.x in 0..view.width && point.y in 0..view.height
        callbackSuccess(callback, JavaOnlyMap().apply {
            putDouble("x", point.x.toDouble())
            putDouble("y", point.y.toDouble())
            putBoolean("visible", visible)
        })
    }

    @LynxUIMethod
    fun selectMarker(params: ReadableMap?, callback: Callback) = setMarkerSelection(params, callback, true)

    @LynxUIMethod
    fun deselectMarker(params: ReadableMap?, callback: Callback) = setMarkerSelection(params, callback, false)

    @LynxUIMethod
    fun showMarkers(params: ReadableMap?, callback: Callback) {
        val ids = params?.array("ids") ?: params?.array("identifiers")
        if (ids == null || ids.size() == 0 || ids.size() > MAX_MARKERS) {
            callbackFailure(callback, LynxMapResult.invalid("showMarkers.ids 必须是非空有界数组"))
            return
        }
        val bounds = LatLngBounds.Builder()
        var count = 0
        for (index in 0 until ids.size()) {
            val id = ids.getString(index)
            val marker = markers[id]
            if (marker == null) {
                callbackFailure(callback, LynxMapResult.invalid("showMarkers 包含不存在的 marker：$id"))
                return
            }
            bounds.include(marker.position)
            count += 1
        }
        val padding = params?.number("padding")?.toInt()?.coerceIn(0, MAX_PADDING) ?: 0
        val update = CameraUpdateFactory.newLatLngBounds(bounds.build(), padding)
        cameraChangeSource = "api"
        if (params?.boolean("animated") ?: true) map?.animateCamera(update) else map?.moveCamera(update)
        callbackSuccess(callback, JavaOnlyMap().apply {
            putBoolean("accepted", true)
            putInt("count", count)
        })
    }

    @LynxUIMethod
    fun getPerformanceSnapshot(params: ReadableMap?, callback: Callback) {
        callbackSuccess(callback, JavaOnlyMap().apply {
                putInt("schemaVersion", 1)
                putInt("applyCount", applyCount)
                putDouble("lastApplyDurationMs", lastApplyDurationMs)
                putInt("markerCount", markers.size)
                putInt("polylineCount", polylines.size)
                putInt("massPointCount", massPointOverlay?.items?.size ?: 0)
                putBoolean("pendingRender", false)
                putBoolean("providerReady", providerReady)
                putNull("fps")
                putNull("frameTimeMs")
                putString("note", "FPS/frame time 需要 Android FrameMetrics 或 Perfetto 采样。")
            })
    }

    @LynxUIMethod
    fun fitBounds(params: ReadableMap?, callback: Callback) {
        val bounds = params?.map("bounds") ?: params
        val southwest = bounds?.map("southwest")
        val northeast = bounds?.map("northeast")
        val southwestLat = southwest?.number("latitude")
        val southwestLon = southwest?.number("longitude")
        val northeastLat = northeast?.number("latitude")
        val northeastLon = northeast?.number("longitude")
        if (southwestLat == null || southwestLon == null || northeastLat == null || northeastLon == null) {
            callbackFailure(callback, LynxMapResult.invalid("fitBounds.bounds 参数无效"))
            return
        }
        val padding = params?.number("padding")?.toInt()?.coerceIn(0, MAX_PADDING) ?: 0
        val boundsValue = LatLngBounds.Builder()
            .include(LatLng(southwestLat, southwestLon))
            .include(LatLng(northeastLat, northeastLon))
            .build()
        cameraChangeSource = "api"
        val update = CameraUpdateFactory.newLatLngBounds(boundsValue, padding)
        if (params?.boolean("animated") ?: true) map?.animateCamera(update) else map?.moveCamera(update)
        callbackSuccess(callback, JavaOnlyMap().apply { putBoolean("accepted", true) })
    }

    @LynxUIMethod
    fun getCapabilities(params: ReadableMap?, callback: Callback) {
        callbackSuccess(callback, JavaOnlyMap().apply {
                putInt("schemaVersion", 1)
                putInt("contractVersion", 3)
                putBoolean("available", LynxMapRuntime.isConfigured())
                putString("provider", "amap-android")
                putMap("features", JavaOnlyMap().apply {
                    putBoolean("camera.move", true)
                    putBoolean("camera.read", true)
                    putBoolean("camera.fitBounds", true)
                    putBoolean("camera.bearing", true)
                    putBoolean("camera.pitch", true)
                    putBoolean("camera.anchor", true)
                    putBoolean("map.projectCoordinate", true)
                    putBoolean("map.tap", true)
                    putBoolean("map.longPress", true)
                    putBoolean("overlay.marker", true)
                    putBoolean("overlay.polyline", true)
                    putBoolean("overlay.massPoints", true)
                    putBoolean("overlay.layerVisibility", true)
                    putBoolean("overlay.layerOpacity", true)
                    putBoolean("overlay.layerZIndex", true)
                    putBoolean("overlay.markerZIndex", true)
                    putBoolean("marker.selection", true)
                    putBoolean("marker.drag", true)
                    putBoolean("marker.icon", true)
                    putBoolean("marker.view", true)
                    putBoolean("massPoints", true)
                    putBoolean("amap.traffic", true)
                    putBoolean("lifecycle.pauseResume", true)
                    putBoolean("interaction.gestures", true)
                    putBoolean("controls.native", true)
                    putArray("amap.overlayLevels", JavaOnlyArray.from(listOf("aboveRoads", "aboveLabels")))
                    putArray("amap.layers", JavaOnlyArray.from(listOf("base", "traffic", "marker", "polyline")))
                })
                putMap("limits", JavaOnlyMap().apply {
                    putInt("markers", 200)
                    putInt("identifierLength", 128)
                    putInt("markerTextLength", 256)
                    putInt("colorLength", 16)
                    putInt("polylines", 50)
                    putInt("massPoints", 5000)
                    putInt("polylinePointsPerPath", 512)
                    putInt("polylinePointsTotal", 5000)
                    putDouble("zoomMin", 0.0)
                    putDouble("zoomMax", 24.0)
                    putDouble("polylineWidthMax", 128.0)
                    putInt("fitBoundsPaddingMax", MAX_PADDING)
                    putInt("zIndexMagnitudeMax", 100000)
                })
                putMap("apiCatalog", JavaOnlyMap().apply {
                    putArray("element", JavaOnlyArray.from(listOf(
                        "camera.center", "camera.zoom", "camera.bearing", "camera.pitch", "camera.anchor",
                        "camera.fitBounds", "map.projectCoordinate", "map.tap", "map.regionChange",
                        "overlay.marker", "marker.icon", "marker.view", "overlay.polyline", "overlay.massPoints",
                        "overlay.visibility", "overlay.opacity", "overlay.zIndex", "map.mapType", "map.traffic",
                        "interaction.gestures", "controls.native", "lifecycle.pauseResume",
                    )))
                    putArray("service", JavaOnlyArray.from(listOf(
                        "poi.search", "geocode", "route.plan", "route.transit", "location.getCurrent", "location.start/stop",
                    )))
                    putArray("nativePage", JavaOnlyArray.from(listOf("navigation", "massPoints", "indoor", "offlineMap")))
                })
        })
        if (!LynxMapRuntime.isConfigured()) {
            // available=false 已在 data 中返回；reasonCode 由能力快照消费者按宿主状态处理。
        }
    }

    private fun applyCamera(animated: Boolean) {
        val target = CameraPosition.Builder()
            .target(center)
            .zoom(zoom)
            .bearing(bearing)
            .tilt(pitch)
            .build()
        map?.let {
            if (animated) it.animateCamera(CameraUpdateFactory.newCameraPosition(target))
            else it.moveCamera(CameraUpdateFactory.newCameraPosition(target))
        }
    }

    private fun renderMarkers(value: ReadableArray?) {
        val startedAt = System.nanoTime()
        pendingIconTasks.values.forEach { it.cancel(true) }
        pendingIconTasks.clear()
        markers.values.forEach { it.remove() }
        markers.clear()
        val currentMap = map ?: return
        if (value == null) return
        for (index in 0 until minOf(value.size(), 200)) {
            val item = value.getMap(index) ?: continue
            val coordinate = item.map("coordinate") ?: continue
            val lat = coordinate.number("latitude") ?: continue
            val lon = coordinate.number("longitude") ?: continue
            if (!validCoordinate(lat, lon)) continue
            val id = item.string("id") ?: "marker-$index"
            val markerOptions = MarkerOptions()
                    .position(LatLng(lat, lon))
                    .title(item.string("title"))
                    .snippet(item.string("subtitle"))
                    .draggable(item.boolean("draggable") ?: false)
                    .visible(item.boolean("visible") ?: true)
                    .alpha(((item.number("opacity") ?: 1.0).toFloat().coerceIn(0f, 1f) * layerOpacity))
                    .zIndex((item.number("zIndex") ?: 0.0).toFloat() + layerZIndex)
            val viewConfiguration = item.map("view")
            val iconConfiguration = item.map("icon")
            var markerDescriptor: BitmapDescriptor? = null
            if (viewConfiguration != null) {
                markerDescriptor = createViewDescriptor(viewConfiguration)
                markerDescriptor?.let { markerOptions.icon(it) }
            } else {
                iconConfiguration?.string("uri")?.let { uri ->
                    if (uri.startsWith("https://")) {
                        markerOptions.icon(BitmapDescriptorFactory.defaultMarker())
                    }
                }
            }
            val anchor = (viewConfiguration ?: iconConfiguration)?.map("anchor")
            if (anchor != null) {
                markerOptions.anchor(
                    (anchor.number("x") ?: .5).toFloat().coerceIn(0f, 1f),
                    (anchor.number("y") ?: 1.0).toFloat().coerceIn(0f, 1f),
                )
            }
            val marker = currentMap.addMarker(markerOptions) ?: continue
            marker.setObject(id)
            val selected = item.boolean("selected") ?: false
            marker.setIcon(if (selected) BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_ORANGE) else markerDescriptor ?: BitmapDescriptorFactory.defaultMarker())
            markers[id] = marker
            val uri = iconConfiguration?.string("uri")
            if (viewConfiguration != null && uri.isNullOrBlank()) {
                // View marker 已在主线程生成，避免把 Lynx view 跨边界传给 AMap。
            } else if (uri?.startsWith("https://") == true) {
                loadIconAsync(id, uri)
            }
        }
        applyCount += 1
        lastApplyDurationMs = (System.nanoTime() - startedAt) / 1_000_000.0
    }

    private fun renderPolylines(value: ReadableArray?) {
        val startedAt = System.nanoTime()
        polylines.values.forEach { it.remove() }
        polylines.clear()
        val currentMap = map ?: return
        if (value == null) return
        for (index in 0 until minOf(value.size(), 50)) {
            val item = value.getMap(index) ?: continue
            val points = item.array("points") ?: continue
            val options = PolylineOptions()
                .width((item.number("width") ?: 6.0).toFloat().coerceIn(1f, 128f))
                .color(withAlpha(parseColor(item.string("color")), ((item.number("opacity") ?: 1.0).toFloat() * layerOpacity).coerceIn(0f, 1f)))
                .visible((item.boolean("visible") ?: true) && layerVisible)
                .zIndex((item.number("zIndex") ?: 0.0).toFloat() + layerZIndex)
            for (pointIndex in 0 until points.size()) {
                val point = points.getMap(pointIndex) ?: continue
                val lat = point.number("latitude") ?: continue
                val lon = point.number("longitude") ?: continue
                if (validCoordinate(lat, lon)) options.add(LatLng(lat, lon))
            }
            if (options.points.size < 2) continue
            val id = item.string("id") ?: "polyline-$index"
            currentMap.addPolyline(options)?.also { polylines[id] = it }
        }
        applyCount += 1
        lastApplyDurationMs = (System.nanoTime() - startedAt) / 1_000_000.0
    }

    private fun renderMassPoints(value: ReadableArray?) {
        val currentMap = map ?: return
        massPointOverlay?.remove()
        massPointOverlay = null
        if (value == null || value.size() == 0) return
        val items = ArrayList<MultiPointItem>(minOf(value.size(), MAX_MASS_POINTS))
        for (index in 0 until minOf(value.size(), MAX_MASS_POINTS)) {
            val item = value.getMap(index) ?: continue
            val coordinate = item.map("coordinate") ?: continue
            val latitude = coordinate.number("latitude") ?: continue
            val longitude = coordinate.number("longitude") ?: continue
            if (!validCoordinate(latitude, longitude)) continue
            val point = MultiPointItem(LatLng(latitude, longitude)).apply {
                customerId = item.string("id") ?: "mass-$index"
                title = item.string("title")
                snippet = item.string("subtitle")
            }
            items += point
        }
        if (items.isEmpty()) return
        massPointOverlay = currentMap.addMultiPointOverlay(
            MultiPointOverlayOptions().apply {
                icon(BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_AZURE))
                anchor(.5f, .5f)
                setMultiPointItems(items)
                setEnable(layerVisible)
            },
        )
    }

    private fun applyOverlayVisibility() {
        renderMarkers(markerInput)
        renderPolylines(polylineInput)
        renderMassPoints(massPointInput)
    }

    private fun setMarkerSelection(params: ReadableMap?, callback: Callback, selected: Boolean) {
        val id = params?.string("id") ?: params?.string("identifier")
        if (id.isNullOrBlank()) {
            callbackFailure(callback, LynxMapResult.invalid("marker id 无效"))
            return
        }
        val marker = markers[id]
        if (marker == null) {
            callbackFailure(callback, LynxMapResult.invalid("marker 不存在：$id"))
            return
        }
        updateMarkerSelection(id, selected)
        callbackSuccess(callback, JavaOnlyMap().apply {
            putBoolean("accepted", true)
            putString("id", id)
        })
    }

    private fun updateMarkerSelection(id: String, selected: Boolean) {
        val marker = markers[id] ?: return
        val previous = markers.entries.firstOrNull { it.value.isInfoWindowShown && it.key != id }?.key
        if (selected && previous != null) {
            markers[previous]?.setIcon(BitmapDescriptorFactory.defaultMarker())
            emit("markerdeselected", mapOf("id" to previous, "coordinate" to coordinateMap(markers[previous]?.position?.latitude ?: 0.0, markers[previous]?.position?.longitude ?: 0.0), "selected" to false))
        }
        marker.setIcon(if (selected) BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_ORANGE) else BitmapDescriptorFactory.defaultMarker())
        if (selected) marker.showInfoWindow() else marker.hideInfoWindow()
        emit(
            if (selected) "markerselected" else "markerdeselected",
            mapOf("id" to id, "coordinate" to coordinateMap(marker.position.latitude, marker.position.longitude), "selected" to selected),
        )
    }

    private fun emitRegion(position: CameraPosition, phase: String) {
        emit(
            "regionchange",
            mapOf(
                "center" to coordinateMap(position.target.latitude, position.target.longitude),
                "zoom" to position.zoom,
                "source" to cameraChangeSource,
                "phase" to phase,
            ),
        )
    }

    private fun createViewDescriptor(configuration: ReadableMap): BitmapDescriptor? {
        val width = (configuration.number("width") ?: 44.0).toFloat().coerceIn(1f, 256f).roundToInt()
        val height = (configuration.number("height") ?: 44.0).toFloat().coerceIn(1f, 256f).roundToInt()
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = parseColor(configuration.string("backgroundColor") ?: "#147EF5")
            style = Paint.Style.FILL
        }
        val radius = (configuration.number("cornerRadius") ?: 0.0).toFloat().coerceIn(0f, minOf(width, height) / 2f)
        canvas.drawRoundRect(0f, 0f, width.toFloat(), height.toFloat(), radius, radius, paint)
        val borderWidth = (configuration.number("borderWidth") ?: 0.0).toFloat().coerceIn(0f, 16f)
        if (borderWidth > 0f) {
            paint.style = Paint.Style.STROKE
            paint.strokeWidth = borderWidth
            paint.color = parseColor(configuration.string("borderColor") ?: "#FFFFFF")
            canvas.drawRoundRect(borderWidth / 2f, borderWidth / 2f, width - borderWidth / 2f, height - borderWidth / 2f, radius, radius, paint)
        }
        configuration.string("text")?.let { text ->
            paint.style = Paint.Style.FILL
            paint.color = parseColor(configuration.string("foregroundColor") ?: "#FFFFFF")
            paint.textAlign = Paint.Align.CENTER
            paint.typeface = Typeface.DEFAULT_BOLD
            paint.textSize = minOf(width, height) * .34f
            val baseline = height / 2f - (paint.ascent() + paint.descent()) / 2f
            canvas.drawText(text.take(16), width / 2f, baseline, paint)
        }
        return BitmapDescriptorFactory.fromBitmap(bitmap)
    }

    private fun loadIconAsync(id: String, uri: String) {
        val cached = iconCache[uri]
        if (cached != null) {
            markers[id]?.setIcon(cached)
            return
        }
        val task = iconExecutor.submit {
            val descriptor = runCatching {
                val connection = (URL(uri).openConnection() as HttpURLConnection).apply {
                    connectTimeout = 4000
                    readTimeout = 4000
                    instanceFollowRedirects = true
                }
                connection.inputStream.use { stream ->
                    BitmapFactory.decodeStream(stream)?.let { bitmap -> BitmapDescriptorFactory.fromBitmap(bitmap) }
                }
            }.getOrNull() ?: return@submit
            iconCache[uri] = descriptor
            mainHandler.post { markers[id]?.setIcon(descriptor) }
        }
        pendingIconTasks["$id:$uri"] = task
    }

    private fun emitMarkerDrag(marker: Marker, phase: String) {
        emit(
            "markerdrag",
            mapOf(
                "id" to (marker.getObject()?.toString() ?: marker.id),
                "coordinate" to coordinateMap(marker.position.latitude, marker.position.longitude),
                "phase" to phase,
            ),
        )
    }

    private fun emit(name: String, params: Map<String, Any?>) {
        val safeParams = HashMap<String, Any>()
        params.forEach { (key, value) -> if (value != null) safeParams[key] = value }
        getLynxContext().eventEmitter.sendCustomEvent(
            LynxCustomEvent(sign, name, safeParams),
        )
    }

    /** Lynx 4.1 UI Method callback 的第一个参数必须是 Integer code。 */
    private fun callbackSuccess(callback: Callback, data: JavaOnlyMap = JavaOnlyMap()) {
        callback.invoke(0, data)
    }

    private fun callbackFailure(callback: Callback, result: JavaOnlyMap) {
        val code = if (result.hasKey("code")) result.getInt("code") else 1001
        callback.invoke(code, result)
    }

    private fun coordinateMap(latitude: Double, longitude: Double): JavaOnlyMap = JavaOnlyMap().apply {
        putDouble("latitude", latitude)
        putDouble("longitude", longitude)
    }

    private fun parseColor(value: String?): Int = runCatching {
        Color.parseColor(value ?: "#087cf9")
    }.getOrDefault(Color.rgb(8, 124, 249))

    private fun withAlpha(color: Int, alpha: Float): Int = Color.argb(
        (alpha.coerceIn(0f, 1f) * 255f).roundToInt(),
        Color.red(color),
        Color.green(color),
        Color.blue(color),
    )

    private fun validCoordinate(latitude: Double, longitude: Double): Boolean =
        latitude in -90.0..90.0 && longitude in -180.0..180.0

    private fun ReadableMap.number(key: String): Double? =
        if (hasKey(key) && !isNull(key)) getDouble(key) else null

    private fun ReadableMap.string(key: String): String? =
        if (hasKey(key) && !isNull(key)) getString(key) else null

    private fun ReadableMap.boolean(key: String): Boolean? =
        if (hasKey(key) && !isNull(key)) getBoolean(key) else null

    private fun ReadableMap.map(key: String): ReadableMap? =
        if (hasKey(key) && !isNull(key)) getMap(key) else null

    private fun ReadableMap.array(key: String): ReadableArray? =
        if (hasKey(key) && !isNull(key)) getArray(key) else null

    companion object {
        private const val DEFAULT_LATITUDE = 39.9042
        private const val DEFAULT_LONGITUDE = 116.4074
        private const val DEFAULT_ZOOM = 12f
        private const val MAX_MARKERS = 200
        private const val MAX_POLYLINES = 50
        private const val MAX_MASS_POINTS = 5000
        private const val MAX_PADDING = 4096
    }
}

/**
 * 地图嵌在 Lynx scroll-view 时，必须在 View 分发阶段决定是否交给地图。
 * 只在地图手势开启时禁止父容器抢事件；关闭手势时返回 false，让页面继续滚动。
 */
private class LynxTextureMapView(
    context: Context,
    private val isTouchEnabled: () -> Boolean,
    private val blockedTopRatio: () -> Float,
) : TextureMapView(context) {
    private var blockedGesture = false

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_DOWN) {
            blockedGesture = height > 0 && event.y >= height * blockedTopRatio().coerceIn(0f, 1f)
            if (blockedGesture) {
                parent?.requestDisallowInterceptTouchEvent(false)
                return false
            }
        }
        if (blockedGesture) return false

        val enabled = isTouchEnabled()
        if (!enabled) {
            if (event.actionMasked == MotionEvent.ACTION_DOWN) {
                parent?.requestDisallowInterceptTouchEvent(false)
            }
            return false
        }

        if (event.actionMasked == MotionEvent.ACTION_DOWN || event.actionMasked == MotionEvent.ACTION_MOVE) {
            parent?.requestDisallowInterceptTouchEvent(true)
        }
        val handled = super.dispatchTouchEvent(event)
        if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) {
            parent?.requestDisallowInterceptTouchEvent(false)
        }
        return handled
    }
}
