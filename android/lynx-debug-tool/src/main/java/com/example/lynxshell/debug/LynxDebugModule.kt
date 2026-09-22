package com.example.lynxshell.debug

import com.lynx.jsbridge.LynxMethod
import com.lynx.jsbridge.LynxModule
import com.lynx.react.bridge.Callback
import com.lynx.react.bridge.JavaOnlyMap
import com.lynx.tasm.behavior.LynxContext

/** 只读调试 Module；Release 未注册此名字。 */
class LynxDebugModule(context: android.content.Context) : LynxModule(context) {
    @LynxMethod
    fun getSnapshot(callback: Callback) {
        callback.invoke(LynxDebugTool.store().snapshotJson())
    }

    @LynxMethod
    fun clear(callback: Callback) {
        LynxDebugTool.store().clear()
        callback.invoke(result(0, "调试记录已清空"))
    }

    @LynxMethod
    fun open(callback: Callback) {
        val context = (mContext as? LynxContext)?.getContext() ?: mContext
        val activity = context.findActivity()
        if (activity == null) {
            callback.invoke(result(1002, "当前 LynxContext 没有关联 Activity"))
            return
        }
        LynxDebugTool.show(activity)
        callback.invoke(result(0, "调试面板已打开"))
    }

    private fun result(code: Int, message: String): JavaOnlyMap =
        com.lynx.jsbridge.Arguments.makeNativeMap(
            hashMapOf<String, Any>("code" to code, "message" to message),
        )

    private fun android.content.Context.findActivity(): android.app.Activity? = when (this) {
        is android.app.Activity -> this
        is android.content.ContextWrapper -> baseContext.findActivity()
        else -> null
    }

    companion object { const val MODULE_NAME = "LynxDebugModule" }
}
