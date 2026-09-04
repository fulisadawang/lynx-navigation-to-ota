package com.example.lynxcapacitormodule

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.view.HapticFeedbackConstants
import android.view.View
import androidx.core.content.ContextCompat
import java.util.Locale
import org.json.JSONArray
import org.json.JSONObject

/** Android 原生 Haptics 能力；不把所有调用压成固定时长的短震动。 */
object NativeHapticsCapabilities {
    private const val PLUGIN_ID = "Haptics"
    private const val MAX_ONE_SHOT_MS = 10_000L
    private const val MAX_WAVEFORM_MS = 30_000L
    private const val DEFAULT_LONG_VIBRATION_MS = 1_500L
    private const val DEFAULT_WAVEFORM_ON_MS = 250L
    private const val DEFAULT_WAVEFORM_OFF_MS = 150L

    private data class PredefinedEffect(
        val name: String,
        val id: Int,
    )

    private val predefinedEffects = listOf(
        PredefinedEffect("TICK", VibrationEffect.EFFECT_TICK),
        PredefinedEffect("CLICK", VibrationEffect.EFFECT_CLICK),
        PredefinedEffect("HEAVY_CLICK", VibrationEffect.EFFECT_HEAVY_CLICK),
        PredefinedEffect("DOUBLE_CLICK", VibrationEffect.EFFECT_DOUBLE_CLICK),
    )

    /** 返回 null 表示交给其它能力域；Haptics 所属方法始终返回真实业务结果或结构化错误。 */
    fun dispatch(
        activity: Activity,
        pluginId: String,
        methodName: String,
        options: JSONObject,
    ): JSONObject? {
        if (pluginId != PLUGIN_ID) return null
        if (LooperGuard.isNotMainThread()) {
            return error("UI_THREAD_REQUIRED", "Haptics Android API 必须在主线程调用")
        }

        return runCatching {
            when (methodName) {
                "impact" -> performImpact(activity, options)
                "notification" -> performNotification(activity, options)
                "selection" -> performSelection(activity)
                "vibrate" -> vibrateOneShot(activity, options, "one-shot", 40L)
                "vibrateLong" -> vibrateOneShot(activity, options, "long", DEFAULT_LONG_VIBRATION_MS)
                "vibrateWaveform" -> vibrateWaveform(activity, options)
                "vibratePredefined" -> vibratePredefined(activity, options)
                "vibrateComposition" -> vibrateComposition(activity, options)
                "getCapabilities" -> getCapabilities(activity)
                "cancel" -> cancel(activity)
                else -> error("UNSUPPORTED", "Haptics.$methodName 尚未接入当前 Android Module")
            }
        }.getOrElse { throwable ->
            when (throwable) {
                is HapticsException -> error(throwable.code, throwable.message ?: "Haptics 参数无效")
                is SecurityException -> error("PERMISSION_DENIED", throwable.message ?: "没有振动权限")
                else -> error("NATIVE_ERROR", throwable.message ?: "Android Haptics 调用失败")
            }
        }
    }

    private fun performImpact(activity: Activity, options: JSONObject): JSONObject {
        val view = activity.window.decorView
        val style = options.optString("style", "MEDIUM").trim().uppercase(Locale.US)
        val constant = when (style) {
            "LIGHT" -> HapticFeedbackConstants.CLOCK_TICK
            "MEDIUM", "DEFAULT" -> HapticFeedbackConstants.CONTEXT_CLICK
            "HEAVY" -> HapticFeedbackConstants.LONG_PRESS
            else -> throw HapticsException("INVALID_ARGUMENT", "impact.style 只支持 LIGHT、MEDIUM、HEAVY")
        }
        return feedbackResult(activity, view, constant, "impact", style)
    }

