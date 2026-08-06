package com.example.lynxshell.runtime

import android.app.Application
import com.example.lynxshell.bridge.LynxShellModule
import com.example.lynxshell.resource.ShellTemplateProvider
import com.facebook.drawee.backends.pipeline.Fresco
import com.facebook.imagepipeline.core.ImagePipelineConfig
import com.facebook.imagepipeline.memory.PoolConfig
import com.facebook.imagepipeline.memory.PoolFactory
import com.lynx.service.http.LynxHttpService
import com.lynx.service.image.LynxImageService
import com.lynx.service.log.LynxLogService
import com.lynx.tasm.LynxEnv
import com.lynx.tasm.service.LynxServiceCenter
import java.util.concurrent.atomic.AtomicBoolean

/** Lynx 运行时一次性初始化器。 */
object LynxRuntimeInitializer {
    private val initialized = AtomicBoolean(false)

    fun initialize(application: Application) {
        if (!initialized.compareAndSet(false, true)) return

        // Image Service 依赖 Fresco，必须先完成图片管线初始化。
        val poolFactory = PoolFactory(PoolConfig.newBuilder().build())
        val imageConfig = ImagePipelineConfig.newBuilder(application)
            .setPoolFactory(poolFactory)
            .build()
        Fresco.initialize(application, imageConfig)

        // Lynx Service 需要宿主主动注入；顺序与官方 4.0 接入示例一致。
        LynxServiceCenter.inst().registerService(LynxImageService.getInstance())
        LynxServiceCenter.inst().registerService(LynxLogService)
        LynxServiceCenter.inst().registerService(LynxHttpService)

        // 全局 Provider 作为兜底；每个页面仍会注入带错误监听的 Provider。
        LynxEnv.inst().init(
            application,
            null,
            ShellTemplateProvider(application),
            null,
        )

        // 模块名必须与 Lynx 页面侧 NativeModules 声明完全一致。
        LynxEnv.inst().registerModule(LynxShellModule.MODULE_NAME, LynxShellModule::class.java)
    }
}
