package com.example.lynxshell.debug

import android.app.Activity
import android.app.Application
import android.view.ViewGroup
import com.lynx.service.devtool.LynxDevToolService
import com.lynx.tasm.service.LynxServiceCenter
import com.lynx.tasm.LynxEnv
import com.lynx.devtool.LynxDevtoolEnv
import com.google.android.material.bottomsheet.BottomSheetBehavior
import com.google.android.material.bottomsheet.BottomSheetDialog
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android 端内 Debug Tool 入口。
 *
 * 该类只应由 Debug Application 显式调用；Release 不依赖此 module。
 */
object LynxDebugTool {
    private val installed = AtomicBoolean(false)
    private lateinit var store: DebugEventStore
    private var inspector: BottomSheetDialog? = null

    @JvmStatic
    fun install(value: Application) {
        if (!installed.compareAndSet(false, true)) return
        store = DebugEventStore()
        LynxDebugBridge.install(store)
        LynxServiceCenter.inst().registerService(LynxDevToolService.INSTANCE)
        activateRuntimeFlags()
        LynxEnv.inst().registerModule(LynxDebugModule.MODULE_NAME, LynxDebugModule::class.java)
        LynxConsoleLogDelegate.installOnce()
        LynxDebugFloatingBallManager.install(value)
        LynxDebugFloatingBallManager.setEnabled(true)
    }

    /** Runtime 初始化后再次调用，避免 LynxEnv.init 覆盖 Debug flags。 */
    @JvmStatic
    fun activateRuntimeFlags() {
        LynxEnv.inst().enableLynxDebug(true)
        LynxEnv.inst().enableDevtool(true)
        LynxEnv.inst().enableLogBox(true)
        LynxDevtoolEnv.inst().enableLongPressMenu(true)
        LynxServiceCenter.inst().registerService(LynxDebugHttpService)
    }

    @JvmStatic
    fun show(activity: Activity) {
        if (!installed.get()) return
        if (inspector?.isShowing == true) return
        val dialog = BottomSheetDialog(activity)
        val panel = LynxDebugPanelView(activity) { dialog.dismiss() }
        dialog.setContentView(panel)
        // Inspector 是诊断工作台，不允许误触下拉、遮罩或返回键关闭；只保留面板内的 X。
        dialog.setCancelable(false)
        dialog.setCanceledOnTouchOutside(false)
        dialog.setOnShowListener {
            val sheet = dialog.findViewById<ViewGroup>(com.google.android.material.R.id.design_bottom_sheet)
            sheet?.let {
                it.layoutParams = it.layoutParams.apply {
                    height = (activity.resources.displayMetrics.heightPixels * 0.78f).toInt()
                }
                BottomSheetBehavior.from(it).apply {
                    state = BottomSheetBehavior.STATE_EXPANDED
                    skipCollapsed = true
                    isHideable = false
                    isDraggable = false
                }
            }
        }
        dialog.setOnDismissListener { inspector = null }
        inspector = dialog
        dialog.show()
    }

    internal fun store(): DebugEventStore = store

}
