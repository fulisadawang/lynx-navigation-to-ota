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
    if (Thread.currentThread().isInterrupted) {
      throw InterruptedException("Bundle 下载任务已取消")
    }
    localPath.parentFile?.let { ensureDirectory(it) }
    when ((remoteUri.scheme ?: "").lowercase()) {
      "file" -> {
        if (localPath.exists() && !localPath.delete()) {
          throw IOException("无法删除旧 Bundle：$localPath")
        }
        return copyAndHash(File(remoteUri), localPath)
      }

      "http", "https" -> {
        val connection = remoteUri.toURL().openConnection() as HttpURLConnection
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
        try {
          connection.inputStream.use { inputStream ->
            return writeAndHash(inputStream, localPath)
          }
        } finally {
          connection.disconnect()
        }
      }

      else -> throw OtaSdkException("不支持的下载协议：${remoteUri.scheme ?: ""}")
    }
  }

  /** 从已校验的旧 Release 流式复制到新的 staging 文件。 */
  @JvmStatic
  @Throws(IOException::class, InterruptedException::class)
  fun copyAndHash(sourcePath: File, destinationPath: File): StreamResult {
    if (!sourcePath.isFile) {
      throw IOException("Bundle 源文件不存在：$sourcePath")
    }
    FileInputStream(sourcePath).use { inputStream ->
      return writeAndHash(inputStream, destinationPath)
    }
  }

  @JvmStatic
  @Throws(IOException::class, InterruptedException::class)
  fun writeAndHash(inputStream: InputStream, destinationPath: File): StreamResult {
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
          bytes += readCount.toLong()
          digest.update(buffer, 0, readCount)
          outputStream.write(buffer, 0, readCount)
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
    }
    return StreamResult(bytes, formatSha256(digest.digest()))
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
