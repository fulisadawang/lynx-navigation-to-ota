package com.example.lynxcapacitormodule

import androidx.camera.camera2.Camera2Config
import androidx.camera.core.CameraFilter
import androidx.camera.core.CameraSelector
import androidx.camera.core.CameraXConfig
import androidx.camera.lifecycle.ProcessCameraProvider
import java.util.concurrent.locks.ReentrantLock

/**
 * 当前 Module 的 CameraX 初始化边界。
 *
 * 部分 Android Emulator 只暴露后置 camera，但 PackageManager 同时声明了前置
 * camera feature。CameraX 默认校验两者时会把整个 provider 判定为不可用；这里仅
 * 提供一个不附带镜头朝向的可用相机过滤器，让真正的拍照/扫码 selector 决定镜头。
 */
object NativeCameraXConfiguration {
    private val lock = Any()
    private val operationLock = ReentrantLock()
    private var configured = false

    fun configure() {
        synchronized(lock) {
            if (configured) return

            val allAvailableCameras = CameraSelector.Builder()
                .addCameraFilter(CameraFilter { cameras -> cameras.toMutableList() })
                .build()
            val config = CameraXConfig.Builder
                .fromConfig(Camera2Config.defaultConfig())
                .setAvailableCamerasLimiter(allAvailableCameras)
                .build()

            try {
                ProcessCameraProvider.configureInstance(config)
            } catch (error: IllegalStateException) {
                // 宿主可能已经提前配置了 CameraX；只有“已配置”允许复用现有实例。
                if (!error.message.orEmpty().contains("already", ignoreCase = true)) throw error
            }
            configured = true
        }
    }

    /** 相机是进程级硬件资源；拍照和扫码页面不得并发抢占同一个 CameraX provider。 */
    fun tryAcquireOperation(): Boolean = operationLock.tryLock()

    fun releaseOperation() {
        if (operationLock.isHeldByCurrentThread) operationLock.unlock()
    }
}
