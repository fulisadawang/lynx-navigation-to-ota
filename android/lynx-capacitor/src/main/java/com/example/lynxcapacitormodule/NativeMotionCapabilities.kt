package com.example.lynxcapacitormodule

import android.app.Activity
import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import java.util.Locale
import java.util.UUID
import java.util.WeakHashMap
import org.json.JSONObject

/**
 * Android 自有的 Motion 能力。
 *
 * 这里直接使用 SensorManager，不继承 Capacitor 类，也不创建 Capacitor Bridge。一个 Activity
 * 对应一份传感器状态；监听器在 stop 时保留，便于宿主在恢复生命周期后调用 start 重新注册。
 */
object NativeMotionCapabilities {
    private const val PLUGIN_ID = "Motion"
    private const val DEFAULT_SAMPLING_PERIOD_US = 20_000
    private const val EVENT_ACCEL = "accel"
    private const val EVENT_ORIENTATION = "orientation"

    private val states = WeakHashMap<Activity, MotionState>()

    /** 安装或更新指定 Activity 的事件发送器，但不在没有监听器时注册传感器。 */
    @Synchronized
    fun install(activity: Activity, eventSender: (String) -> Unit) {
        val existing = states[activity]
        if (existing == null) {
            val sensorManager = activity.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
            states[activity] = MotionState(sensorManager, eventSender)
        } else {
            existing.updateEventSender(eventSender)
        }
    }

    /** 解除 Activity 的传感器注册并清理其所有监听器。 */
    fun detach(activity: Activity) {
        val state = synchronized(this) { states.remove(activity) }
        state?.detach()
    }

    /**
     * 处理 Motion 业务方法。
     *
     * 返回值是能力自身的业务对象；事件结果通过 eventSender 发送完整 JSON envelope。未安装
     * 的 Activity、未知方法和非法监听事件均返回结构化错误，不伪造成功结果。
     */
    fun dispatch(activity: Activity, methodName: String, options: JSONObject): JSONObject? {
        val state = synchronized(this) { states[activity] }
            ?: return failure("NOT_INSTALLED", "Motion 尚未为当前 Activity 安装")

        return when (methodName) {
            "addListener" -> state.addListener(options)
            "removeListener" -> state.removeListener(options)
            "removeAllListeners" -> state.removeAllListeners()
            "start" -> state.start()
            "stop" -> state.stop()
            else -> failure("UNSUPPORTED", "Motion.$methodName 尚未接入当前 Android Module")
        }
    }

    /** 恢复指定 Activity 的全部已保存监听器。可由宿主的 onResume 后续接线调用。 */
    fun start(activity: Activity): JSONObject = synchronized(this) { states[activity] }
        ?.start()
        ?: failure("NOT_INSTALLED", "Motion 尚未为当前 Activity 安装")

    /** 暂停指定 Activity 的传感器回调，但保留监听器，便于后续恢复。 */
    fun stop(activity: Activity): JSONObject = synchronized(this) { states[activity] }
        ?.stop()
        ?: failure("NOT_INSTALLED", "Motion 尚未为当前 Activity 安装")

