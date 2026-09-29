package com.ota.android.sdk

import java.net.URI

/** Async 资源契约。路径和 SHA 在解析阶段即拒绝歧义。 */
object OtaSidecarModels {
  private val shaPattern = Regex("^sha256:[0-9a-f]{64}$")

  fun safePath(value: String, allowLeadingSlash: Boolean = false): String {
    val path = if (allowLeadingSlash && value.startsWith('/') && !value.startsWith("//")) value.drop(1) else value
    require(path.isNotEmpty() && !path.startsWith('/') && !path.contains('\\') &&
      !path.contains('?') && !path.contains('#') && path.split('/').all { it.isNotEmpty() && it != "." && it != ".." }) {
      "附属资源路径不安全：$value"
    }
    return value
  }

  private fun sha(value: Any?): String = OtaModels.stringValue(value).also {
    require(shaPattern.matches(it)) { "附属资源 SHA256 不合法" }
  }

  private fun strictInt(value: Any?): Int {
    require(value is Byte || value is Short || value is Int || value is Long) { "附属资源数字必须是 JSON 整数" }
    val number = (value as Number).toLong()
    require(number in 1..Int.MAX_VALUE.toLong()) { "附属资源数字超出范围" }
    return number.toInt()
  }

  private fun size(value: Any?): Int = strictInt(value).also {
    require(it > 0 && it <= OtaModels.MAX_BUNDLE_BYTES) { "附属资源 size 不合法" }
  }

  private fun string(value: Any?): String = OtaModels.stringValue(value).also {
    require(it.isNotBlank()) { "附属资源字段不能为空" }
  }

  data class AsyncManifestRef(val schemaVersion: Int, val url: URI, val sha256: String, val size: Int) {
    init {
      require(schemaVersion == 1 && shaPattern.matches(sha256) && size > 0 && size <= OtaModels.MAX_BUNDLE_BYTES)
    }
    fun toJsonMap(): Map<String, Any?> = mapOf("schemaVersion" to schemaVersion, "url" to url.toString(), "sha256" to sha256, "size" to size)
    companion object {
      fun fromJsonMap(map: Map<String, Any?>) = AsyncManifestRef(
        strictInt(map["schemaVersion"]), URI.create(string(map["url"])), sha(map["sha256"]), size(map["size"]),
      )
    }
  }

  enum class AsyncKind(val wireValue: String) {
    BUNDLE("bundle"), SCRIPT("script"), STYLE("style"), ASSET("asset");
    companion object {
      fun fromWire(raw: String) = entries.singleOrNull { it.wireValue == raw }
        ?: throw IllegalArgumentException("未知 Async 资源类型：$raw")
    }
  }

  data class AsyncEntry(
    val ownerBundlePath: String,
    val requestKey: String,
    val path: String,
    val url: URI,
    val sha256: String,
    val size: Int,
    val kind: AsyncKind,
  ) {
    init {
      safePath(ownerBundlePath)
      safePath(requestKey, allowLeadingSlash = true)
      safePath(path)
      require(shaPattern.matches(sha256) && size > 0 && size <= OtaModels.MAX_BUNDLE_BYTES)
    }
    fun toJsonMap(): Map<String, Any?> = mapOf(
      "ownerBundlePath" to ownerBundlePath, "requestKey" to requestKey, "path" to path,
      "url" to url.toString(), "sha256" to sha256, "size" to size, "kind" to kind.wireValue,
    )
    companion object {
      fun fromJsonMap(map: Map<String, Any?>) = AsyncEntry(
        safePath(string(map["ownerBundlePath"])), safePath(string(map["requestKey"]), true),
        safePath(string(map["path"])), URI.create(string(map["url"])), sha(map["sha256"]),
        size(map["size"]), AsyncKind.fromWire(string(map["kind"])),
      )
    }
  }

  data class AsyncManifest(val schemaVersion: Int, val entries: List<AsyncEntry>) {
    init {
      require(schemaVersion == 1 && entries.isNotEmpty())
      require(entries.map { it.ownerBundlePath to it.requestKey }.distinct().size == entries.size) { "Async requestKey 重复" }
      require(entries.groupBy { it.path }.values.all { same -> same.map { it.sha256 to it.size }.distinct().size == 1 }) {
        "Async path 对应不同对象"
      }
    }
    fun toJsonMap(): Map<String, Any?> = mapOf("schemaVersion" to schemaVersion, "entries" to entries.map(AsyncEntry::toJsonMap))
    companion object {
      fun fromJsonMap(map: Map<String, Any?>) = AsyncManifest(
        strictInt(map["schemaVersion"]),
        OtaJson.asArray(map["entries"], "async.entries").map { AsyncEntry.fromJsonMap(OtaJson.asObject(it, "async.entry")) },
      )
    }
  }
}
