package com.ota.android.sdk

import java.io.File
import java.io.FileOutputStream
import java.math.BigInteger
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

class OtaSelectionException(code: String) : OtaSdkException("OTA selection: $code", null, code)

enum class OtaSelectionKind(val wireValue: String) { FULL("full"), GRAY("gray") }
enum class OtaSelectionAction(val wireValue: String) {
  USE_RELEASE("use_release"), USE_EMBEDDED("use_embedded"), NO_COMPATIBLE_RELEASE("no_compatible_release")
}

data class OtaVersionCodeRange(val min: String? = null, val max: String? = null) {
  fun toJsonMap(): Map<String, Any?> = mapOf("min" to min, "max" to max)
  companion object {
    fun fromJsonMap(map: Map<String, Any?>): OtaVersionCodeRange {
      OtaSelectionJson.validateRangeKeys(map)
      return OtaVersionCodeRange(OtaSelectionJson.optionalString(map, "min"), OtaSelectionJson.optionalString(map, "max"))
    }
  }
}

data class OtaSelectionMetadata(
  val kind: OtaSelectionKind,
  val ruleId: String? = null,
  val policyRevision: String,
  val reason: String,
) {
  fun toJsonMap(): Map<String, Any?> = mapOf("kind" to kind.wireValue, "ruleId" to ruleId, "policyRevision" to policyRevision, "reason" to reason)
  companion object {
    fun fromJsonMap(map: Map<String, Any?>): OtaSelectionMetadata = OtaSelectionMetadata(
      OtaSelectionKind.entries.firstOrNull { it.wireValue == map["kind"] } ?: throw OtaSelectionException("invalid_selection_metadata"),
      OtaSelectionJson.optionalString(map, "ruleId"), OtaSelectionJson.string(map, "policyRevision"), OtaSelectionJson.string(map, "reason"),
    )
  }
}

