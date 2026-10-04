package com.example.lynxcapacitormodule

import java.lang.ref.WeakReference

/** View 可先激活、Module 后懒创建；旧 Context 退出不得清掉后来激活的 View。 */
internal class NativeActiveContext<T : Any> {
    private var reference: WeakReference<T>? = null
    @Synchronized fun canActivate(context: T): Boolean = reference?.get().let { it == null || it === context }
    @Synchronized fun activate(context: T) { reference = WeakReference(context) }
    @Synchronized fun release(context: T): Boolean {
        if (reference?.get() !== context) return false
        reference = null
        return true
    }
}
