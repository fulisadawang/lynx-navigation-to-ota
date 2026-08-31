package com.ota.android.sdk

import java.net.URI

/**
 * 调试本地 OTA 服务的地址策略。
 *
 * HTTP 只允许显式打开的 TEST loopback/Android emulator host；普通配置和生产构建仍只
 * 接受 HTTPS。这个策略只控制测试地址，不改变 Bundle 的身份校验和原子提交。
 */
internal object OtaURLPolicy {
  fun isAllowed(uri: URI, environment: OtaModels.Environment, allowLocalHTTPForTest: Boolean): Boolean {
    if (uri.scheme.equals("https", ignoreCase = true)) return uri.host?.isNotBlank() == true
    return allowLocalHTTPForTest && environment == OtaModels.Environment.TEST &&
      uri.scheme.equals("http", ignoreCase = true) && isLoopbackOrEmulatorHost(uri.host)
  }

  fun isLoopbackOrEmulatorHost(host: String?): Boolean {
    return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "10.0.2.2"
  }
}