data class OtaStoredSelection(
  val kind: OtaSelectionKind,
  val audienceKey: String?,
  val ruleId: String?,
  val releaseSequence: String,
  val policyRevision: String,
  val versionCodeRange: OtaVersionCodeRange?,
  val lynxSdkRange: OtaModels.ReleaseVersionRange?,
  val minAppVersion: String?,
  val maxAppVersion: String?,
  val nativeProtocolVersionRange: OtaModels.ReleaseVersionRange?,
) {
  fun compatible(context: OtaUserContext): Boolean = runCatching {
    OtaSelectionValidation.decimal(releaseSequence)
    OtaSelectionValidation.decimal(policyRevision, allowZero = true)
    (kind != OtaSelectionKind.GRAY || (context.userId != null && audienceKey == context.audienceKey)) &&
      OtaSelectionValidation.matchesCode(context.versionCode, versionCodeRange) &&
      OtaSelectionValidation.matchesVersion(context.lynxSdkVersion, lynxSdkRange, strict = true) &&
      OtaSelectionValidation.matchesVersion(context.appVersion, OtaModels.ReleaseVersionRange(minAppVersion, maxAppVersion)) &&
      OtaSelectionValidation.matchesVersion(context.nativeProtocolVersion, nativeProtocolVersionRange)
  }.getOrDefault(false)

  fun toJsonMap(): Map<String, Any?> = mapOf(
    "kind" to kind.wireValue, "audienceKey" to audienceKey, "ruleId" to ruleId,
    "releaseSequence" to releaseSequence, "policyRevision" to policyRevision,
    "versionCodeRange" to versionCodeRange?.toJsonMap(), "lynxSdkRange" to OtaSelectionJson.rangeMap(lynxSdkRange),
    "minAppVersion" to minAppVersion, "maxAppVersion" to maxAppVersion,
    "nativeProtocolVersionRange" to OtaSelectionJson.rangeMap(nativeProtocolVersionRange),
  )

  companion object {
    fun fromLatest(latest: OtaModels.LatestBundleList, context: OtaUserContext): OtaStoredSelection {
      val metadata = latest.selection ?: throw OtaSelectionException("missing_selection_metadata")
      val sequence = latest.releaseSequence ?: throw OtaSelectionException("missing_selection_metadata")
      if (latest.selectionSchemaVersion != 1) throw OtaSelectionException("missing_selection_metadata")
      if (latest.env != context.env || latest.hostApp != context.hostApp || latest.platform != context.platform ||
        latest.status != OtaModels.ReleaseStatus.ACTIVE || !Regex("^[0-9]{8}$").matches(latest.lynxAppId)
      ) throw OtaSelectionException("invalid_selection_metadata")
      OtaSelectionValidation.decimal(sequence)
      OtaSelectionValidation.decimal(metadata.policyRevision, allowZero = true)
      if (metadata.reason !in setOf("latest_full", "matched_gray", "server_rollback") ||
        (metadata.kind == OtaSelectionKind.GRAY && (context.userId == null || metadata.ruleId.isNullOrBlank()))
      ) throw OtaSelectionException("invalid_selection_metadata")
      OtaSelectionValidation.validateCodeRange(latest.versionCodeRange)
      OtaSelectionValidation.validateSDKRange(latest.lynxSdkRange)
      return OtaStoredSelection(metadata.kind, if (metadata.kind == OtaSelectionKind.GRAY) context.audienceKey else null,
        metadata.ruleId, sequence, metadata.policyRevision, latest.versionCodeRange, latest.lynxSdkRange,
        latest.minAppVersion, latest.maxAppVersion, latest.nativeProtocolVersionRange)
    }

    fun fromJsonMap(map: Map<String, Any?>): OtaStoredSelection = OtaStoredSelection(
      OtaSelectionKind.entries.firstOrNull { it.wireValue == map["kind"] } ?: throw OtaSelectionException("invalid_selection_metadata"),
      OtaSelectionJson.optionalString(map, "audienceKey"), OtaSelectionJson.optionalString(map, "ruleId"),
      OtaSelectionJson.string(map, "releaseSequence"), OtaSelectionJson.string(map, "policyRevision"),
      map["versionCodeRange"]?.let { OtaVersionCodeRange.fromJsonMap(OtaJson.asObject(it, "versionCodeRange")) },
      OtaSelectionJson.range(map["lynxSdkRange"]), OtaSelectionJson.optionalString(map, "minAppVersion"),
      OtaSelectionJson.optionalString(map, "maxAppVersion"), OtaSelectionJson.range(map["nativeProtocolVersionRange"]),
    )
  }
}

data class OtaSelectionDirective(val lynxAppId: String, val action: OtaSelectionAction, val policyRevision: String, val reason: String) {
  fun validate() {
    if (!Regex("^[0-9]{8}$").matches(lynxAppId) || action == OtaSelectionAction.USE_RELEASE) throw OtaSelectionException("invalid_selection_metadata")
    OtaSelectionValidation.decimal(policyRevision, allowZero = true)
  }
  fun toJsonMap(): Map<String, Any?> = mapOf("lynxAppId" to lynxAppId, "action" to action.wireValue, "policyRevision" to policyRevision, "reason" to reason)
  companion object {
    fun fromJsonMap(map: Map<String, Any?>): OtaSelectionDirective = OtaSelectionDirective(
      OtaSelectionJson.string(map, "lynxAppId"), OtaSelectionJson.action(map),
      OtaSelectionJson.string(map, "policyRevision"), OtaSelectionJson.string(map, "reason"),
    )
  }
}

data class OtaLastDecision(
  val audienceKey: String, val clientContextKey: String, val policyRevision: String,
  val action: OtaSelectionAction, val targetReleaseId: String?, val reason: String,
) {
  fun toJsonMap(): Map<String, Any?> = mapOf("audienceKey" to audienceKey, "clientContextKey" to clientContextKey,
    "policyRevision" to policyRevision, "action" to action.wireValue, "targetReleaseId" to targetReleaseId, "reason" to reason)
  companion object {
    fun fromJsonMap(map: Map<String, Any?>): OtaLastDecision = OtaLastDecision(
      OtaSelectionJson.string(map, "audienceKey"), OtaSelectionJson.string(map, "clientContextKey"),
      OtaSelectionJson.string(map, "policyRevision"), OtaSelectionJson.action(map),
      OtaSelectionJson.optionalString(map, "targetReleaseId"), OtaSelectionJson.string(map, "reason"),
    )
  }
}

