package com.example.lynxshell.debug

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** 先选页面，再看该页面自己的 Console / GlobalProps / Native Method。 */
class LynxDebugActivity : Activity() {
    private enum class Tab { CONSOLE, GLOBAL_PROPS, METHODS }
    private data class PageItem(val viewId: String?, val label: String) {
        override fun toString(): String = label
    }

    private lateinit var pageSelector: Spinner
    private lateinit var output: TextView
    private var selectedTab = Tab.CONSOLE
    private var selectedViewId: String? = null
    private val timeFormat = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)
    private val consoleListener = object : ConsoleLogStore.Listener {
        override fun onChanged() { runOnUiThread { if (selectedTab == Tab.CONSOLE) refresh() } }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = "Lynx Debug Tool"

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.WHITE)
            setPadding(12, 12, 12, 12)
        }
        val actions = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        actions.addView(Button(this).apply {
            text = "刷新"
            setOnClickListener { refreshPageSelector(); refresh() }
        })
        actions.addView(Button(this).apply {
            text = "清空"
            setOnClickListener {
                ConsoleLogStore.clear()
                LynxDebugTool.store().clear()
                refresh()
            }
        })
        root.addView(actions, LinearLayout.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)

        pageSelector = Spinner(this)
        pageSelector.onItemSelectedListener = object : android.widget.AdapterView.OnItemSelectedListener {
            override fun onItemSelected(parent: android.widget.AdapterView<*>?, view: android.view.View?, position: Int, id: Long) {
                selectedViewId = (pageSelector.selectedItem as? PageItem)?.viewId
                refresh()
            }

            override fun onNothingSelected(parent: android.widget.AdapterView<*>?) = Unit
        }
        root.addView(pageSelector, LinearLayout.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)

        val tabs = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        tabs.addView(tabButton("Console") { selectTab(Tab.CONSOLE) }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        tabs.addView(tabButton("GlobalProps") { selectTab(Tab.GLOBAL_PROPS) }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        tabs.addView(tabButton("Native Method") { selectTab(Tab.METHODS) }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        root.addView(tabs)

        output = TextView(this).apply {
            textSize = 12f
            setTextColor(Color.DKGRAY)
            setTextIsSelectable(true)
            typeface = android.graphics.Typeface.MONOSPACE
            gravity = Gravity.TOP or Gravity.START
        }
        root.addView(
            ScrollView(this).apply { addView(output) },
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0).apply { weight = 1f },
        )
        setContentView(root)
        refreshPageSelector()
        selectTab(Tab.CONSOLE)
    }

    override fun onStart() {
        super.onStart()
        ConsoleLogStore.addListener(consoleListener)
        refreshPageSelector()
        refresh()
    }

    override fun onStop() {
        ConsoleLogStore.removeListener(consoleListener)
        super.onStop()
    }

    private fun tabButton(label: String, onClick: () -> Unit): Button = Button(this).apply {
        text = label
        textSize = 11f
        setOnClickListener { onClick() }
    }

    private fun selectTab(tab: Tab) {
        selectedTab = tab
        refresh()
    }

    private fun refreshPageSelector() {
        if (!::pageSelector.isInitialized) return
        val options = buildList {
            add(PageItem(null, "全部页面"))
            addAll(LynxDebugTool.store().pageOptions().map { PageItem(it.viewId, it.label) })
        }
        val previous = selectedViewId
        pageSelector.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, options)
        val index = options.indexOfFirst { it.viewId == previous }.takeIf { it >= 0 } ?: 0
        pageSelector.setSelection(index, false)
        selectedViewId = options[index].viewId
    }

    private fun refresh() {
        if (!::output.isInitialized) return
        output.text = when (selectedTab) {
            Tab.CONSOLE -> renderConsole()
            Tab.GLOBAL_PROPS -> LynxDebugTool.store().containersJson(selectedViewId)
            Tab.METHODS -> LynxDebugTool.store().methodsText(selectedViewId)
        }
    }

    private fun renderConsole(): String {
        val logs = ConsoleLogStore.snapshot(selectedViewId).asReversed()
        if (logs.isEmpty()) {
            return "暂无当前页面 Console 日志\n\n提示：选择“全部页面”可查看未关联日志。"
        }
        return logs.joinToString("\n\n") { log ->
            val time = timeFormat.format(Date(log.timestamp))
            "[$time] [${log.type.uppercase(Locale.US)}] ${log.tag}: ${log.message}"
        }
    }

    companion object {
        fun intent(context: Context): Intent = Intent(context, LynxDebugActivity::class.java)
    }
}
