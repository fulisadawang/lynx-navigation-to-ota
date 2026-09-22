package com.example.lynxshell.runtime

import android.app.Application
import com.lynx.devtoolwrapper.DevToolSettings
import com.lynx.tasm.LynxEnv

/** Release 仅使用核心 SDK 关闭调试引导，不链接调试 Service 或调试桥。 */
internal object LynxDevToolRuntime {
    @Suppress("UNUSED_PARAMETER")
    fun beforeInitialize(application: Application) {
        DevToolSettings.inst().bootstrap().apply {
            setLynxDebugEnabled(false)
            setLogBoxEnabled(false)
            setLoadQJSBridge(false)
            setLoadV8Bridge(false)
        }
    }

    @Suppress("UNUSED_PARAMETER")
    fun afterInitialize(application: Application) {
        LynxEnv.inst().enableLynxDebug(false)
    }
}