sealed class OtaLatestSelection {
  data class Release(val bundleList: OtaModels.LatestBundleList) : OtaLatestSelection()
  data class Directive(val directive: OtaSelectionDirective) : OtaLatestSelection()
}

class OtaAppBundleListSyncFailure(val stage: Stage, val cause: Throwable) {
  enum class Stage { DECISION, UPDATE }
  override fun toString(): String = "OTA App sync failed during $stage"
}
class OtaHostBundleListSyncException(
  val partialResult: OtaModels.HostBundleListSyncResult,
  val failures: Map<String, OtaAppBundleListSyncFailure>,
) : OtaSdkException("OTA batch sync failed for ${failures.size} App(s)", null, "partial_batch_failure")

data class OtaUserContext internal constructor(
  val userId: String?, val identityEpoch: Long, val audienceKey: String, val clientContextKey: String,
  val env: OtaModels.Environment, val hostApp: OtaModels.HostApp, val platform: OtaModels.Platform,
  val versionCode: String?, val lynxSdkVersion: String?, val appVersion: String?, val nativeProtocolVersion: String?,
  internal val ownerId: UUID,
) {
  val selectionEnabled: Boolean get() = versionCode != null
  companion object {
    @JvmStatic fun normalizeUserId(raw: String?): String? = OtaSelectionValidation.userId(raw)
    @JvmStatic fun normalizeVersionCode(raw: String): String = OtaSelectionValidation.decimal(raw).toString()
    @JvmStatic fun normalizeLynxSdkVersion(raw: String): String = OtaSelectionValidation.sdk(raw)
  }
}

