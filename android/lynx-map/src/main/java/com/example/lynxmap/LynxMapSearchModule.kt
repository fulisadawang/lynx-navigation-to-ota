package com.example.lynxmap

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.amap.api.services.core.LatLonPoint
import com.amap.api.services.core.PoiItem
import com.amap.api.services.geocoder.GeocodeAddress
import com.amap.api.services.geocoder.GeocodeQuery
import com.amap.api.services.geocoder.GeocodeSearch
import com.amap.api.services.geocoder.RegeocodeQuery
import com.amap.api.services.geocoder.RegeocodeResult
import com.amap.api.services.poisearch.PoiResult
import com.amap.api.services.poisearch.PoiSearch
import com.amap.api.services.route.BusPathV2
import com.amap.api.services.route.BusRouteResultV2
import com.amap.api.services.route.BusStepV2
import com.amap.api.services.route.DrivePathV2
import com.amap.api.services.route.DriveRouteResultV2
import com.amap.api.services.route.DriveStepV2
import com.amap.api.services.route.Path
import com.amap.api.services.route.RidePath
import com.amap.api.services.route.RideRouteResultV2
import com.amap.api.services.route.RideStep
import com.amap.api.services.route.RouteBusLineItem
import com.amap.api.services.route.RouteSearchV2
import com.amap.api.services.route.WalkPath
import com.amap.api.services.route.WalkRouteResultV2
import com.amap.api.services.route.WalkStep
import com.lynx.jsbridge.LynxMethod
import com.lynx.jsbridge.LynxModule
import com.lynx.react.bridge.Callback
import com.lynx.react.bridge.JavaOnlyMap
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicLong

