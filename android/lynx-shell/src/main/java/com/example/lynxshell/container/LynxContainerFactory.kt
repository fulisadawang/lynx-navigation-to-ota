package com.example.lynxshell.container

import android.app.Activity
import android.view.View
import com.example.lynxshell.model.LynxPageRequest
import com.example.lynxshell.resource.ShellTemplateProvider
import com.example.lynxshell.runtime.ShellGlobalPropsFactory
import com.example.lynxshell.runtime.XElementRuntime
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
    ): LynxView {
        val builder = LynxViewBuilder()
            .setTemplateProvider(templateProvider)
            .setThreadStrategyForRendering(ThreadStrategyForRendering.MOST_ON_TASM)

        // 全部页面统一安装 Lynx 4.0 Explorer 范围内的完整 XElement Behavior。
        XElementRuntime.install(builder)

        if (request.widthPx != null && request.heightPx != null) {
            builder.setPresetMeasuredSpec(
                View.MeasureSpec.makeMeasureSpec(request.widthPx, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(request.heightPx, View.MeasureSpec.EXACTLY),
            )
        }
        request.density?.let(builder::setDensity)

        return builder.build(activity).also { lynxView ->
            // Lynx 4.0 没有 Builder.setLynxViewClient；必须在 build 后、render 前安装。
            lynxViewClient?.let(lynxView::addLynxViewClient)
            val globalProps = ShellGlobalPropsFactory.create(activity, request, bundleMetadata)
            lynxView.updateGlobalProps(TemplateData.fromMap(globalProps))
        }
    }
}
