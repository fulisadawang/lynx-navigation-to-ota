package com.example.lynxshell.sample

import com.example.lynxshell.debug.LynxDebugTool

/** 只由 Debug Manifest 选用；生产 Application 不含调试安装或反射入口。 */
class LynxShellDebugApplication : LynxShellSampleApplication() {
    override fun onCreate() {
        // Core 的 Debug variant 先完成官方 DevTool 接线；面板随后安装，不覆盖用户开关。
        super.onCreate()
        LynxDebugTool.install(this)
    }
}
