package com.example.lynxcapacitormodule

import org.json.JSONArray
import org.json.JSONObject

/** 同步查询只读取实现目录和安装快照，不访问 UI、权限或实际 Host。 */
internal object NativeCapabilityStatusSnapshot {
    fun build(): String = JSONArray().apply {
        NativeCapabilityCatalog.specs.forEach { spec ->
            put(JSONObject().apply {
                put("name", spec.id)
                put("methods", JSONArray(spec.methods))
                put("implementedMethods", JSONArray(spec.implementedMethods))
                val needsHost = spec.implementedMethods.any { NativeHostRegistry.requiresHost(spec.id, it) }
                put("state", if (needsHost) "partial" else spec.state)
                put("hostConfigured", NativeHostRegistry.provider != null)
                put("runtimeAvailability", if (needsHost) "checkRequired" else "permission_or_hardware_check_required")
                put("hostMethods", JSONArray(NativeHostRegistry.supportedMethods.filter { it.startsWith("${spec.id}.") }))
                put("contractVersion", LynxCapabilitySemantics.CONTRACT_VERSION)
                put("semanticState", if (needsHost) "partial" else spec.semanticState)
                put("reasonCode", if (needsHost) "HOST_INTEGRATION_REQUIRED" else spec.reasonCode)
                put("reason", if (needsHost) "需要当前容器 Host adapter，并在调用时验证 owner 和系统可用性。" else spec.reason)
                put("methodStatus", spec.methodStatus().apply {
                    for (index in 0 until length()) {
                        val item = getJSONObject(index)
                        val name = item.optString("name", item.optString("methodName"))
                        if (NativeHostRegistry.requiresHost(spec.id, name)) {
                            item.put("state", "partial").put("semanticState", "partial")
                                .put("reasonCode", "HOST_INTEGRATION_REQUIRED").put("runtimeAvailability", "checkRequired")
                        }
                    }
                })
                put("verification", LynxCapabilitySemantics.verification())
                put("platform", "android")
            })
        }
    }.toString()

}
