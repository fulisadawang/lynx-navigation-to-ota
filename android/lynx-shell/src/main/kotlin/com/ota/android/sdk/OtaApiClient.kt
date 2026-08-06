package com.ota.android.sdk

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URLEncoder

interface OtaApiClient {
  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun checkForUpdate(request: OtaModels.PolicyMatchRequest): OtaModels.PolicyMatchResponse

  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun fetchManifest(
    releaseId: String,
    env: OtaModels.Environment,
    hostApp: OtaModels.HostApp,
    lynxAppId: String,
    platform: OtaModels.Platform,
  ): OtaModels.ReleaseManifest

  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun fetchLatestBundleLists(
    env: OtaModels.Environment,
    hostApp: OtaModels.HostApp,
    platform: OtaModels.Platform,
  ): OtaModels.HostLatestBundleLists

  /**
   * 只读取指定 lynxAppId 的最新 Bundle 清单。
   *
   * 服务端仍然复用 latest-bundle-list 接口，只是带上 lynxAppId 查询参数；
   * Application 启动/回前台使用上面的全量接口，页面缺包时使用这个窄范围接口。
   * 默认实现保留 FakeApiClient 和旧接入方的二进制兼容，只从全量响应中过滤目标 appId。
   */
  fun fetchLatestBundleList(
    env: OtaModels.Environment,
    hostApp: OtaModels.HostApp,
    lynxAppId: String,
    platform: OtaModels.Platform,
  ): OtaModels.LatestBundleList {
    val all = fetchLatestBundleLists(env, hostApp, platform)
    return all.bundleLists.firstOrNull { it.lynxAppId == lynxAppId }
      ?: throw OtaSdkException("最新 bundle-list 中不存在 lynxAppId：$lynxAppId")
  }

  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun reportEvent(payload: OtaModels.ReportPayload)

  companion object {
    const val OTA_CLIENT_TOKEN_HEADER = "x-ota-client-token"

    @JvmStatic
    fun server(baseUri: URI): OtaApiClient {
      return ServerOtaApiClient(baseUri, OtaModels.DEFAULT_OTA_CLIENT_TOKEN)
    }

    @JvmStatic
    fun server(baseUri: URI, otaClientToken: String?): OtaApiClient {
      return ServerOtaApiClient(baseUri, otaClientToken)
    }
  }
}