    private fun performNotification(activity: Activity, options: JSONObject): JSONObject {
        val view = activity.window.decorView
        val type = options.optString("type", "SUCCESS").trim().uppercase(Locale.US)
        val constant = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            when (type) {
                "SUCCESS" -> HapticFeedbackConstants.CONFIRM
                "ERROR", "FAILURE" -> HapticFeedbackConstants.REJECT
                "WARNING" -> HapticFeedbackConstants.LONG_PRESS
                else -> throw HapticsException("INVALID_ARGUMENT", "notification.type 只支持 SUCCESS、WARNING、ERROR")
            }
        } else {
            when (type) {
                "SUCCESS", "WARNING", "ERROR", "FAILURE" -> HapticFeedbackConstants.LONG_PRESS
                else -> throw HapticsException("INVALID_ARGUMENT", "notification.type 只支持 SUCCESS、WARNING、ERROR")
            }
        }
        return feedbackResult(activity, view, constant, "notification", type)
    }

    private fun performSelection(activity: Activity): JSONObject = feedbackResult(
        activity = activity,
        view = activity.window.decorView,
        constant = HapticFeedbackConstants.KEYBOARD_TAP,
        mode = "selection",
        value = "KEYBOARD_TAP",
    )

    private fun feedbackResult(
        activity: Activity,
        view: View,
        constant: Int,
        mode: String,
        value: String,
    ): JSONObject {
        val vibrator = vibrator(activity)
        val performed = view.performHapticFeedback(constant)
        return JSONObject()
            .put("mode", mode)
            .put("value", value)
            .put("supported", vibrator?.hasVibrator() == true)
            .put("performed", performed)
            .put("permissionRequired", false)
    }

    private fun vibrateOneShot(
        activity: Activity,
        options: JSONObject,
        mode: String,
        defaultDurationMs: Long,
    ): JSONObject {
        val vibrator = requireVibrator(activity)
        val durationMs = positiveDuration(options.opt("duration"), defaultDurationMs, MAX_ONE_SHOT_MS, "duration")
        val amplitude = oneShotAmplitude(options.opt("amplitude"))
        val effect = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            VibrationEffect.createOneShot(durationMs, amplitude)
        } else {
            null
        }
        if (effect != null) {
            play(vibrator, effect, android.os.VibrationAttributes.USAGE_TOUCH)
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(durationMs)
        }
        return JSONObject()
            .put("mode", mode)
            .put("fired", true)
            .put("durationMs", durationMs)
            .put("amplitude", amplitude)
            .put("hasAmplitudeControl", vibrator.hasAmplitudeControl())
    }

    private fun vibrateWaveform(activity: Activity, options: JSONObject): JSONObject {
        val vibrator = requireVibrator(activity)
        val timings = parseTimings(options.optJSONArray("timings") ?: defaultWaveformTimings())
        val amplitudes = options.optJSONArray("amplitudes")?.let { parseAmplitudes(it, timings.size) }
        val repeat = parseRepeat(options.opt("repeat"), timings.size)
        val durationMs = timings.sum()
        if (repeat < 0 && durationMs > MAX_WAVEFORM_MS) {
            throw HapticsException("INVALID_ARGUMENT", "waveform 总时长不能超过 ${MAX_WAVEFORM_MS}ms")
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val effect = if (amplitudes == null) {
                VibrationEffect.createWaveform(timings, repeat)
            } else {
                VibrationEffect.createWaveform(timings, amplitudes, repeat)
            }
            play(vibrator, effect, android.os.VibrationAttributes.USAGE_TOUCH)
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(timings, repeat)
        }
        return JSONObject()
            .put("mode", "waveform")
            .put("fired", true)
            .put("timings", JSONArray(timings.toList()))
            .put("amplitudes", amplitudes?.let { JSONArray(it.toList()) } ?: JSONObject.NULL)
            .put("repeat", repeat)
            .put("durationMs", if (repeat >= 0) JSONObject.NULL else durationMs)
            .put("hasAmplitudeControl", vibrator.hasAmplitudeControl())
    }

    private fun vibratePredefined(activity: Activity, options: JSONObject): JSONObject {
        val vibrator = requireVibrator(activity)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return error("API_UNAVAILABLE", "预定义 VibrationEffect 需要 Android 10/API 29 或更高版本")
        }
        val selected = parsePredefined(options.opt("effectId"))
        val support = predefinedSupport(vibrator, selected.id)
        val effect = VibrationEffect.createPredefined(selected.id)
        play(vibrator, effect, android.os.VibrationAttributes.USAGE_TOUCH)
        return JSONObject()
            .put("mode", "predefined")
            .put("effect", selected.name)
            .put("effectId", selected.id)
            .put("support", support)
            .put("fired", true)
    }

    private fun vibrateComposition(activity: Activity, options: JSONObject): JSONObject {
        val vibrator = requireVibrator(activity)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return error("API_UNAVAILABLE", "VibrationEffect Composition 需要 Android 11/API 30 或更高版本")
        }
        val primitives = options.optJSONArray("primitives")
            ?: return error("INVALID_ARGUMENT", "primitives 不能为空")
        if (primitives.length() == 0 || primitives.length() > 32) {
            return error("INVALID_ARGUMENT", "primitives 数量必须在 1 到 32 之间")
        }

        val parsed = (0 until primitives.length()).map { index ->
            val item = primitives.optJSONObject(index)
                ?: throw HapticsException("INVALID_ARGUMENT", "primitives[$index] 必须是对象")
            val id = parsePrimitive(item.opt("id"))
            val scale = decimal(item.opt("scale"), 1.0, 0.0, 1.0, "primitives[$index].scale")
            val delay = nonNegativeInt(item.opt("delay"), 0, 10_000, "primitives[$index].delay")
            Triple(id, scale.toFloat(), delay)
        }
        val primitiveIds = parsed.map { it.first }.toIntArray()
        val supported = vibrator.arePrimitivesSupported(*primitiveIds)
        if (supported.any { !it }) {
            return error("UNSUPPORTED_PRIMITIVE", "当前设备不支持 composition 中的一个或多个 primitive")
                .put("supported", JSONArray(supported.toList()))
        }

        var composition = VibrationEffect.startComposition()
        parsed.forEach { (id, scale, delay) ->
            composition = if (delay == 0) {
                composition.addPrimitive(id, scale)
            } else {
                composition.addPrimitive(id, scale, delay)
            }
        }
        play(vibrator, composition.compose(), android.os.VibrationAttributes.USAGE_TOUCH)
        return JSONObject()
            .put("mode", "composition")
            .put("fired", true)
            .put("primitiveCount", parsed.size)
            .put("supported", JSONArray(supported.toList()))
    }

    private fun getCapabilities(activity: Activity): JSONObject {
        val vibrator = vibrator(activity)
            ?: return JSONObject()
                .put("supported", false)
                .put("hasVibrator", false)
                .put("hasAmplitudeControl", false)
                .put("apiLevel", Build.VERSION.SDK_INT)
        val effects = JSONArray().apply {
            predefinedEffects.forEach { effect ->
                put(
                    JSONObject()
                        .put("name", effect.name)
                        .put("id", effect.id)
                        .put("support", predefinedSupport(vibrator, effect.id)),
                )
            }
        }
        val capabilities = JSONObject()
            .put("supported", vibrator.hasVibrator())
            .put("hasVibrator", vibrator.hasVibrator())
            .put("hasAmplitudeControl", vibrator.hasAmplitudeControl())
            .put("permissionGranted", hasVibratePermission(activity))
            .put("apiLevel", Build.VERSION.SDK_INT)
            .put("predefinedEffects", effects)
            .put("composition", JSONObject().put("available", Build.VERSION.SDK_INT >= Build.VERSION_CODES.R))
        if (Build.VERSION.SDK_INT >= 36) {
            capabilities.put("envelopeEffects", vibrator.areEnvelopeEffectsSupported())
        } else {
            capabilities.put("envelopeEffects", JSONObject.NULL)
        }
        return capabilities
    }

    private fun cancel(activity: Activity): JSONObject {
        val vibrator = vibrator(activity) ?: return JSONObject().put("cancelled", false).put("supported", false)
        vibrator.cancel()
        return JSONObject().put("cancelled", true).put("supported", vibrator.hasVibrator())
    }

    @Suppress("NewApi")
    private fun play(vibrator: Vibrator, effect: VibrationEffect, usage: Int) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val attributes = android.os.VibrationAttributes.Builder().setUsage(usage).build()
            vibrator.vibrate(effect, attributes)
        } else {
            vibrator.vibrate(effect)
        }
    }

    private fun requireVibrator(activity: Activity): Vibrator {
        if (!hasVibratePermission(activity)) {
            throw HapticsException("PERMISSION_DENIED", "宿主 Manifest 未授予 android.permission.VIBRATE")
        }
        return vibrator(activity)?.takeIf { it.hasVibrator() }
            ?: throw HapticsException("NO_PROVIDER", "当前 Android 设备没有可用的振动器")
    }

    private fun vibrator(activity: Activity): Vibrator? =
        activity.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator

    private fun hasVibratePermission(activity: Activity): Boolean =
        ContextCompat.checkSelfPermission(activity, Manifest.permission.VIBRATE) == PackageManager.PERMISSION_GRANTED

    private fun predefinedSupport(vibrator: Vibrator, effectId: Int): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return "unknown"
        return when (vibrator.areEffectsSupported(effectId).firstOrNull()) {
            Vibrator.VIBRATION_EFFECT_SUPPORT_YES -> "yes"
            Vibrator.VIBRATION_EFFECT_SUPPORT_NO -> "no"
            else -> "unknown"
        }
    }

    private fun parsePredefined(raw: Any?): PredefinedEffect {
        val value = when (raw) {
            null, JSONObject.NULL -> VibrationEffect.EFFECT_CLICK
            is Number -> raw.toDouble().takeIf { it.isFinite() && it % 1.0 == 0.0 }?.toInt()
            is String -> raw.trim().uppercase(Locale.US).toIntOrNull() ?: predefinedEffects
                .firstOrNull { it.name == raw.trim().uppercase(Locale.US) }
                ?.id
            else -> null
        } ?: throw HapticsException("INVALID_ARGUMENT", "effectId 必须是 TICK、CLICK、HEAVY_CLICK、DOUBLE_CLICK 或整数")
        return predefinedEffects.firstOrNull { it.id == value }
            ?: throw HapticsException("INVALID_ARGUMENT", "effectId 不是受支持的 Android 预定义效果")
    }

    private fun parsePrimitive(raw: Any?): Int = when (raw) {
        is Number -> raw.toDouble().takeIf { it.isFinite() && it % 1.0 == 0.0 }?.toInt()
        is String -> when (raw.trim().uppercase(Locale.US)) {
            "CLICK" -> VibrationEffect.Composition.PRIMITIVE_CLICK
            "THUD" -> VibrationEffect.Composition.PRIMITIVE_THUD
            "SPIN" -> VibrationEffect.Composition.PRIMITIVE_SPIN
            "QUICK_RISE" -> VibrationEffect.Composition.PRIMITIVE_QUICK_RISE
            "SLOW_RISE" -> VibrationEffect.Composition.PRIMITIVE_SLOW_RISE
            "QUICK_FALL" -> VibrationEffect.Composition.PRIMITIVE_QUICK_FALL
            "TICK" -> VibrationEffect.Composition.PRIMITIVE_TICK
            "LOW_TICK" -> VibrationEffect.Composition.PRIMITIVE_LOW_TICK
            else -> raw.trim().toIntOrNull()
        }
        else -> null
    } ?: throw HapticsException("INVALID_ARGUMENT", "primitive id 无效")

    private fun parseTimings(array: JSONArray): LongArray {
        if (array.length() == 0 || array.length() > 64) {
            throw HapticsException("INVALID_ARGUMENT", "timings 数量必须在 1 到 64 之间")
        }
        return LongArray(array.length()) { index ->
            nonNegativeLong(array.opt(index), 0L, MAX_WAVEFORM_MS, "timings[$index]")
        }
    }

    private fun parseAmplitudes(array: JSONArray, expectedLength: Int): IntArray {
        if (array.length() != expectedLength) {
            throw HapticsException("INVALID_ARGUMENT", "amplitudes 长度必须与 timings 相同")
        }
        return IntArray(array.length()) { index ->
            val value = numberAsDouble(array.opt(index))
                ?.takeIf { it.isFinite() && it % 1.0 == 0.0 }
                ?.toInt()
                ?: throw HapticsException("INVALID_ARGUMENT", "amplitudes[$index] 必须是整数")
            if (value != VibrationEffect.DEFAULT_AMPLITUDE && value !in 0..255) {
                throw HapticsException("INVALID_ARGUMENT", "amplitudes[$index] 必须在 0 到 255 或 DEFAULT_AMPLITUDE")
            }
            value
        }
    }

    private fun parseRepeat(raw: Any?, length: Int): Int {
        val repeat = if (raw == null || raw === JSONObject.NULL) -1 else {
            numberAsDouble(raw)?.takeIf { it.isFinite() && it % 1.0 == 0.0 }?.toInt()
                ?: throw HapticsException("INVALID_ARGUMENT", "repeat 必须是整数")
        }
        if (repeat != -1 && repeat !in 0 until length) {
            throw HapticsException("INVALID_ARGUMENT", "repeat 必须是 -1 或 timings 的有效下标")
        }
        return repeat
    }

    private fun positiveDuration(raw: Any?, fallback: Long, max: Long, field: String): Long =
        nonNegativeLong(raw, fallback, max, field).takeIf { it > 0L }
            ?: throw HapticsException("INVALID_ARGUMENT", "$field 必须大于 0")

    private fun oneShotAmplitude(raw: Any?): Int {
        if (raw == null || raw === JSONObject.NULL) return VibrationEffect.DEFAULT_AMPLITUDE
        val value = numberAsDouble(raw)?.takeIf { it.isFinite() && it % 1.0 == 0.0 }?.toInt()
            ?: throw HapticsException("INVALID_ARGUMENT", "amplitude 必须是整数")
        if (value != VibrationEffect.DEFAULT_AMPLITUDE && value !in 1..255) {
            throw HapticsException("INVALID_ARGUMENT", "amplitude 必须在 1 到 255 或 DEFAULT_AMPLITUDE")
        }
        return value
    }

    private fun decimal(raw: Any?, fallback: Double, min: Double, max: Double, field: String): Double {
        val value = if (raw == null || raw === JSONObject.NULL) fallback else numberAsDouble(raw)
            ?: throw HapticsException("INVALID_ARGUMENT", "$field 必须是数字")
        if (!value.isFinite() || value !in min..max) {
            throw HapticsException("INVALID_ARGUMENT", "$field 必须在 $min 到 $max 之间")
        }
        return value
    }

    private fun nonNegativeLong(raw: Any?, fallback: Long, max: Long, field: String): Long {
        val value = if (raw == null || raw === JSONObject.NULL) fallback else numberAsDouble(raw)
            ?.takeIf { it.isFinite() && it % 1.0 == 0.0 }
            ?.toLong()
            ?: throw HapticsException("INVALID_ARGUMENT", "$field 必须是整数")
        if (value !in 0L..max) throw HapticsException("INVALID_ARGUMENT", "$field 必须在 0 到 $max 之间")
        return value
    }

    private fun nonNegativeInt(raw: Any?, fallback: Int, max: Int, field: String): Int =
        nonNegativeLong(raw, fallback.toLong(), max.toLong(), field).toInt()

    private fun numberAsDouble(value: Any?): Double? = when (value) {
        is Number -> value.toDouble()
        is String -> value.trim().toDoubleOrNull()
        else -> null
    }

    private fun defaultWaveformTimings(): JSONArray = JSONArray()
        .put(0L)
        .put(DEFAULT_WAVEFORM_ON_MS)
        .put(DEFAULT_WAVEFORM_OFF_MS)
        .put(DEFAULT_WAVEFORM_ON_MS)

    private fun error(code: String, message: String): JSONObject = JSONObject()
        .put("error", JSONObject().put("code", code).put("message", message))

    private class HapticsException(val code: String, message: String) : Exception(message)

    private object LooperGuard {
        fun isNotMainThread(): Boolean = android.os.Looper.myLooper() != android.os.Looper.getMainLooper()
    }
}