    private class MotionState(
        private val sensorManager: SensorManager?,
        private var eventSender: (String) -> Unit,
    ) : SensorEventListener {
        private val listeners = LinkedHashMap<String, Listener>()
        private val registeredSensorTypes = mutableSetOf<Int>()
        private var started = false
        private var lastAccelerationTimestampNanos = 0L
        private var lastLinearAccelerationTimestampNanos = 0L
        private var lastGyroscopeTimestampNanos = 0L
        private var latestGravity: FloatArray? = null
        private var latestLinearAcceleration: FloatArray? = null

        @Synchronized
        fun updateEventSender(eventSender: (String) -> Unit) {
            this.eventSender = eventSender
        }

        @Synchronized
        fun addListener(options: JSONObject): JSONObject {
            val eventName = options.optString("eventName").trim().lowercase(Locale.US)
            if (eventName !in setOf(EVENT_ACCEL, EVENT_ORIENTATION)) {
                return failure("UNSUPPORTED", "Motion.addListener 只支持 accel 或 orientation")
            }

            val sensor = sensorFor(eventName)
                ?: return failure("UNSUPPORTED", "当前设备不支持 Motion.$eventName 所需传感器")

            val listenerId = listenerId(options)
            val previous = listeners.put(listenerId, Listener(listenerId, eventName))
            val startResult = startLocked(sensor)
            if (startResult != null) {
                if (previous == null) {
                    listeners.remove(listenerId)
                } else {
                    listeners[listenerId] = previous
                }
                if (listeners.isEmpty()) stopLocked()
                return startResult
            }

            return JSONObject()
                .put("listenerId", listenerId)
                .put("eventName", eventName)
                .put("save", true)
                .put("pending", true)
        }

        @Synchronized
        fun removeListener(options: JSONObject): JSONObject {
            val listenerId = options.optString("listenerId").trim()
                .ifEmpty { options.optString("callbackId").trim() }
            if (listenerId.isEmpty()) {
                return failure("INVALID_ARGUMENT", "Motion.removeListener 需要 listenerId")
            }

            val removed = listeners.remove(listenerId) != null
            if (listeners.isEmpty()) stopLocked()
            return JSONObject()
                .put("listenerId", listenerId)
                .put("removed", removed)
                .put("save", false)
                .put("pending", false)
        }

        @Synchronized
        fun removeAllListeners(): JSONObject {
            val removed = listeners.size
            listeners.clear()
            stopLocked()
            return JSONObject()
                .put("removed", removed)
                .put("save", false)
                .put("pending", false)
        }

        @Synchronized
        fun start(): JSONObject {
            if (listeners.isEmpty()) {
                return JSONObject().put("started", false).put("listenerCount", 0)
            }
            if (started) {
                return JSONObject().put("started", true).put("listenerCount", listeners.size)
            }

            val requiredSensors = listeners.values
                .flatMap { sensorsFor(it.eventName) }
                .distinctBy { it.type }
            val registrationError = requiredSensors.firstNotNullOfOrNull { sensor ->
                if (sensorManager?.registerListener(
                        this,
                        sensor,
                        DEFAULT_SAMPLING_PERIOD_US,
                ) == true
                ) {
                    registeredSensorTypes += sensor.type
                    null
                } else {
                    failure("UNSUPPORTED", "无法注册当前设备的 ${sensorName(sensor)} 传感器")
                }
            }
            if (registrationError != null) {
                sensorManager?.unregisterListener(this)
                registeredSensorTypes.clear()
                started = false
                return registrationError
            }

            started = true
            return JSONObject().put("started", true).put("listenerCount", listeners.size)
        }

        @Synchronized
        fun stop(): JSONObject {
            stopLocked()
            return JSONObject().put("stopped", true).put("listenerCount", listeners.size)
        }

        @Synchronized
        fun detach() {
            stopLocked()
            listeners.clear()
        }

        override fun onSensorChanged(event: SensorEvent) {
            val envelopes = synchronized(this) {
                if (!started) return@synchronized emptyList<String>()

                val eventName = when (event.sensor.type) {
                    Sensor.TYPE_ACCELEROMETER,
                    Sensor.TYPE_LINEAR_ACCELERATION,
                    -> EVENT_ACCEL
                    Sensor.TYPE_GYROSCOPE -> EVENT_ORIENTATION
                    else -> return@synchronized emptyList()
                }
                val matchingListeners = listeners.values.filter { it.eventName == eventName }
                if (matchingListeners.isEmpty()) return@synchronized emptyList()

                val interval = intervalMillis(event)
                matchingListeners.map { listener ->
                    eventEnvelope(
                        listener = listener,
                        data = when (eventName) {
                            EVENT_ACCEL -> accelerationData(event.values, interval, event.sensor.type)
                            EVENT_ORIENTATION -> orientationData(event.values, interval)
                            else -> JSONObject()
                        },
                    ).toString()
                }
            }

            envelopes.forEach { envelope ->
                val sender = synchronized(this) { eventSender }
                runCatching { sender(envelope) }
            }
        }

        override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

        private fun startLocked(sensor: Sensor): JSONObject? {
            if (started && sensor.type in registeredSensorTypes) return null
            if (started) stopLocked()
            val result = start()
            return if (result.optBoolean("started", false)) {
                null
            } else {
                result.takeIf { result.has("error") }
                    ?: failure("UNSUPPORTED", "无法注册 ${sensorName(sensor)} 传感器")
            }
        }

        private fun stopLocked() {
            if (started) sensorManager?.unregisterListener(this)
            registeredSensorTypes.clear()
            started = false
            lastAccelerationTimestampNanos = 0L
            lastLinearAccelerationTimestampNanos = 0L
            lastGyroscopeTimestampNanos = 0L
            latestGravity = null
            latestLinearAcceleration = null
        }

        private fun sensorFor(eventName: String): Sensor? = when (eventName) {
            EVENT_ACCEL -> sensorsFor(EVENT_ACCEL).firstOrNull()
            EVENT_ORIENTATION -> sensorManager?.getDefaultSensor(Sensor.TYPE_GYROSCOPE)
            else -> null
        }

        private fun sensorsFor(eventName: String): List<Sensor> = when (eventName) {
            EVENT_ACCEL -> listOfNotNull(
                sensorManager?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER),
                sensorManager?.getDefaultSensor(Sensor.TYPE_LINEAR_ACCELERATION),
            )
            EVENT_ORIENTATION -> listOfNotNull(sensorManager?.getDefaultSensor(Sensor.TYPE_GYROSCOPE))
            else -> emptyList()
        }

