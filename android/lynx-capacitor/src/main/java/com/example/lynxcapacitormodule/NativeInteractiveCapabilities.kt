package com.example.lynxcapacitormodule

import android.app.Activity
import android.app.AlertDialog
import android.os.Looper
import android.text.InputType
import android.widget.EditText
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONArray
import org.json.JSONObject

/** 使用 Android framework 提供 Dialog 和 ActionSheet，不依赖 Capacitor。 */
object NativeInteractiveCapabilities {
    private const val DIALOG = "Dialog"
    private const val ACTION_SHEET = "ActionSheet"

    /**
     * 接管交互能力请求。
     *
     * 返回 true 表示 pluginId 已由本能力接管；用户操作完成前不会同步调用 complete。
     * 其它 pluginId 返回 false，调用方可以继续交给其它能力域处理。
     */
    fun dispatch(
        activity: Activity,
        pluginId: String,
        methodName: String,
        options: JSONObject,
        complete: (JSONObject) -> Unit,
    ): Boolean {
        if (pluginId != DIALOG && pluginId != ACTION_SHEET) return false

        val completion = CompletionOnce(complete)
        val show = Runnable {
            if (!isActivityUsable(activity)) {
                completion.invoke(error("ACTIVITY_UNAVAILABLE", "Activity 已销毁或正在结束"))
                return@Runnable
            }

            runCatching {
                when (pluginId) {
                    DIALOG -> dispatchDialog(activity, methodName, options, completion)
                    ACTION_SHEET -> dispatchActionSheet(activity, methodName, options, completion)
                }
            }.onFailure { error ->
                completion.invoke(error("NATIVE_ERROR", error.message ?: "创建 Android 交互界面失败"))
            }
        }

        if (Looper.myLooper() == Looper.getMainLooper()) {
            show.run()
        } else {
            runCatching { activity.runOnUiThread(show) }
                .onFailure { error ->
                    completion.invoke(error("UI_THREAD_UNAVAILABLE", error.message ?: "无法切换到 Android 主线程"))
                }
        }
        return true
    }

    private fun dispatchDialog(
        activity: Activity,
        methodName: String,
        options: JSONObject,
        completion: CompletionOnce,
    ) {
        when (methodName) {
            "alert" -> showAlert(activity, options, completion)
            "confirm" -> showConfirm(activity, options, completion)
            "prompt" -> showPrompt(activity, options, completion)
            else -> completion.invoke(error("UNSUPPORTED", "Dialog.$methodName 尚未接入当前 Android Module"))
        }
    }

    private fun showAlert(
        activity: Activity,
        options: JSONObject,
        completion: CompletionOnce,
    ) {
        val cancelled = { completion.invoke(JSONObject().put("confirmed", false)) }
        AlertDialog.Builder(activity)
            .applyCommonText(options)
            .setPositiveButton(options.optString("buttonTitle", "OK")) { _, _ ->
                completion.invoke(JSONObject().put("confirmed", true))
            }
            .setOnCancelListener { cancelled() }
            // Activity 因生命周期结束而 dismiss 时未必经过 onCancel，作为兜底仍返回一次取消结果。
            .setOnDismissListener { cancelled() }
            .show()
    }

    private fun showConfirm(
        activity: Activity,
        options: JSONObject,
        completion: CompletionOnce,
    ) {
        val cancelled = { completion.invoke(JSONObject().put("value", false)) }
        AlertDialog.Builder(activity)
            .applyCommonText(options)
            .setPositiveButton(options.optString("okButtonTitle", "OK")) { _, _ ->
                completion.invoke(JSONObject().put("value", true))
            }
            .setNegativeButton(options.optString("cancelButtonTitle", "Cancel")) { _, _ ->
                completion.invoke(JSONObject().put("value", false))
            }
            .setOnCancelListener { cancelled() }
            .setOnDismissListener { cancelled() }
            .show()
    }

    private fun showPrompt(
        activity: Activity,
        options: JSONObject,
        completion: CompletionOnce,
    ) {
        val input = EditText(activity).apply {
            setText(options.optString("inputText", ""))
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            options.optString("inputPlaceholder", "").takeIf(String::isNotEmpty)?.let { hint = it }
        }
        val cancelled = {
            completion.invoke(
                JSONObject()
                    .put("value", "")
                    .put("cancelled", true),
            )
        }
        AlertDialog.Builder(activity)
            .applyCommonText(options)
            .setView(input)
            .setPositiveButton(options.optString("okButtonTitle", "OK")) { _, _ ->
                completion.invoke(
                    JSONObject()
                        .put("value", input.text?.toString().orEmpty())
                        .put("cancelled", false),
                )
            }
            .setNegativeButton(options.optString("cancelButtonTitle", "Cancel")) { _, _ ->
                cancelled()
            }
            .setOnCancelListener { cancelled() }
            .setOnDismissListener { cancelled() }
            .show()
    }

    private fun dispatchActionSheet(
        activity: Activity,
        methodName: String,
        options: JSONObject,
        completion: CompletionOnce,
    ) {
        if (methodName != "showActions") {
            completion.invoke(error("UNSUPPORTED", "ActionSheet.$methodName 尚未接入当前 Android Module"))
            return
        }

        val titles = actionTitles(options)
        if (titles == null) {
            completion.invoke(error("INVALID_ARGUMENT", "ActionSheet.options 必须包含至少一个带 title 的选项"))
            return
        }

        val cancelled = {
            completion.invoke(JSONObject().put("index", -1).put("cancelled", true))
        }
        AlertDialog.Builder(activity)
            .applyCommonText(options)
            .setItems(titles.toTypedArray()) { _, index ->
                completion.invoke(JSONObject().put("index", index).put("cancelled", false))
            }
            .setOnCancelListener { cancelled() }
            .setOnDismissListener { cancelled() }
            .show()
    }

    private fun actionTitles(options: JSONObject): List<String>? {
        val values: JSONArray = options.optJSONArray("options") ?: return null
        if (values.length() == 0) return null

        val titles = ArrayList<String>(values.length())
        for (index in 0 until values.length()) {
            val option = values.optJSONObject(index) ?: return null
            val title = option.optString("title", "")
            if (title.isEmpty()) return null
            titles += title
        }
        return titles
    }

    private fun AlertDialog.Builder.applyCommonText(options: JSONObject): AlertDialog.Builder = apply {
        options.optString("title", "").takeIf(String::isNotEmpty)?.let { setTitle(it) }
        options.optString("message", "").takeIf(String::isNotEmpty)?.let { setMessage(it) }
    }

    private fun isActivityUsable(activity: Activity): Boolean =
        !activity.isFinishing && !activity.isDestroyed

    private fun error(code: String, message: String): JSONObject = JSONObject()
        .put("error", JSONObject().put("code", code).put("message", message))

    /** 防止按钮、遮罩、返回键和 Activity dismiss 路径重复交付结果。 */
    private class CompletionOnce(private val complete: (JSONObject) -> Unit) {
        private val completed = AtomicBoolean(false)

        fun invoke(result: JSONObject) {
            if (!completed.compareAndSet(false, true)) return
            runCatching { complete(result) }
        }
    }
}