private class ServerOtaApiClient(
  private val baseUri: URI,
  otaClientToken: String?,
) : OtaApiClient {
  private val otaClientToken: String =
    if (otaClientToken.isNullOrBlank()) OtaModels.DEFAULT_OTA_CLIENT_TOKEN else otaClientToken

  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  override fun checkForUpdate(request: OtaModels.PolicyMatchRequest): OtaModels.PolicyMatchResponse {
    val response = send("POST", resolve("/api/ota/v1/policy/match"), OtaJson.stringify(request.toJsonMap()))
    ensureSuccess(response)
    return OtaModels.PolicyMatchResponse.fromJsonMap(OtaJson.asObject(OtaJson.parse(response.body), "policy match 响应"))
  }

  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  override fun fetchManifest(
    releaseId: String,
    env: OtaModels.Environment,
    hostApp: OtaModels.HostApp,
    lynxAppId: String,
    platform: OtaModels.Platform,
  ): OtaModels.ReleaseManifest {
    val uri = resolve(
      "/api/ota/v1/release/${encode(releaseId)}/manifest?env=${encode(env.wireValue)}" +
        "&hostApp=${encode(hostApp.wireValue)}" +
        "&lynxAppId=${encode(lynxAppId)}" +
        "&platform=${encode(platform.wireValue)}",
    )
    val response = send("GET", uri, null)
    ensureSuccess(response)
    return OtaModels.ReleaseManifest.fromJsonMap(OtaJson.asObject(OtaJson.parse(response.body), "manifest 响应"))
  }

  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  override fun fetchLatestBundleLists(
    env: OtaModels.Environment,
    hostApp: OtaModels.HostApp,
    platform: OtaModels.Platform,
  ): OtaModels.HostLatestBundleLists {
    return fetchLatestBundleLists(env, hostApp, null, platform)
  }

  override fun fetchLatestBundleList(
    env: OtaModels.Environment,
    hostApp: OtaModels.HostApp,
    lynxAppId: String,
    platform: OtaModels.Platform,
  ): OtaModels.LatestBundleList {
    val uri = resolve(
      "/api/ota/v1/releases/latest-bundle-list?env=${encode(env.wireValue)}" +
        "&hostApp=${encode(hostApp.wireValue)}" +
        "&lynxAppId=${encode(lynxAppId)}" +
        "&platform=${encode(platform.wireValue)}",
    )
    val response = send("GET", uri, null)
    ensureSuccess(response)
    return OtaModels.LatestBundleList.fromJsonMap(
      OtaJson.asObject(OtaJson.parse(response.body), "appId latest-bundle-list 响应"),
    )
  }

  private fun fetchLatestBundleLists(
    env: OtaModels.Environment,
    hostApp: OtaModels.HostApp,
    lynxAppId: String?,
    platform: OtaModels.Platform,
  ): OtaModels.HostLatestBundleLists {
    val uri = resolve(
      "/api/ota/v1/releases/latest-bundle-list?env=${encode(env.wireValue)}" +
        "&hostApp=${encode(hostApp.wireValue)}" +
        (if (lynxAppId == null) "" else "&lynxAppId=${encode(lynxAppId)}") +
        "&platform=${encode(platform.wireValue)}",
    )
    val response = send("GET", uri, null)
    ensureSuccess(response)
    val body = OtaJson.asObject(OtaJson.parse(response.body), "latest-bundle-list 响应")
    if (body.containsKey("bundleLists")) {
      return OtaModels.HostLatestBundleLists.fromJsonMap(body)
    }
    val bundleLists = ArrayList<OtaModels.LatestBundleList>()
    bundleLists.add(OtaModels.LatestBundleList.fromJsonMap(body))
    return OtaModels.HostLatestBundleLists(env, hostApp, platform, bundleLists)
  }

  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  override fun reportEvent(payload: OtaModels.ReportPayload) {
    val response = send("POST", resolve("/api/ota/v1/release/report"), OtaJson.stringify(payload.toJsonMap()))
    ensureSuccess(response)
  }

  private fun resolve(pathAndQuery: String): URI {
    val base = baseUri.toString()
    val normalizedBase = if (base.endsWith("/")) base.substring(0, base.length - 1) else base
    return URI.create(normalizedBase + pathAndQuery)
  }

  private fun encode(raw: String): String {
    return try {
      URLEncoder.encode(raw, "UTF-8")
    } catch (error: java.io.UnsupportedEncodingException) {
      throw IllegalStateException("当前运行环境不支持 UTF-8", error)
    }
  }

  @Throws(IOException::class)
  private fun send(method: String, uri: URI, body: String?): HttpResult {
    val connection = uri.toURL().openConnection() as HttpURLConnection
    connection.requestMethod = method
    connection.connectTimeout = 10_000
    connection.readTimeout = 30_000
    connection.setRequestProperty("Accept", "application/json")
    connection.setRequestProperty(OtaApiClient.OTA_CLIENT_TOKEN_HEADER, otaClientToken)
    if (body != null) {
      val bytes = body.toByteArray(Charsets.UTF_8)
      connection.doOutput = true
      connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")
      connection.setRequestProperty("Content-Length", bytes.size.toString())
      connection.outputStream.use { it.write(bytes) }
    }
    val statusCode = connection.responseCode
    val stream = if (statusCode in 200..299) connection.inputStream else connection.errorStream
    val responseBody = stream?.use { String(readAll(it), Charsets.UTF_8) } ?: ""
    connection.disconnect()
    return HttpResult(statusCode, responseBody)
  }

  @Throws(OtaSdkException::class)
  private fun ensureSuccess(response: HttpResult) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw OtaSdkException.invalidResponse(response.statusCode, response.body)
    }
  }

  private data class HttpResult(
    val statusCode: Int,
    val body: String,
  )

  @Throws(IOException::class)
  private fun readAll(inputStream: InputStream): ByteArray {
    val outputStream = ByteArrayOutputStream()
    val buffer = ByteArray(8192)
    while (true) {
      val readCount = inputStream.read(buffer)
      if (readCount == -1) {
        break
      }
      outputStream.write(buffer, 0, readCount)
    }
    return outputStream.toByteArray()
  }
}
