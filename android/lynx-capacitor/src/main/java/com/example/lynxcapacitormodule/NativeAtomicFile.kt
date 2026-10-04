package com.example.lynxcapacitormodule

import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID

internal object NativeAtomicFile {
    fun publish(temporary: File, target: File) {
        NativeCallContext.commit {
            Files.move(temporary.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        }
    }
    fun write(target: File, bytes: ByteArray, beforePublish: () -> Unit = {}) {
        NativeCallContext.checkActive()
        target.parentFile?.mkdirs()
        val temporary = File(target.parentFile, ".${target.name}.${UUID.randomUUID()}.part")
        try {
            FileOutputStream(temporary).use { output -> output.write(bytes); output.fd.sync() }
            beforePublish()
            publish(temporary, target)
        } finally { temporary.delete() }
    }
}
