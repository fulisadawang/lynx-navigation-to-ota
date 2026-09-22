package com.example.lynxshell.sample

import com.example.lynxshell.debug.LynxDebugTool

/** 只由 Debug Manifest 选用；生产 Application 不含调试安装或反射入口。 */
class LynxShellDebugApplication : LynxShellSampleApplication() {
    override fun onCreate() {
        // DevTool Service 必须在父类初始化 Lynx Runtime 之前注册。
        LynxDebugTool.install(this)
        super.onCreate()
        LynxDebugTool.activateRuntimeFlags()
    }
}
