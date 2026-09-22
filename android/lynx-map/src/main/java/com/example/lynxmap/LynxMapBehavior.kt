package com.example.lynxmap

import com.lynx.tasm.behavior.Behavior
import com.lynx.tasm.behavior.LynxContext
import com.lynx.tasm.behavior.ui.LynxUI

/** `lynx-map` 的每个 Lynx View 独立 Behavior。 */
class LynxMapBehavior : Behavior("lynx-map") {
    override fun createUI(context: LynxContext): LynxUI<*> = LynxMapUI(context)
}