internal object OtaSelectionValidation {
  private const val TRIM = "\u0009\u000a\u000b\u000c\u000d\u0020\u00a0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200a\u2028\u2029\u202f\u205f\u3000\ufeff"
  private val MAX = BigInteger.valueOf(Long.MAX_VALUE)
  private fun digits(raw: String): String {
    if (raw.isEmpty() || raw.any { it !in '0'..'9' }) throw OtaSelectionException("invalid_version_code")
    return raw.trimStart('0').ifEmpty { "0" }
  }
  fun userId(raw: String?): String? {
    if (raw == null) return null
    if (raw.any { it.code <= 31 || it.code in 127..159 }) throw OtaSelectionException("invalid_user_id")
    val value = raw.trim { it in TRIM }
    if (value.toByteArray(Charsets.UTF_8).size > 256) throw OtaSelectionException("invalid_user_id")
    return value.ifEmpty { null }
  }
  fun decimal(raw: String, allowZero: Boolean = false): Long {
    val value = BigInteger(digits(raw.trim { it in TRIM }))
    if (value > MAX || value < BigInteger.valueOf(if (allowZero) 0L else 1L)) throw OtaSelectionException("invalid_version_code")
    return value.toLong()
  }
  fun sdk(raw: String): String {
    val pieces = raw.trim { it in TRIM }.split('.')
    if (pieces.size !in 1..3) throw OtaSelectionException("invalid_sdk_version")
    val normalized = try { pieces.map(::digits) } catch (_: Exception) { throw OtaSelectionException("invalid_sdk_version") }
    return (normalized + List(3 - normalized.size) { "0" }).joinToString(".")
  }
  fun validateCodeRange(range: OtaVersionCodeRange?) {
    if (range == null) return
    val lower = range.min?.let { decimal(it) }; val upper = range.max?.let { decimal(it) }
    if (lower != null && upper != null && lower > upper) throw OtaSelectionException("invalid_selection_metadata")
  }
  fun validateSDKRange(range: OtaModels.ReleaseVersionRange?) {
    if (range == null) return
    val lower = range.min?.let(::sdk); range.max?.let(::sdk)
    if (lower != null && !matchesVersion(lower, range, strict = true)) throw OtaSelectionException("invalid_selection_metadata")
  }
  fun matchesCode(value: String?, range: OtaVersionCodeRange?): Boolean = runCatching {
    if (range == null || (range.min == null && range.max == null)) return@runCatching true
    validateCodeRange(range)
    val number = value?.let { decimal(it) } ?: return@runCatching false
    (range.min == null || number >= decimal(range.min)) && (range.max == null || number <= decimal(range.max))
  }.getOrDefault(false)
  fun matchesVersion(value: String?, range: OtaModels.ReleaseVersionRange?, strict: Boolean = false): Boolean = runCatching {
    if (range == null || (range.min == null && range.max == null)) return@runCatching true
    fun parts(raw: String): List<BigInteger> = (if (strict) sdk(raw) else raw.trim { it in TRIM })
      .split('.').map { BigInteger(digits(it)) }
    fun compare(a: List<BigInteger>, b: List<BigInteger>): Int {
      for (index in 0 until maxOf(a.size, b.size)) {
        val order = (a.getOrNull(index) ?: BigInteger.ZERO).compareTo(b.getOrNull(index) ?: BigInteger.ZERO)
        if (order != 0) return order
      }
      return 0
    }
    val actual = value?.let(::parts) ?: return@runCatching false
    val min = range.min?.let(::parts); val max = range.max?.let(::parts)
    if (min != null && max != null && compare(min, max) > 0) return@runCatching false
    (min == null || compare(actual, min) >= 0) && (max == null || compare(actual, max) <= 0)
  }.getOrDefault(false)
  fun digest(parts: List<String>): String = MessageDigest.getInstance("SHA-256")
    .digest(OtaJson.stringify(parts).toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it.toInt() and 0xff) }
}

internal object OtaSelectionJson {
  fun string(map: Map<String, Any?>, key: String): String = map[key] as? String ?: throw OtaSelectionException("invalid_selection_metadata")
  fun optionalString(map: Map<String, Any?>, key: String): String? = if (map[key] == null) null else string(map, key)
  fun schema(map: Map<String, Any?>): Int? = map["selectionSchemaVersion"]?.let {
    if (it !is Number || it.toDouble() != 1.0) throw OtaSelectionException("invalid_selection_metadata")
    1
  }
  fun action(map: Map<String, Any?>): OtaSelectionAction = OtaSelectionAction.entries.firstOrNull { it.wireValue == map["action"] }
    ?: throw OtaSelectionException("invalid_selection_metadata")
  fun validateRangeKeys(map: Map<String, Any?>) {
    if (map.any { (key, value) -> key !in setOf("min", "max") || value !is String }) throw OtaSelectionException("invalid_selection_metadata")
  }
  fun range(value: Any?): OtaModels.ReleaseVersionRange? = value?.let {
    val map = OtaJson.asObject(it, "version range"); validateRangeKeys(map)
    OtaModels.ReleaseVersionRange(optionalString(map, "min"), optionalString(map, "max"))
  }
  fun rangeMap(range: OtaModels.ReleaseVersionRange?): Map<String, Any?>? = range?.let { mapOf("min" to it.min, "max" to it.max) }
}

