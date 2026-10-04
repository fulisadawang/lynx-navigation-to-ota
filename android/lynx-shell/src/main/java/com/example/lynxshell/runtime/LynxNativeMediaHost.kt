package com.example.lynxshell.runtime

import android.content.Context
import org.json.JSONObject

/** 宿主将旧 Shell 媒体 ABI 接到独立能力模块；Context 必须保留实际 LynxView 身份。 */
interface LynxNativeMediaHost {
    fun call(callerContext: Context, methodName: String, optionsJSON: String, complete: (JSONObject) -> Unit)
    fun onViewDestroy(callerContext: Context)
}
