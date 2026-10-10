package com.example.lynxshell.runtime

import android.app.Activity
import android.content.Intent
import com.lynx.tasm.LynxView

/** 可选能力模块由业务 App 安装；Shell 不需要依赖具体能力 AAR。所有回调在主线程执行。 */
interface LynxNativeModuleHost {
    fun onViewActive(activity: Activity, view: LynxView)
    fun onActivityResult(activity: Activity, requestCode: Int, resultCode: Int, data: Intent?)
    fun onRequestPermissionsResult(activity: Activity, requestCode: Int, permissions: Array<out String>, grantResults: IntArray)
    fun onNewIntent(activity: Activity, intent: Intent)
}

/** 可选销毁接线不改变已有 Host 的二进制接口；SDK Module.destroy 仍照常执行。 */
interface LynxNativeModuleLifecycleHost : LynxNativeModuleHost {
    /** context 实际为当前 LynxContext；与 MediaHost 共用签名，统一处理宿主任务且应幂等。 */
    fun onViewDestroy(context: android.content.Context)
}