/** Explicit propagation is required for Executor workers; ThreadLocal is restored in finally. */
internal object OtaOperationContext {
  data class Snapshot(val identity: OtaUserContext?, val selection: OtaStoredSelection?, val expectedCandidate: String?, val expectedCurrent: String? = null)
  private val local = ThreadLocal<Snapshot?>()
  val identity: OtaUserContext? get() = local.get()?.identity
  val selection: OtaStoredSelection? get() = local.get()?.selection
  val expectedCandidate: String? get() = local.get()?.expectedCandidate
  val expectedCurrent: String? get() = local.get()?.expectedCurrent
  fun snapshot(): Snapshot = local.get() ?: Snapshot(null, null, null)
  fun <T> withSnapshot(value: Snapshot, operation: () -> T): T {
    val previous = local.get()
    local.set(value)
    try { return operation() } finally { if (previous == null) local.remove() else local.set(previous) }
  }
  fun <T> withIdentity(value: OtaUserContext, operation: () -> T): T = withSnapshot(snapshot().copy(identity = value), operation)
  fun <T> withSelection(value: OtaStoredSelection, operation: () -> T): T = withSnapshot(snapshot().copy(selection = value), operation)
  fun <T> withCandidate(value: String?, operation: () -> T): T = withSnapshot(snapshot().copy(expectedCandidate = value), operation)
  fun <T> withCurrentRelease(value: String?, operation: () -> T): T = withSnapshot(snapshot().copy(expectedCurrent = value), operation)
}

internal class OtaUserContextBox(private val configuration: OtaModels.Configuration) {
  private val lock = ReentrantLock()
  private val owner = UUID.randomUUID()
  private var userId = OtaUserContext.normalizeUserId(configuration.userId)
  private var epoch = 0L
  val enabled: Boolean get() = configuration.versionCode != null
  val identityEpoch: Long get() = lock.withLock { epoch }
  fun register(raw: String?): Boolean {
    val value = OtaUserContext.normalizeUserId(raw)
    return lock.withLock {
      if (value == userId) false else {
        if (epoch == Long.MAX_VALUE) throw OtaSelectionException("stale_identity")
        userId = value; epoch += 1L; true
      }
    }
  }
  fun invalidate() = lock.withLock {
    if (epoch == Long.MAX_VALUE) throw OtaSelectionException("stale_identity")
    epoch += 1L
  }
  fun capture(): OtaUserContext {
    val code = configuration.versionCode?.let(OtaUserContext::normalizeVersionCode)
    val sdk = if (code != null) OtaUserContext.normalizeLynxSdkVersion(configuration.lynxSdkVersion ?: throw OtaSelectionException("invalid_sdk_version")) else configuration.lynxSdkVersion
    val salt = installationSalt()
    return lock.withLock {
      val audience = OtaSelectionValidation.digest(listOf(salt, configuration.environment.wireValue, configuration.hostApp.wireValue, userId?.let { "user:$it" } ?: "anonymous"))
      val key = OtaSelectionValidation.digest(listOf(audience, configuration.platform.wireValue, code ?: "legacy", sdk.orEmpty(), configuration.appVersion.orEmpty(), configuration.nativeProtocolVersion.orEmpty()))
      OtaUserContext(userId, epoch, audience, key, configuration.environment, configuration.hostApp, configuration.platform,
        code, sdk, configuration.appVersion, configuration.nativeProtocolVersion, owner)
    }
  }
  fun operation(): OtaUserContext = (OtaOperationContext.identity ?: capture()).also(::validate)
  fun validate(expected: OtaUserContext) { withCurrent(expected) {} }
  fun <T> withCurrent(expected: OtaUserContext, operation: () -> T): T = lock.withLock {
    if (expected.ownerId != owner || expected.identityEpoch != epoch || expected.userId != userId) throw OtaSelectionException("stale_identity")
    operation()
  }
  private fun installationSalt(): String {
    if (!enabled) return "legacy"
    val path = File(configuration.storageDirectory, "selection-salt").canonicalFile
    return SALT_LOCKS.computeIfAbsent(path.path) { ReentrantLock() }.withLock {
      if (path.isFile) return@withLock path.readText(Charsets.UTF_8)
      path.parentFile?.mkdirs()
      val salt = UUID.randomUUID().toString()
      FileOutputStream(path).use { it.write(salt.toByteArray(Charsets.UTF_8)); it.fd.sync() }
      salt
    }
  }
  private companion object { val SALT_LOCKS = ConcurrentHashMap<String, ReentrantLock>() }
}
