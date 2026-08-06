package com.example.lynxshell.runtime

import com.lynx.tasm.LynxViewBuilder
import com.lynx.xelement.XElementBehaviors

/**
 * Lynx 4.0 XElement 的统一运行时注册入口。
 *
 * Gradle 已显式引入 Input、Overlay、ViewPager、ScrollCoordinator、SVG、Markdown、
 * Refresh、BlurView 与 WebView。这里使用官方 [XElementBehaviors] 聚合器，把各 AAR
 * 由注解处理器生成的 Behavior 一次性注册到每个 [LynxViewBuilder]。
 *
 * 不要在业务页面里零散注册单个 Behavior，否则不同页面可能出现组件能力不一致。
 */
object XElementRuntime {
    /**
     * 将当前版本携带的全部 XElement Behavior 安装到 Builder。
     *
     * [XElementBehaviors.create] 会读取 `com.lynx.xelement.BehaviorGenerator` 与
     * `com.lynx.xelement.svg.BehaviorGenerator`，因此 R8 keep 规则也在 app 的
     * `proguard-rules.pro` 中显式保留了这两个生成类。
     */
    fun install(builder: LynxViewBuilder) {
        builder.addBehaviors(XElementBehaviors().create())
    }
}
