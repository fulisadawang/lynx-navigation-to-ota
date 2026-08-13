package com.example.lynxshell.telemetry

import java.lang.ref.WeakReference
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Android App 前后台适配器的最小注册表。
 *
 * Router 不猜测宿主的 ProcessLifecycleOwner 实现；业务在 Application/进程生命周期回调中
 * 调用 LynxRouter.onApplicationForeground/onApplicationBackground，注册表再把事实广播给
 * 活着的页面协调器。WeakReference 保证页面销毁后不会因为监控反向持有 Activity。
 */
object TelemetryCoordinatorRegistry {
    private val coordinators = CopyOnWriteArrayList<WeakReference<TelemetryCoordinator>>()

    fun register(coordinator: TelemetryCoordinator) {
        compact()
        if (coordinators.none { it.get() === coordinator }) {
            coordinators += WeakReference(coordinator)
        }
    }

    fun unregister(coordinator: TelemetryCoordinator) {
        coordinators.removeAll { it.get() == null || it.get() === coordinator }
    }

    fun onApplicationForeground() {
        compact()
        coordinators.mapNotNull { it.get() }.forEach { it.onApplicationLifecycle(AppLifecycleState.FOREGROUND, "appForeground") }
    }

    fun onApplicationBackground() {
        compact()
        coordinators.mapNotNull { it.get() }.forEach { it.onApplicationLifecycle(AppLifecycleState.BACKGROUND, "appBackground") }
    }

    private fun compact() {
        coordinators.removeAll { it.get() == null }
    }
}