/** AMap Search/Route 的 Lynx 服务边界，输出与 iOS 服务一致的可序列化 JSON。 */
class LynxMapSearchModule(context: Context) : LynxModule(context) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val generation = AtomicLong(0)
    private var destroyed = false
    private var activeCompletion: ((JavaOnlyMap) -> Unit)? = null
    private var poiSearch: PoiSearch? = null
    private var geocodeSearch: GeocodeSearch? = null
    private var routeSearch: RouteSearchV2? = null

    @LynxMethod
    fun searchPOI(optionsJSON: String?, callback: Callback) {
        mainHandler.post {
            val options = ready(optionsJSON, callback) ?: return@post
            runCatching {
                val keyword = requiredString(options, "keyword", 128)
                val city = optionalString(options, "city", 64)
                val query = PoiSearch.Query(keyword, optionalString(options, "types", 256), city).apply {
                    pageNum = integer(options, "page", 1, 1..100)
                    pageSize = integer(options, "offset", 20, 1..25)
                    setCityLimit(options.optBoolean("cityLimit", false))
                    extensions = PoiSearch.EXTENSIONS_ALL
                    coordinate(options.optJSONObject("location"))?.let { setLocation(it) }
                }
                val search = PoiSearch(hostContext(), query)
                poiSearch = search
                val requestGeneration = begin(callback)
                search.setOnPoiSearchListener(object : PoiSearch.OnPoiSearchListener {
                    override fun onPoiSearched(result: PoiResult?, code: Int) {
                        if (!isCurrent(requestGeneration)) return
                        if (code != 1000 || result == null) {
                            finish(LynxMapResult.error(1206, "高德 POI 搜索失败：$code"))
                            return
                        }
                        finish(LynxMapResult.success("搜索成功", mapOf(
                            "count" to (result.pois?.size ?: 0),
                            "pois" to (result.pois ?: emptyList<PoiItem>()).take(25).map(::poiData),
                        )))
                    }

                    override fun onPoiItemSearched(result: PoiItem?, code: Int) = Unit
                })
                search.searchPOIAsyn()
            }.onFailure { error -> finish(LynxMapResult.error(code(error), error.message ?: "POI 搜索参数无效")) }
        }
    }

    @LynxMethod
    fun reverseGeocode(optionsJSON: String?, callback: Callback) {
        mainHandler.post {
            val options = ready(optionsJSON, callback) ?: return@post
            runCatching {
                val point = requiredCoordinate(options, "coordinate")
                val search = GeocodeSearch(hostContext())
                geocodeSearch = search
                val requestGeneration = begin(callback)
                search.setOnGeocodeSearchListener(object : GeocodeSearch.OnGeocodeSearchListener {
                    override fun onRegeocodeSearched(result: RegeocodeResult?, code: Int) {
                        if (!isCurrent(requestGeneration)) return
                        if (code != 1000 || result?.regeocodeAddress == null) {
                            finish(LynxMapResult.error(1206, "高德逆地理编码失败：$code"))
                            return
                        }
                        finish(LynxMapResult.success("搜索成功", mapOf("reGeocode" to regeocodeData(result))))
                    }

                    override fun onGeocodeSearched(result: com.amap.api.services.geocoder.GeocodeResult?, code: Int) = Unit
                })
                val radius = integer(options, "radius", 1000, 0..3000)
                search.getFromLocationAsyn(
                    RegeocodeQuery(point, radius.toFloat(), GeocodeSearch.AMAP).apply {
                        extensions = if (options.optBoolean("requireExtension", true)) GeocodeSearch.EXTENSIONS_ALL else GeocodeSearch.EXTENSIONS_BASE
                    },
                )
            }.onFailure { error -> finish(LynxMapResult.error(code(error), error.message ?: "逆地理编码参数无效")) }
        }
    }

    @LynxMethod
    fun geocode(optionsJSON: String?, callback: Callback) {
        mainHandler.post {
            val options = ready(optionsJSON, callback) ?: return@post
            runCatching {
                val address = requiredString(options, "address", 256)
                val search = GeocodeSearch(hostContext())
                geocodeSearch = search
                val requestGeneration = begin(callback)
                search.setOnGeocodeSearchListener(object : GeocodeSearch.OnGeocodeSearchListener {
                    override fun onRegeocodeSearched(result: RegeocodeResult?, code: Int) = Unit

                    override fun onGeocodeSearched(result: com.amap.api.services.geocoder.GeocodeResult?, code: Int) {
                        if (!isCurrent(requestGeneration)) return
                        if (code != 1000 || result == null) {
                            finish(LynxMapResult.error(1206, "高德地理编码失败：$code"))
                            return
                        }
                        finish(LynxMapResult.success("搜索成功", mapOf(
                            "count" to (result.geocodeAddressList?.size ?: 0),
                            "geocodes" to (result.geocodeAddressList ?: emptyList<GeocodeAddress>()).take(10).map(::geocodeData),
                        )))
                    }
                })
                search.getFromLocationNameAsyn(GeocodeQuery(address, optionalString(options, "city", 64)))
            }.onFailure { error -> finish(LynxMapResult.error(code(error), error.message ?: "地理编码参数无效")) }
        }
    }

    @LynxMethod
    fun searchRoute(optionsJSON: String?, callback: Callback) {
        mainHandler.post {
            val options = ready(optionsJSON, callback) ?: return@post
            runCatching {
                val origin = requiredCoordinate(options, "origin")
                val destination = requiredCoordinate(options, "destination")
                val fromAndTo = RouteSearchV2.FromAndTo(origin, destination)
                val mode = options.optString("mode", "driving").lowercase()
                val search = RouteSearchV2(hostContext())
                routeSearch = search
                val requestGeneration = begin(callback)
                search.setRouteSearchListener(routeListener(requestGeneration))
                when (mode) {
                    "walking" -> search.calculateWalkRouteAsyn(
                        RouteSearchV2.WalkRouteQuery(fromAndTo).apply {
                            showFields = routeShowFields()
                            alternativeRoute = options.optInt("alternativeRoute", 3).coerceIn(1, 3)
                        },
                    )
                    "riding", "cycling" -> search.calculateRideRouteAsyn(
                        RouteSearchV2.RideRouteQuery(fromAndTo).apply {
                            showFields = routeShowFields()
                            alternativeRoute = options.optInt("alternativeRoute", 3).coerceIn(1, 3)
                        },
                    )
                    "driving" -> {
                        val passedBy = coordinates(options.optJSONArray("waypoints"), "waypoints", 16)
                        val strategyValue = options.optInt("strategy", RouteSearchV2.DrivingStrategy.DEFAULT.value)
                        val strategy = drivingStrategy(strategyValue)
                        search.calculateDriveRouteAsyn(
                            RouteSearchV2.DriveRouteQuery(fromAndTo, strategy, passedBy, null, null).apply {
                                showFields = routeShowFields() or RouteSearchV2.ShowFields.TMCS
                            },
                        )
                    }
                    else -> error("mode 只支持 driving、walking、riding")
                }
            }.onFailure { error -> finish(LynxMapResult.error(code(error), error.message ?: "路线参数无效")) }
        }
    }

    @LynxMethod
    fun searchTransit(optionsJSON: String?, callback: Callback) {
        mainHandler.post {
            val options = ready(optionsJSON, callback) ?: return@post
            runCatching {
                val origin = requiredCoordinate(options, "origin")
                val destination = requiredCoordinate(options, "destination")
                val city = requiredString(options, "city", 32)
                val fromAndTo = RouteSearchV2.FromAndTo(origin, destination)
                val search = RouteSearchV2(hostContext())
                routeSearch = search
                val requestGeneration = begin(callback)
                search.setRouteSearchListener(routeListener(requestGeneration))
                val query = RouteSearchV2.BusRouteQuery(
                    fromAndTo,
                    options.optInt("strategy", RouteSearchV2.BusMode.BUS_DEFAULT).coerceIn(0, 8),
                    city,
                    options.optInt("nightFlag", 0),
                ).apply {
                    cityd = optionalString(options, "destinationCity", 32) ?: city
                    date = optionalString(options, "date", 16)
                    time = optionalString(options, "time", 8)
                    maxTrans = options.optInt("maxTrans", 4).coerceIn(0, 4)
                    alternativeRoute = options.optInt("alternativeRoute", 5).coerceIn(1, 10)
                    showFields = routeShowFields()
                }
                search.calculateBusRouteAsyn(query)
            }.onFailure { error -> finish(LynxMapResult.error(code(error), error.message ?: "公交路线参数无效")) }
        }
    }

    @LynxMethod
    fun cancelSearch(callback: Callback) {
        mainHandler.post {
            generation.incrementAndGet()
            activeCompletion?.invoke(LynxMapResult.error(1207, "搜索请求已取消"))
            activeCompletion = null
            callback.invoke(LynxMapResult.success("搜索已取消", mapOf("status" to "cancelled")))
        }
    }

    override fun destroy() {
        mainHandler.post {
            destroyed = true
            generation.incrementAndGet()
            activeCompletion?.invoke(LynxMapResult.error(1207, "搜索请求已取消"))
            activeCompletion = null
            poiSearch = null
            geocodeSearch = null
            routeSearch = null
        }
        super.destroy()
    }

    private fun routeListener(requestGeneration: Long) = object : RouteSearchV2.OnRouteSearchListener {
        override fun onDriveRouteSearched(result: DriveRouteResultV2?, code: Int) {
            if (!isCurrent(requestGeneration)) return
            if (code != 1000 || result == null) {
                finish(LynxMapResult.error(1206, "高德驾车路线失败：$code"))
                return
            }
            finish(LynxMapResult.success("搜索成功", mapOf(
                "count" to (result.paths?.size ?: 0),
                "paths" to (result.paths ?: emptyList<DrivePathV2>()).take(3).map(::driveV2PathData),
            )))
        }

        override fun onWalkRouteSearched(result: WalkRouteResultV2?, code: Int) {
            if (!isCurrent(requestGeneration)) return
            if (code != 1000 || result == null) {
                finish(LynxMapResult.error(1206, "高德步行路线失败：$code"))
                return
            }
            finish(LynxMapResult.success("搜索成功", mapOf(
                "count" to (result.paths?.size ?: 0),
                "paths" to (result.paths ?: emptyList<WalkPath>()).take(3).map(::routePathData),
            )))
        }

        override fun onRideRouteSearched(result: RideRouteResultV2?, code: Int) {
            if (!isCurrent(requestGeneration)) return
            if (code != 1000 || result == null) {
                finish(LynxMapResult.error(1206, "高德骑行路线失败：$code"))
                return
            }
            finish(LynxMapResult.success("搜索成功", mapOf(
                "count" to (result.paths?.size ?: 0),
                "paths" to (result.paths ?: emptyList<RidePath>()).take(3).map(::routePathData),
            )))
        }

        override fun onBusRouteSearched(result: BusRouteResultV2?, code: Int) {
            if (!isCurrent(requestGeneration)) return
            if (code != 1000 || result == null) {
                finish(LynxMapResult.error(1206, "高德公交路线失败：$code"))
                return
            }
            finish(LynxMapResult.success("搜索成功", mapOf(
                "count" to (result.paths?.size ?: 0),
                "distance" to result.distance,
                "transits" to (result.paths ?: emptyList<BusPathV2>()).take(10).map(::transitV2Data),
            )))
        }
    }

    private fun ready(optionsJSON: String?, callback: Callback): JSONObject? {
        if (destroyed) {
            callback.invoke(LynxMapResult.error(1207, "搜索服务实例已销毁"))
            return null
        }
        if (!LynxMapRuntime.isConfigured()) {
            callback.invoke(LynxMapResult.error(1202, "高德搜索隐私配置未完成"))
            return null
        }
        return runCatching {
            val value = optionsJSON?.trim().orEmpty()
            if (value.isEmpty()) JSONObject() else JSONObject(value)
        }.getOrElse {
            callback.invoke(LynxMapResult.error(1201, "搜索 options 必须是 JSON Object"))
            null
        }
    }

    private fun begin(callback: Callback): Long {
        activeCompletion?.invoke(LynxMapResult.error(1207, "搜索请求已取消"))
        val value = generation.incrementAndGet()
        activeCompletion = { result -> callback.invoke(result) }
        return value
    }

    private fun isCurrent(requestGeneration: Long): Boolean = !destroyed && requestGeneration == generation.get()

    private fun finish(result: JavaOnlyMap) {
        val completion = activeCompletion ?: return
        activeCompletion = null
        completion(result)
    }

    private fun coordinate(value: JSONObject?): LatLonPoint? {
        if (value == null) return null
        val latitude = value.optDouble("latitude", Double.NaN)
        val longitude = value.optDouble("longitude", Double.NaN)
        require(latitude.isFinite() && longitude.isFinite() && latitude in -90.0..90.0 && longitude in -180.0..180.0) { "坐标无效" }
        return LatLonPoint(latitude, longitude)
    }

    private fun requiredCoordinate(options: JSONObject, key: String): LatLonPoint = coordinate(options.optJSONObject(key)) ?: error("$key 坐标无效")

    private fun coordinates(value: JSONArray?, key: String, maxCount: Int): List<LatLonPoint>? {
        if (value == null) return null
        require(value.length() <= maxCount) { "$key 不能超过 $maxCount 个点" }
        return (0 until value.length()).map { index -> coordinate(value.optJSONObject(index)) ?: error("$key 坐标无效") }
    }

    private fun requiredString(options: JSONObject, key: String, maxLength: Int): String {
        val value = options.optString(key, "").trim()
        require(value.isNotEmpty() && value.length <= maxLength) { "$key 不能为空且不能超过 $maxLength 个字符" }
        return value
    }

    private fun optionalString(options: JSONObject, key: String, maxLength: Int): String? = options.optString(key, "").trim().takeIf { it.isNotEmpty() && it.length <= maxLength }

    private fun integer(options: JSONObject, key: String, defaultValue: Int, range: IntRange): Int {
        val value = options.optInt(key, defaultValue)
        require(value in range) { "$key 超出允许范围" }
        return value
    }

    private fun routeShowFields(): Int =
        RouteSearchV2.ShowFields.COST or
            RouteSearchV2.ShowFields.NAVI or
            RouteSearchV2.ShowFields.POLINE

    private fun drivingStrategy(value: Int): RouteSearchV2.DrivingStrategy =
        runCatching { RouteSearchV2.DrivingStrategy.fromValue(value) }
            .getOrElse { error("strategy 不支持：$value，请使用 32..45") }

    private fun poiData(poi: PoiItem): Map<String, Any> = buildMap {
        put("id", poi.poiId ?: "")
        put("name", poi.title ?: "")
        put("type", poi.typeDes ?: "")
        put("typecode", poi.typeCode ?: "")
        put("address", poi.snippet ?: "")
        put("tel", poi.tel ?: "")
        put("distance", poi.distance)
        put("city", poi.cityName ?: "")
        put("district", poi.adName ?: "")
        poi.latLonPoint?.let { put("coordinate", coordinateData(it)) }
    }

    private fun geocodeData(value: GeocodeAddress): Map<String, Any> = buildMap {
        put("formattedAddress", value.formatAddress ?: "")
        put("province", value.province ?: "")
        put("city", value.city ?: "")
        put("district", value.district ?: "")
        put("adcode", value.adcode ?: "")
        put("level", value.level ?: "")
        value.latLonPoint?.let { put("coordinate", coordinateData(it)) }
    }

    private fun regeocodeData(result: RegeocodeResult): Map<String, Any> {
        val value = result.regeocodeAddress ?: return emptyMap()
        return buildMap {
            put("formattedAddress", value.formatAddress ?: "")
            put("province", value.province ?: "")
            put("city", value.city ?: "")
            put("district", value.district ?: "")
            put("township", value.township ?: "")
            value.streetNumber?.let {
                put("street", it.street ?: "")
                put("number", it.number ?: "")
            }
            put("adcode", value.adCode ?: "")
            value.pois?.firstOrNull()?.let { poi ->
                poi.latLonPoint?.let { point ->
                    put("nearestPOI", mapOf("id" to (poi.poiId ?: ""), "name" to (poi.title ?: ""), "coordinate" to coordinateData(point)))
                }
            }
        }
    }

    private fun routePathData(path: Path): Map<String, Any> = buildMap {
        put("distance", path.distance)
        put("duration", path.duration)
        put("tolls", 0f)
        put("totalTrafficLights", 0)
        put("polyline", path.polyline.orEmpty().map(::coordinateData))
        val steps: List<Any> = when (path) {
            is WalkPath -> path.steps.orEmpty().take(64).map(::walkStepData)
            is RidePath -> path.steps.orEmpty().take(64).map(::rideStepData)
            else -> emptyList()
        }
        put("steps", steps)
    }

    private fun driveV2PathData(path: DrivePathV2): Map<String, Any> = buildMap {
        val cost = path.cost
        val duration = if (path.duration > 0L) path.duration else (cost?.duration ?: 0f).toLong()
        put("distance", path.distance)
        put("duration", duration)
        put("tolls", cost?.tolls ?: 0f)
        put("totalTrafficLights", cost?.trafficLights ?: 0)
        put("polyline", path.polyline.orEmpty().map(::coordinateData))
        put("steps", path.steps.orEmpty().take(64).map(::driveV2StepData))
    }

    private fun driveV2StepData(step: DriveStepV2): Map<String, Any> = stepData(
        step.instruction,
        step.road,
        step.stepDistance.toFloat(),
        step.costDetail?.duration ?: 0f,
        step.polyline,
    )

    private fun walkStepData(step: WalkStep): Map<String, Any> = stepData(step.instruction, step.road, step.distance, step.duration, step.polyline)

    private fun rideStepData(step: RideStep): Map<String, Any> = stepData(step.instruction, step.road, step.distance, step.duration, step.polyline)

    private fun stepData(instruction: String?, road: String?, distance: Float, duration: Float, points: List<LatLonPoint>?): Map<String, Any> = mapOf(
        "instruction" to (instruction ?: ""),
        "road" to (road ?: ""),
        "distance" to distance,
        "duration" to duration,
        "polyline" to points.orEmpty().map(::coordinateData),
    )

    private fun transitV2Data(path: BusPathV2): Map<String, Any> = buildMap {
        put("cost", path.cost)
        put("duration", path.duration)
        put("distance", path.distance)
        put("walkingDistance", path.walkDistance)
        put("nightflag", path.isNightBus)
        put("segments", path.steps.orEmpty().take(32).map(::transitV2SegmentData))
    }

    private fun transitV2SegmentData(step: BusStepV2): Map<String, Any> = buildMap {
        step.walk?.let { walk ->
            put("walking", mapOf("distance" to walk.distance, "duration" to walk.duration, "polyline" to walk.polyline.orEmpty().map(::coordinateData)))
        }
        put("lines", step.busLines.orEmpty().take(8).map(::busLineData))
        step.entrance?.let { put("enterName", it.name ?: "") }
        step.exit?.let { put("exitName", it.name ?: "") }
    }

    private fun busLineData(line: RouteBusLineItem): Map<String, Any> = mapOf(
        "id" to (line.busLineId ?: ""),
        "name" to (line.busLineName ?: ""),
        "type" to (line.busLineType ?: ""),
        "distance" to line.distance,
        "duration" to line.duration,
        "totalPrice" to line.totalPrice,
        "polyline" to line.polyline.orEmpty().map(::coordinateData),
        "departureStop" to (line.departureBusStation?.busStationName ?: ""),
        "arrivalStop" to (line.arrivalBusStation?.busStationName ?: ""),
    )

    private fun coordinateData(point: LatLonPoint): Map<String, Double> = mapOf("latitude" to point.latitude, "longitude" to point.longitude)

    private fun hostContext(): Context = (mContext as? com.lynx.tasm.behavior.LynxContext)?.context ?: mContext

    private fun code(error: Throwable): Int = if (error is IllegalArgumentException) 1201 else 1206
}
