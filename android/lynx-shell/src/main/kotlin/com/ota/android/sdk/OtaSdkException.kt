package com.ota.android.sdk

class OtaSdkException : Exception {
  /** 可选结构化原因码；旧调用方仍只依赖 message。 */
  @JvmField
  val reasonCode: String?

  constructor(message: String?) : this(message, null, null)

  constructor(message: String?, cause: Throwable?) : this(message, cause, null)

  constructor(message: String?, cause: Throwable?, reasonCode: String?) : super(message, cause) {
    this.reasonCode = reasonCode
  }

  companion object {
    @JvmStatic
    fun invalidResponse(statusCode: Int, body: String): OtaSdkException {
      return OtaSdkException("服务端响应异常：$statusCode $body")
    }

    @JvmStatic
    fun checksumMismatch(expected: String, actual: String): OtaSdkException {
      return OtaSdkException(
        "Bundle 校验失败，期望 $expected，实际 $actual",
        null,
        OtaModels.ReasonCodes.BUNDLE_CHECKSUM_FAILED,
      )
    }
  }
}
