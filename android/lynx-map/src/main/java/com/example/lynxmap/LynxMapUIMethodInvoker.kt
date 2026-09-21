package com.example.lynxmap

import com.lynx.react.bridge.Callback
import com.lynx.react.bridge.ReadableMap
import com.lynx.tasm.behavior.utils.LynxUIMethodInvoker

/**
 * Lynx 4.1 约定的生成类名；保留该类名即可让 MethodsExecutor 直接发现它，
 * 不需要在业务壳里引入 processor 或维护全局 invoker 注册表。
 */
class `LynxMapUI$$MethodInvoker` : LynxUIMethodInvoker<LynxMapUI> {
    override fun invoke(ui: LynxMapUI, methodName: String, params: ReadableMap?, callback: Callback) {
        when (methodName) {
            "moveCamera" -> ui.moveCamera(params, callback)
            "getCamera", "getCameraState" -> ui.getCameraState(params, callback)
            "projectCoordinate" -> ui.projectCoordinate(params, callback)
            "fitBounds" -> ui.fitBounds(params, callback)
            "selectMarker" -> ui.selectMarker(params, callback)
            "deselectMarker" -> ui.deselectMarker(params, callback)
            "showMarkers" -> ui.showMarkers(params, callback)
            "getCapabilities" -> ui.getCapabilities(params, callback)
            "getPerformanceSnapshot" -> ui.getPerformanceSnapshot(params, callback)
            else -> callback.invoke(LynxMapResult.invalid("未知地图 UI Method：$methodName"))
        }
    }
}
