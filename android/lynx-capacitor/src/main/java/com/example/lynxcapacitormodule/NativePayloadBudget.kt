package com.example.lynxcapacitormodule

import java.io.InputStream
import java.io.ByteArrayOutputStream
import java.io.OutputStream

internal object NativePayloadBudget {
    const val REQUEST_BYTES = 1024 * 1024
    const val INLINE_BYTES = 512 * 1024
    const val RESULT_BYTES = 2 * 1024 * 1024
    const val DOWNLOAD_BYTES = 20L * 1024 * 1024
    const val IMAGE_PIXELS = 16_777_216L
    const val IMAGE_EDGE = 4096
    fun check(bytes: Long, limit: Long, code: String = "PAYLOAD_TOO_LARGE") {
        if (bytes > limit) throw NativeBudgetExceeded(code, "数据超过 $limit 字节限制，请使用 URI")
    }
    fun checkImage(width: Int, height: Int) {
        if (width <= 0 || height <= 0) throw NativeBudgetExceeded("INVALID_IMAGE", "图片尺寸无效")
        if (width > IMAGE_EDGE || height > IMAGE_EDGE || width.toLong() * height > IMAGE_PIXELS) {
            throw NativeBudgetExceeded("IMAGE_TOO_LARGE", "图片超过 4096 边长或 16777216 像素限制")
        }
    }
    fun copy(input: InputStream, output: OutputStream, limit: Long = Long.MAX_VALUE): Long {
        var total = 0L
        val buffer = ByteArray(8192)
        while (true) {
            NativeCallContext.checkActive()
            val count = input.read(buffer)
            if (count < 0) break
            NativeCallContext.checkActive()
            check(total + count, limit)
            output.write(buffer, 0, count)
            total += count
        }
        NativeCallContext.checkActive()
        output.flush()
        return total
    }
    fun read(input: InputStream, limit: Int = INLINE_BYTES): ByteArray {
        val output = ByteArrayOutputStream(minOf(limit, 8192))
        val buffer = ByteArray(8192)
        while (true) {
            NativeCallContext.checkActive()
            val count = input.read(buffer)
            if (count < 0) break
            check(output.size().toLong() + count, limit.toLong())
            output.write(buffer, 0, count)
        }
        return output.toByteArray()
    }
}
