package com.example.lynxshell.runtime

import com.lynx.tasm.LynxViewBuilder
import com.lynx.xelement.XElementBehaviors

/**
 * Lynx 4.1 XElement 的统一运行时注册入口。
 *
 * Gradle 已显式引入 Input、Overlay、ViewPager、ScrollCoordinator、SVG、Markdown、
 * Refresh、BlurView、WebView 与 Video。这里使用官方 [XElementBehaviors]
 * 聚合器，把各 AAR 由注解处理器生成的 Behavior 一次性注册到每个 [LynxViewBuilder]。
 *
 * 不要在业务页面里零散注册单个 Behavior，否则不同页面可能出现组件能力不一致。
 */
object XElementRuntime {
    /**
     * 将当前版本携带的全部 XElement Behavior 安装到 Builder。
     *
     * [XElementBehaviors.create] 会读取 `com.lynx.xelement.BehaviorGenerator` 与
     * `com.lynx.xelement.svg.BehaviorGenerator`，因此 R8 keep 规则也在本 Module 的
     * `consumer-rules.pro` 中显式保留这两个生成类。Video 由 4.1 聚合器中的 AutoRegistry
     * 直接创建，保持与其它 XElement 相同的 Builder 注册边界。
     * AnimaX 由独立专项分支启用，本分支在聚合结果上显式过滤其 Behavior。
     */
    fun install(builder: LynxViewBuilder) {
        builder.addBehaviors(
            XElementBehaviors().create().filterNot { it.name == ANIMAX_BEHAVIOR_NAME },
        )
    }

    private const val ANIMAX_BEHAVIOR_NAME = "animax-view"
}
