package com.example.lynxshell.debug

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.roundToInt

/** 半屏 Inspector 展示层；数据按 viewId 过滤，避免多个 Lynx 页面互相污染。 */
internal class LynxDebugPanelView(
    context: Context,
    private val onClose: () -> Unit,
) : LinearLayout(context) {
    private enum class Tab { CONSOLE, NETWORK, PROPS, METHODS }
    private data class PageItem(val viewId: String?, val label: String) {
        override fun toString(): String = label
    }

    private val store get() = LynxDebugTool.store()
    private val content = LinearLayout(context)
    private val pageSelector = TextView(context)
    private val tabButtons = mutableMapOf<Tab, TextView>()
    private var tab = Tab.CONSOLE
    private var viewId: String? = null
    private val timeFormat = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)

    init {
        orientation = VERTICAL
        content.orientation = VERTICAL
        setBackgroundColor(Color.rgb(248, 249, 252))
        setPadding(dp(16), dp(8), dp(16), dp(12))
        buildHeader()
        buildPageSelector()
        buildTabs()
        val scroll = ScrollView(context).apply {
            isFillViewport = true
            addView(content, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        }
        addView(scroll, LayoutParams(LayoutParams.MATCH_PARENT, 0).apply { weight = 1f })
        refreshPageSelector()
        refresh()
    }

    private fun buildHeader() {
        val handle = View(context).apply { setBackgroundColor(Color.rgb(190, 194, 202)) }
        addView(handle, LayoutParams(dp(40), dp(4)).apply {
            gravity = Gravity.CENTER_HORIZONTAL
            bottomMargin = dp(10)
        })
        val row = LinearLayout(context).apply { gravity = Gravity.CENTER_VERTICAL }
        row.addView(TextView(context).apply {
            text = "Lynx Debug Tool"
            textSize = 18f
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
            setTextColor(Color.rgb(25, 31, 42))
            setTypeface(typeface, Typeface.BOLD)
        }, LayoutParams(0, LayoutParams.WRAP_CONTENT).apply { weight = 1f })
        row.addView(toolbarButton("×") { onClose() })
        addView(row, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
    }

    private fun toolbarButton(label: String, action: () -> Unit): TextView = TextView(context).apply {
        text = label
        textSize = 12f
        gravity = Gravity.CENTER
        setTextColor(Color.rgb(0, 103, 225))
        background = rounded(Color.rgb(235, 242, 255), dp(10))
        setPadding(dp(10), dp(8), dp(10), dp(8))
        layoutParams = LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply {
            marginStart = dp(4)
        }
        setOnClickListener { action() }
    }

    private fun buildPageSelector() {
        addView(TextView(context).apply {
            text = "当前页面"
            textSize = 12f
            setTextColor(Color.rgb(100, 108, 123))
            setPadding(0, dp(10), 0, dp(2))
        })
        pageSelector.apply {
            textSize = 14f
            setTextColor(Color.rgb(25, 31, 42))
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(14), dp(12), dp(14), dp(12))
            background = rounded(Color.WHITE, dp(10))
            setOnClickListener { showPageChooser() }
        }
        addView(pageSelector, LayoutParams(LayoutParams.MATCH_PARENT, dp(48)))
    }

    private fun buildTabs() {
        val row = LinearLayout(context).apply { orientation = HORIZONTAL; setPadding(0, dp(10), 0, dp(8)) }
        addTab(row, Tab.CONSOLE, "Console")
        addTab(row, Tab.NETWORK, "Network")
        addTab(row, Tab.PROPS, "Props")
        addTab(row, Tab.METHODS, "Methods")
        addView(row, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
    }

    private fun addTab(parent: LinearLayout, value: Tab, label: String) {
        val button = TextView(context).apply {
            text = label
            textSize = 12f
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
            includeFontPadding = false
            gravity = Gravity.CENTER
            setPadding(dp(8), dp(10), dp(8), dp(10))
            setOnClickListener { tab = value; refresh() }
        }
        tabButtons[value] = button
        parent.addView(button, LayoutParams(0, LayoutParams.WRAP_CONTENT).apply { weight = 1f })
    }

    private fun refreshPageSelector() {
        val options = buildList {
            add(PageItem(null, "全部页面"))
            addAll(store.pageOptions().map { PageItem(it.viewId, it.label) })
        }
        val previous = viewId
        val index = options.indexOfFirst { it.viewId == previous }.takeIf { it >= 0 } ?: 0
        viewId = options[index].viewId
        pageSelector.text = "${options[index].label}  ›"
    }

    private fun showPageChooser() {
        val options = buildList {
            add(PageItem(null, "全部页面"))
            addAll(store.pageOptions().map { PageItem(it.viewId, it.label) })
        }
        val selected = options.indexOfFirst { it.viewId == viewId }.coerceAtLeast(0)
        MaterialAlertDialogBuilder(context)
            .setTitle("选择页面")
            .setSingleChoiceItems(options.map { it.label }.toTypedArray(), selected) { dialog, which ->
                viewId = options[which].viewId
                pageSelector.text = "${options[which].label}  ›"
                dialog.dismiss()
                refresh()
            }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun refresh() {
        tabButtons.forEach { (value, button) ->
            button.setTextColor(if (value == tab) Color.rgb(0, 103, 225) else Color.rgb(110, 118, 132))
            button.setBackgroundColor(if (value == tab) Color.rgb(225, 237, 255) else Color.TRANSPARENT)
        }
        content.removeAllViews()
        when (tab) {
            Tab.CONSOLE -> renderConsole()
            Tab.NETWORK -> renderNetwork()
            Tab.PROPS -> renderProps()
            Tab.METHODS -> renderMethods()
        }
    }

    private fun renderConsole() {
        addTabAction("清空 Console") { ConsoleLogStore.clear(); refresh() }
        val logs = ConsoleLogStore.snapshot(viewId).asReversed()
        if (logs.isEmpty()) {
            addEmpty("当前页面暂无 Console 日志")
            return
        }
        logs.forEach { log ->
            val color = when (log.type) {
                "error" -> Color.rgb(220, 65, 68)
                "warn" -> Color.rgb(190, 125, 0)
                else -> Color.rgb(42, 53, 70)
            }
            addCard(copyText = "${log.tag}\n${log.message}") {
                addRow("${timeFormat.format(Date(log.timestamp))}  ${log.type.uppercase(Locale.US)}", color, true)
                if (log.tag.isNotBlank()) addRow(log.tag, Color.rgb(100, 108, 123), false)
                addRow(log.message, Color.rgb(42, 53, 70), false)
            }
        }
    }

    private fun renderNetwork() {
        addTabAction("清空 Network") { NetworkRequestStore.clear(); refresh() }
        val requests = NetworkRequestStore.snapshot(viewId).asReversed()
        if (requests.isEmpty()) {
            addEmpty("当前页面暂无真实 HTTP 请求\n\n未关联页面的请求请切换到“全部页面”。")
            return
        }
        requests.forEach { request ->
            val status = request.statusCode?.toString() ?: if (request.error == null) "pending" else "ERR"
            val duration = request.endTimeMs?.let { "${it - request.startTimeMs}ms" } ?: "running"
            addCard(copyText = request.curl) {
                addRow("${request.method}  $status  $duration", if (request.error == null) Color.rgb(32, 145, 92) else Color.rgb(220, 65, 68), true)
                addRow(DebugRedactor.bundleUrl(request.url), Color.rgb(42, 53, 70), false)
                addRow("cURL", Color.rgb(0, 103, 225), true)
                addRow(request.curl, Color.rgb(70, 78, 92), false)
            }
        }
    }

    private fun renderProps() {
        val containers = store.containers(viewId)
        if (containers.isEmpty()) {
            addEmpty("当前页面暂无 GlobalProps")
            return
        }
        containers.forEach { snapshot ->
            addCard(copyText = JSONObject(snapshot.globalProps).toString()) {
                addRow("${snapshot.containerKind} · ${snapshot.routeKey}", Color.rgb(25, 31, 42), true)
                addRow("Bundle  ${DebugRedactor.bundleUrl(snapshot.bundleUrl)}", Color.rgb(80, 90, 108), false)
                addRow("viewId  ${snapshot.viewId}", Color.rgb(120, 128, 140), false)
                addSection("GlobalProps", snapshot.globalProps)
                val query = snapshot.globalProps["queryItems"] as? Map<*, *>
                if (query != null) addSection("queryItems", query.entries.associate { it.key.toString() to it.value })
            }
        }
    }

    private fun renderMethods() {
        val methods = store.methodSnapshot(viewId).asReversed()
        if (methods.isEmpty()) {
            addEmpty("当前页面暂无 Native Method 调用")
            return
        }
        methods.forEach { method ->
            val ok = method.success != false
            addCard(copyText = buildString {
                append(method.name).append("\n")
                append(method.params).append("\n")
                append(method.result.orEmpty())
            }) {
                addRow("${if (ok) "OK" else "ERR"}  ${method.name}", if (ok) Color.rgb(32, 145, 92) else Color.rgb(220, 65, 68), true)
                val duration = method.endTimeMs?.let { "${it - method.startTimeMs}ms" } ?: "running"
                addRow("code=${method.code ?: "-"} · ${duration} · view=${method.viewId?.take(8) ?: "unknown"}", Color.rgb(100, 108, 123), false)
                addSection("params", mapOf("value" to method.params.ifBlank { "(empty)" }))
                addSection("result", mapOf("value" to (method.result ?: "(pending)")))
            }
        }
    }

    private fun addEmpty(text: String) {
        content.addView(TextView(context).apply {
            this.text = text
            textSize = 14f
            setTextColor(Color.rgb(110, 118, 132))
            setPadding(dp(12), dp(24), dp(12), dp(24))
        })
    }

    private fun addTabAction(label: String, action: () -> Unit) {
        content.addView(TextView(context).apply {
            text = label
            textSize = 12f
            gravity = Gravity.CENTER_VERTICAL
            setTextColor(Color.rgb(0, 103, 225))
            background = rounded(Color.rgb(235, 242, 255), dp(10))
            setPadding(dp(12), dp(8), dp(12), dp(8))
            setOnClickListener { action() }
        }, LayoutParams(LayoutParams.WRAP_CONTENT, dp(36)).apply { bottomMargin = dp(8) })
    }

    private fun addCard(copyText: String? = null, block: LinearLayout.() -> Unit) {
        val card = LinearLayout(context).apply {
            orientation = VERTICAL
            setPadding(dp(14), dp(12), dp(14), dp(12))
            background = rounded(Color.WHITE, dp(12))
            if (copyText != null) {
                val copyRow = LinearLayout(context).apply { gravity = Gravity.END }
                copyRow.addView(TextView(context).apply {
                    text = "复制"
                    textSize = 11f
                    gravity = Gravity.CENTER
                    setTextColor(Color.rgb(0, 103, 225))
                    background = rounded(Color.rgb(235, 242, 255), dp(8))
                    setPadding(dp(10), dp(6), dp(10), dp(6))
                    setOnClickListener { copy(copyText) }
                })
                addView(copyRow, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
            }
            block()
        }
        content.addView(card, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(8) })
    }

    private fun copy(text: String) {
        val manager = context.getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
        manager.setPrimaryClip(android.content.ClipData.newPlainText("lynx-debug", text))
        android.widget.Toast.makeText(context, "已复制", android.widget.Toast.LENGTH_SHORT).show()
    }

    private fun LinearLayout.addRow(text: String, color: Int, bold: Boolean) {
        addView(TextView(context).apply {
            this.text = text
            textSize = if (bold) 13f else 12f
            setTextColor(color)
            if (bold) setTypeface(typeface, Typeface.BOLD)
            setPadding(0, dp(2), 0, dp(2))
        })
    }

    private fun LinearLayout.addSection(title: String, values: Map<String, Any?>) {
        addRow(title, Color.rgb(0, 103, 225), true)
        values.toSortedMap().forEach { (key, value) ->
            val row = LinearLayout(context).apply {
                orientation = HORIZONTAL
                setPadding(0, dp(2), 0, dp(2))
            }
            row.addView(TextView(context).apply {
                text = key
                textSize = 12f
                setTextColor(Color.rgb(70, 78, 92))
            }, LayoutParams(0, LayoutParams.WRAP_CONTENT).apply { weight = 0.38f })
            row.addView(TextView(context).apply {
                text = formatValue(value)
                textSize = 12f
                setTextColor(Color.rgb(42, 53, 70))
                maxLines = 4
                ellipsize = android.text.TextUtils.TruncateAt.END
            }, LayoutParams(0, LayoutParams.WRAP_CONTENT).apply { weight = 0.62f })
            addView(row)
        }
    }

    private fun formatValue(value: Any?): String = when (value) {
        null -> "null"
        is Map<*, *> -> "Object(${value.size})  " + JSONObject(value.entries.associate { it.key.toString() to it.value }).toString().take(600)
        is List<*> -> "Array(${value.size})  " + JSONArray(value).toString().take(600)
        else -> value.toString().replace('\n', ' ').take(1000)
    }

    private fun rounded(color: Int, radius: Int) = GradientDrawable().apply {
        setColor(color)
        cornerRadius = radius.toFloat()
        setStroke(dp(1), Color.rgb(232, 235, 241))
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).roundToInt()
}
