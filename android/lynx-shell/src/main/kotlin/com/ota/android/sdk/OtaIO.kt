package com.ota.android.sdk

import java.io.IOException
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URI
import java.security.MessageDigest
import java.security.NoSuchAlgorithmException

object OtaIO {
  /** 单次流式复制的可观察结果，避免把完整 Bundle 读入内存。 */
  data class StreamResult(
    val bytes: Long,
    val sha256: String,
  )

  @JvmStatic
  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun download(remoteUri: URI, localPath: File) {
    downloadAndHash(remoteUri, localPath)
  }

  @JvmStatic
  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun downloadAndHash(remoteUri: URI, localPath: File): StreamResult {
    return downloadAndHash(remoteUri, localPath, null, OtaModels.MAX_BUNDLE_BYTES.toLong())
  }

  @JvmStatic
  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun downloadAndHash(
    remoteUri: URI,
    localPath: File,
    expectedBytes: Long?,
    maxBytes: Long,
  ): StreamResult {
    if (Thread.currentThread().isInterrupted) {
      throw InterruptedException("Bundle 下载任务已取消")
    }
    validateExpectedBytes(expectedBytes, maxBytes)
    if (!remoteUri.scheme.equals("https", ignoreCase = true) || remoteUri.host.isNullOrBlank() ||
      remoteUri.userInfo != null || remoteUri.fragment != null
    ) {
      throw OtaSdkException("远程 Bundle URL 必须使用 HTTPS", null, OtaModels.ReasonCodes.INVALID_BUNDLE_URL)
    }
    localPath.parentFile?.let { ensureDirectory(it) }
    val connection = remoteUri.toURL().openConnection() as HttpURLConnection
    connection.instanceFollowRedirects = false
    connection.requestMethod = "GET"
    connection.connectTimeout = 10_000
    connection.readTimeout = 60_000
    val statusCode = connection.responseCode
    if (statusCode < 200 || statusCode >= 300) {
      // 错误响应通常很小，仅在诊断异常时读取，不影响 Bundle 流式路径。
      val body = connection.errorStream?.use { String(it.readBytes(), Charsets.UTF_8) } ?: ""
      connection.disconnect()
      throw OtaSdkException.invalidResponse(statusCode, body)
    }
    val contentLength = connection.contentLengthLong
    if (contentLength > maxBytes || (expectedBytes != null && contentLength >= 0L && contentLength != expectedBytes)) {
      connection.disconnect()
      throw OtaSdkException("Bundle Content-Length 校验失败", null, OtaModels.ReasonCodes.BUNDLE_SIZE_MISMATCH)
    }
    try {
      connection.inputStream.use { inputStream ->
        return writeAndHash(inputStream, localPath, expectedBytes, maxBytes)
      }
    } finally {
      connection.disconnect()
    }
  }

  /** 从已校验的旧 Release 流式复制到新的 staging 文件。 */
  @JvmStatic
  @Throws(IOException::class, InterruptedException::class)
  fun copyAndHash(sourcePath: File, destinationPath: File): StreamResult {
    return copyAndHash(sourcePath, destinationPath, null, OtaModels.MAX_BUNDLE_BYTES.toLong())
  }

  @JvmStatic
  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun copyAndHash(
    sourcePath: File,
    destinationPath: File,
    expectedBytes: Long?,
    maxBytes: Long,
  ): StreamResult {
    if (!sourcePath.isFile) {
      throw IOException("Bundle 源文件不存在：$sourcePath")
    }
    validateExpectedBytes(expectedBytes, maxBytes)
    FileInputStream(sourcePath).use { inputStream ->
      return writeAndHash(inputStream, destinationPath, expectedBytes, maxBytes)
    }
  }

  @JvmStatic
  @Throws(IOException::class, InterruptedException::class)
  fun writeAndHash(inputStream: InputStream, destinationPath: File): StreamResult {
    return writeAndHash(inputStream, destinationPath, null, OtaModels.MAX_BUNDLE_BYTES.toLong())
  }

  @JvmStatic
  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun writeAndHash(
    inputStream: InputStream,
    destinationPath: File,
    expectedBytes: Long?,
    maxBytes: Long,
  ): StreamResult {
    validateExpectedBytes(expectedBytes, maxBytes)
    destinationPath.parentFile?.let { ensureDirectory(it) }
    val digest = newSha256Digest()
    var bytes = 0L
    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
    try {
      FileOutputStream(destinationPath, false).use { outputStream ->
        while (true) {
          if (Thread.currentThread().isInterrupted) {
            throw InterruptedException("Bundle 传输任务已取消")
          }
          val readCount = inputStream.read(buffer)
          if (readCount == -1) {
            break
          }
          if (readCount == 0) {
            continue
          }
          val nextBytes = bytes + readCount.toLong()
          if (nextBytes > maxBytes || (expectedBytes != null && nextBytes > expectedBytes)) {
            throw OtaSdkException("Bundle 超过允许大小", null, OtaModels.ReasonCodes.BUNDLE_TOO_LARGE)
          }
          bytes = nextBytes
          digest.update(buffer, 0, readCount)
          outputStream.write(buffer, 0, readCount)
        }
        if (expectedBytes != null && bytes != expectedBytes) {
          throw OtaSdkException("Bundle size 校验失败", null, OtaModels.ReasonCodes.BUNDLE_SIZE_MISMATCH)
        }
      }
    } catch (error: InterruptedException) {
      if (destinationPath.exists()) {
        destinationPath.delete()
      }
      throw error
    } catch (error: IOException) {
      if (destinationPath.exists()) {
        destinationPath.delete()
      }
      throw error
    } catch (error: OtaSdkException) {
      if (destinationPath.exists()) {
        destinationPath.delete()
      }
      throw error
    }
    return StreamResult(bytes, formatSha256(digest.digest()))
  }

  private fun validateExpectedBytes(expectedBytes: Long?, maxBytes: Long) {
    if (maxBytes <= 0L) {
      throw IllegalArgumentException("Bundle 最大大小必须大于 0")
    }
    if (expectedBytes != null && (expectedBytes <= 0L || expectedBytes > maxBytes)) {
      throw OtaSdkException("Bundle 声明大小不合法", null, OtaModels.ReasonCodes.INVALID_BUNDLE_SIZE)
    }
  }

  @JvmStatic
  @Throws(IOException::class)
  fun sha256(file: File): String {
    try {
      FileInputStream(file).use { inputStream ->
        val digest = newSha256Digest()
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        while (true) {
          val readCount = inputStream.read(buffer)
          if (readCount == -1) {
            break
          }
          if (readCount > 0) {
            digest.update(buffer, 0, readCount)
          }
        }
        return formatSha256(digest.digest())
      }
    } catch (error: NoSuchAlgorithmException) {
      throw IllegalStateException("当前 JDK 不支持 SHA-256", error)
    }
  }

  private fun newSha256Digest(): MessageDigest {
    return try {
      MessageDigest.getInstance("SHA-256")
    } catch (error: NoSuchAlgorithmException) {
      throw IllegalStateException("当前 JDK 不支持 SHA-256", error)
    }
  }

  private fun formatSha256(hash: ByteArray): String {
    val builder = StringBuilder("sha256:")
    for (item in hash) {
      builder.append(String.format("%02x", item))
    }
    return builder.toString()
  }

  private fun ensureDirectory(directory: File) {
    if (directory.isDirectory) return
    if (!directory.mkdirs() && !directory.isDirectory) {
      throw IOException("无法创建 OTA 目录：$directory")
    }
  }

  private const val DEFAULT_BUFFER_SIZE = 64 * 1024
}
