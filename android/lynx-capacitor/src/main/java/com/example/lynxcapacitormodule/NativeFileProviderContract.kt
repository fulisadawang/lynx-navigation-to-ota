package com.example.lynxcapacitormodule

import android.content.Context

/** 当前 Module 独占的 FileProvider authority，避免和宿主或其它库冲突。 */
object NativeFileProviderContract {
    private const val AUTHORITY_SUFFIX = ".lynxcapacitormodule.fileprovider"

    fun authority(context: Context): String = context.packageName + AUTHORITY_SUFFIX
}
