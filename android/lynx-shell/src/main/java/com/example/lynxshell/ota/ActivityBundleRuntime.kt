package com.example.lynxshell.ota

import java.io.File

/**
 * Activity-first Router 与 OTA SDK 之间的最小接缝。
 *
 * Router 不依赖具体的 Manifest、缓存目录或下载器。业务 App 只需要把自己的 OTA SDK
 * 适配成这个接口，prepare 返回值必须已经完成 current 解析、下载、大小检查和 SHA/签名
 * 校验。Router 会在后台线程调用 prepare，因此不会阻塞主线程。
 */
interface ActivityBundleRuntime {
    /**
     * Application 完成初始化时调用。OTA 适配器可在这里异步同步全量 latest-bundle-list，
     * 普通本地 Bundle 适配器保持默认空实现即可。
     */
    fun onApplicationStarted() = Unit

    /**
     * 宿主从后台回到前台时调用。OTA 适配器可再次异步同步全量 appId。
     */
    fun onApplicationForeground() = Unit

    /**
     * 为一次页面打开准备指定 appId 下的 Bundle。
     *
     * 典型实现先读取已提交 current；如果有可用旧版本可以立即返回，并在后台刷新当前
     * appId。如果本地没有可用 Bundle，再调用 `ensureBundleReady(lynxAppId, bundleName)`
     * 等待下载、校验和激活。异常会进入壳的错误态，不会创建一个空 LynxView。
     */
    @Throws(Exception::class)
    fun prepare(lynxAppId: String, bundleName: String): PreparedActivityBundle

    /**
     * 页面首屏失败时按 appId 回滚一次。没有可回滚版本时返回 false，避免误报成功。
     */
    @Throws(Exception::class)
    fun rollback(lynxAppId: String, reason: String): Boolean = false
}

/**
 * OTA runtime 交付给 Activity 的已校验 Bundle 来源。
 *
 * Intent 只保留逻辑 appId/bundleName，绝不把这里的绝对路径写入页面参数或路由栈。
 * file 与 bytes 必须二选一；大 Bundle 优先使用 file，避免长期占用 Java 堆。
 */
data class PreparedActivityBundle(
    val lynxAppId: String,
    val bundleName: String,
    val file: File? = null,
    val bytes: ByteArray? = null,
    val releaseId: String? = null,
    val sha256: String? = null,
) {
    init {
        require(lynxAppId.isNotBlank()) { "lynxAppId 不能为空" }
        require(bundleName.isNotBlank()) { "bundleName 不能为空" }
        require((file == null) xor (bytes == null)) {
            "PreparedActivityBundle 必须且只能提供 file 或 bytes"
        }
        file?.let {
            require(it.isFile) { "已准备的 Bundle 不是普通文件: ${it.absolutePath}" }
            require(it.canRead()) { "已准备的 Bundle 不可读: ${it.absolutePath}" }
        }
        bytes?.let { require(it.isNotEmpty()) { "已准备的 Bundle 不能为空" } }
    }
}
