package com.example.lynxshell.container

import android.app.Activity
import android.view.View
// LYNX_DEBUG_TOOL_BEGIN
import com.example.lynxshell.debug.LynxDebugBridge
// LYNX_DEBUG_TOOL_END
import com.example.lynxshell.model.LynxPageRequest
import com.example.lynxshell.monitoring.LynxViewMonitor
import com.example.lynxshell.resource.ShellTemplateProvider
import com.example.lynxshell.runtime.ShellGlobalPropsFactory
import com.example.lynxshell.runtime.XElementRuntime
import com.example.lynxmap.LynxMapRuntime
import com.lynx.tasm.LynxView
import com.lynx.tasm.LynxViewBuilder
import com.lynx.tasm.LynxViewClient
import com.lynx.tasm.TemplateData
import com.lynx.tasm.ThreadStrategyForRendering

/** 只负责把页面配置翻译成 LynxViewBuilder，不承担导航与页面状态。 */
object LynxContainerFactory {
    fun create(
        activity: Activity,
        request: LynxPageRequest,
        templateProvider: ShellTemplateProvider,
        lynxViewClient: LynxViewClient? = null,
        bundleMetadata: Map<String, Any>? = null,
        monitoring: LynxViewMonitor? = null,
        // LYNX_DEBUG_TOOL_BEGIN
        containerKind: String = "page",
        // LYNX_DEBUG_TOOL_END
    ): LynxView {
        val initialLayout = ShellGlobalPropsFactory.captureLayout(activity)
        val builder = LynxViewBuilder()
            .setTemplateProvider(templateProvider)
            .setThreadStrategyForRendering(ThreadStrategyForRendering.MOST_ON_TASM)
            .setColorScheme(ShellGlobalPropsFactory.resolveColorScheme(activity))
            .setScreenSize(initialLayout.screenWidthPx, initialLayout.screenHeightPx)

        // 全部页面统一安装 Lynx 4.1 Explorer 范围内的完整 XElement Behavior，包含
        // Video；不让业务页面自行注册，避免不同页面能力不一致。
        XElementRuntime.install(builder)
        LynxMapRuntime.install(builder)

        if (request.widthPx != null && request.heightPx != null) {
            builder.setPresetMeasuredSpec(
                View.MeasureSpec.makeMeasureSpec(request.widthPx, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(request.heightPx, View.MeasureSpec.EXACTLY),
            )
        }
        request.density?.let(builder::setDensity)

        val creationStart = System.nanoTime()
        val created = try { builder.build(activity) } catch (error: Exception) {
            monitoring?.createFailed()
            throw error
        }
        return created.also { lynxView ->
            // 观测先于已有错误处理安装；监控失败不能改变首屏与 OTA 的处理结果。
            monitoring?.attach(lynxView, creationStart)
            // Lynx 4.1 仍没有 Builder.setLynxViewClient；必须在 build 后、render 前安装。
            lynxViewClient?.let(lynxView::addLynxViewClient)
            val globalProps = ShellGlobalPropsFactory.create(
                activity = activity,
                request = request,
                bundleMetadata = bundleMetadata,
                initialLayout = initialLayout,
            )
            lynxView.updateGlobalProps(TemplateData.fromMap(globalProps))
            // LYNX_DEBUG_TOOL_BEGIN
            LynxDebugBridge.attach(
                view = lynxView,
                viewId = monitoring?.viewId,
                containerKind = containerKind,
                request = request,
                bundleMetadata = bundleMetadata,
                globalProps = globalProps,
            )
            // LYNX_DEBUG_TOOL_END
        }
    }
}