        private fun intervalMillis(event: SensorEvent): Long {
            val lastTimestamp = when (event.sensor.type) {
                Sensor.TYPE_ACCELEROMETER -> lastAccelerationTimestampNanos
                Sensor.TYPE_LINEAR_ACCELERATION -> lastLinearAccelerationTimestampNanos
                Sensor.TYPE_GYROSCOPE -> lastGyroscopeTimestampNanos
                else -> 0L
            }
            when (event.sensor.type) {
                Sensor.TYPE_ACCELEROMETER -> lastAccelerationTimestampNanos = event.timestamp
                Sensor.TYPE_LINEAR_ACCELERATION -> lastLinearAccelerationTimestampNanos = event.timestamp
                Sensor.TYPE_GYROSCOPE -> lastGyroscopeTimestampNanos = event.timestamp
            }
            return if (lastTimestamp == 0L || event.timestamp <= lastTimestamp) {
                0L
            } else {
                (event.timestamp - lastTimestamp) / 1_000_000L
            }
        }

        private fun eventEnvelope(listener: Listener, data: JSONObject): JSONObject = JSONObject()
            .put("callbackId", listener.listenerId)
            .put("pluginId", PLUGIN_ID)
            .put("methodName", "addListener")
            .put("eventName", listener.eventName)
            .put("listenerId", listener.listenerId)
            .put("success", true)
            .put("data", data)
            .put("save", true)
            .put("pending", false)

        private fun accelerationData(values: FloatArray, interval: Long, sensorType: Int): JSONObject {
            if (sensorType == Sensor.TYPE_LINEAR_ACCELERATION) {
                latestLinearAcceleration = values.copyOf()
            } else if (sensorType == Sensor.TYPE_ACCELEROMETER) {
                latestGravity = values.copyOf()
            }
            return JSONObject()
                .put(
                    "acceleration",
                    latestLinearAcceleration?.let { vector(it, "x", "y", "z") } ?: JSONObject.NULL,
                )
                .put(
                    "accelerationIncludingGravity",
                    latestGravity?.let { vector(it, "x", "y", "z") } ?: JSONObject.NULL,
                )
                .put("rotationRate", JSONObject.NULL)
                .put("interval", interval)
        }

        private fun orientationData(values: FloatArray, interval: Long): JSONObject = JSONObject()
            // 陀螺仪提供的是角速度，不是依赖磁力计/旋转矢量才能得到的绝对姿态角。
            .put(
                "rotationRate",
                vector(values, "alpha", "beta", "gamma"),
            )
            .put("interval", interval)

        private fun vector(values: FloatArray, first: String, second: String, third: String): JSONObject =
            JSONObject()
                .put(first, values.getOrElse(0) { 0f }.toDouble())
                .put(second, values.getOrElse(1) { 0f }.toDouble())
                .put(third, values.getOrElse(2) { 0f }.toDouble())

        private fun sensorName(sensor: Sensor): String = when (sensor.type) {
            Sensor.TYPE_ACCELEROMETER -> "加速度计"
            Sensor.TYPE_LINEAR_ACCELERATION -> "线性加速度计"
            Sensor.TYPE_GYROSCOPE -> "陀螺仪"
            else -> "Motion"
        }
    }

    private data class Listener(
        val listenerId: String,
        val eventName: String,
    )

    private fun listenerId(options: JSONObject): String = options.optString("listenerId").trim()
        .ifEmpty { options.optString("callbackId").trim() }
        .ifEmpty { "motion-${UUID.randomUUID()}" }

    private fun failure(code: String, message: String): JSONObject = JSONObject()
        .put(
            "error",
            JSONObject()
                .put("code", code)
                .put("message", message),
        )
        .put("success", false)
}
