package com.example.lynxcapacitormodule

/** Runtime 与回归测试共用真实方法调度，权限和展示 API 不能随整个能力域进入 IO 线程。 */
internal object NativeExecutionPolicy {
    enum class Lane { UI, LOCAL, NETWORK }
    fun lane(pluginId: String, methodName: String): Lane = when {
        pluginId == "CapacitorHttp" && methodName in setOf("request", "get", "post") -> Lane.NETWORK
        pluginId == "CapacitorSQLite" && methodName !in setOf("echo", "isAvailable") -> Lane.LOCAL
        pluginId in setOf("Filesystem", "Preferences") -> Lane.LOCAL
        pluginId in setOf("Contacts", "Calendar") && methodName !in setOf("checkPermissions", "requestPermissions") -> Lane.LOCAL
        else -> Lane.UI
    }
    fun schedule(pluginId: String, methodName: String, owner: NativeOwnerScope,
        main: (() -> Unit) -> Unit, rejected: () -> Unit, work: () -> Unit) {
        when (lane(pluginId, methodName)) {
            Lane.UI -> main { if (owner.isActive) NativeCallContext.withOwner(owner, work) }
            Lane.LOCAL -> NativeIO.local.submit(owner, rejected, work)
            Lane.NETWORK -> NativeIO.network.submit(owner, rejected, work)
        }
    }
}
