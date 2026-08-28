package com.ota.android.sdk

import java.io.File
import java.net.URI
import java.time.Instant
import java.util.Collections

class OtaModels private constructor() {
  companion object {
    const val DEFAULT_LYNX_APP_ID = "10000000"
    const val DEFAULT_OTA_CLIENT_TOKEN = "ota-client-token-v1-fixed"
    const val MAX_BUNDLE_BYTES = 20 * 1024 * 1024
    private val LYNX_APP_ID_PATTERN = Regex("^[0-9]{8}$")

    @JvmStatic
    fun firstPresent(map: Map<String, Any?>, first: String, second: String): Any? {
      return if (map.containsKey(first)) map[first] else map[second]
    }

    @JvmStatic
    fun stringValue(value: Any?): String {
      if (value == null) {
        throw IllegalArgumentException("字段不能为空")
      }
      return value.toString()
    }

    @JvmStatic
    fun optionalString(value: Any?, fallback: String?): String? {
      return value?.toString() ?: fallback
    }

    @JvmStatic
    fun intValue(value: Any?): Int {
      if (value is Number) {
        return value.toInt()
      }
      return value.toString().toInt()
    }

    @JvmStatic
    fun optionalInt(value: Any?): Int? {
      return if (value == null) null else intValue(value)
    }

    /** OTA Server 契约中的 App ID 是 8 位数字，可直接作为跨平台无碰撞目录段。 */
    @JvmStatic
    fun requireLynxAppId(raw: String): String {
      require(LYNX_APP_ID_PATTERN.matches(raw)) {
        "lynxAppId 必须是 8 位数字：$raw"
      }
      return raw
    }

    @JvmStatic
    fun <T> immutableList(items: List<T>?): List<T> {
      return Collections.unmodifiableList(ArrayList(items ?: emptyList()))
    }

    @JvmStatic
    fun <T> singletonList(item: T): List<T> {
      val items = ArrayList<T>()
      items.add(item)
      return items
    }
  }

  object ReasonCodes {
    const val BASELINE_BLOCKED = "baseline_blocked"
    const val LATEST_BUNDLE_LIST_FETCH_FAILED = "latest_bundle_list_fetch_failed"
    const val LATEST_BUNDLE_LIST_DECODE_FAILED = "latest_bundle_list_decode_failed"
    const val LOCAL_BUNDLE_MISSING = "local_bundle_missing"
    const val BUNDLE_DOWNLOAD_FAILED = "bundle_download_failed"
    const val BUNDLE_CHECKSUM_FAILED = "bundle_checksum_failed"
    const val RELEASE_ACTIVATE_FAILED = "release_activate_failed"
    const val MANUAL_ROLLBACK = "manual_rollback"
    const val RELEASE_DISABLED = "release_disabled"
    const val RELEASE_ROLLED_BACK = "release_rolled_back"
    const val INVALID_RELEASE_STATUS = "invalid_release_status"
    const val INVALID_BUNDLE_URL = "invalid_bundle_url"
    const val MISSING_BUNDLE_SIZE = "missing_bundle_size"
    const val INVALID_BUNDLE_SIZE = "invalid_bundle_size"
    const val BUNDLE_TOO_LARGE = "bundle_too_large"
    const val BUNDLE_SIZE_MISMATCH = "bundle_size_mismatch"
  }

  enum class Environment(@JvmField val wireValue: String) {
    TEST("TEST"),
    STAGING("STAGING"),
    PROD("PROD");

    companion object {
      @JvmStatic
      fun fromWire(raw: String): Environment {
        for (item in entries) {
          if (item.wireValue.equals(raw, ignoreCase = true)) {
            return item
          }
        }
        throw IllegalArgumentException("未知环境：$raw")
      }
    }
  }

  enum class HostApp(@JvmField val wireValue: String) {
    CAPP("capp"),
    GAPP("gapp");

    companion object {
      @JvmStatic
      fun fromWire(raw: String): HostApp {
        for (item in entries) {
          if (item.wireValue.equals(raw, ignoreCase = true)) {
            return item
          }
        }
        throw IllegalArgumentException("未知宿主 App：$raw")
      }
    }
  }

  enum class Platform(@JvmField val wireValue: String) {
    ANDROID("android"),
    IOS("ios");

    companion object {
      @JvmStatic
      fun fromWire(raw: String): Platform {
        for (item in entries) {
          if (item.wireValue.equals(raw, ignoreCase = true)) {
            return item
          }
        }
        throw IllegalArgumentException("未知平台：$raw")
      }
    }
  }

  enum class ReleaseStatus(@JvmField val wireValue: String) {
    DRAFT("DRAFT"),
    ACTIVE("ACTIVE"),
    DISABLED("DISABLED"),
    ROLLED_BACK("ROLLED_BACK");

    companion object {
      @JvmStatic
      fun fromWire(raw: String): ReleaseStatus {
        for (item in entries) {
          if (item.wireValue.equals(raw, ignoreCase = true)) {
            return item
          }
        }
        throw IllegalArgumentException("未知发布状态：$raw")
      }
    }
  }

  enum class ReportEvent(@JvmField val wireValue: String) {
    CHECK_RESULT("lynx_ota_check_result"),
    DOWNLOAD_SUCCESS("lynx_bundle_download_success"),
    ACTIVATE("lynx_release_activate"),
    PAGE_OPEN("lynx_page_open"),
    ROLLBACK("lynx_release_rollback");

    companion object {
      @JvmStatic
      fun fromWire(raw: String): ReportEvent {
        for (item in entries) {
          if (item.wireValue.equals(raw, ignoreCase = true)) {
            return item
          }
        }
        throw IllegalArgumentException("未知上报事件：$raw")
      }
    }
  }

  enum class ReportEventStage(@JvmField val wireValue: String) {
    CHECK("CHECK"),
    MATCH("MATCH"),
    MANIFEST("MANIFEST"),
    DOWNLOAD("DOWNLOAD"),
    ACTIVATE("ACTIVATE"),
    PAGE_OPEN("PAGE_OPEN"),
    ROLLBACK("ROLLBACK");

    companion object {
      @JvmStatic
      fun fromWire(raw: String): ReportEventStage {
        for (item in entries) {
          if (item.wireValue.equals(raw, ignoreCase = true)) {
            return item
          }
        }
        throw IllegalArgumentException("未知上报阶段：$raw")
      }
    }
  }

  enum class ReportEventResult(@JvmField val wireValue: String) {
    SUCCESS("SUCCESS"),
    SKIPPED("SKIPPED"),
    FAILED("FAILED");

    companion object {
      @JvmStatic
      fun fromWire(raw: String): ReportEventResult {
        for (item in entries) {
          if (item.wireValue.equals(raw, ignoreCase = true)) {
            return item
          }
        }
        throw IllegalArgumentException("未知上报结果：$raw")
      }
    }
  }

  enum class UpdateResultType {
    NO_RELEASE,
    SKIPPED,
    ALREADY_ACTIVE,
    UPDATED,
    CANDIDATE,
  }

  class ReleaseVersionRange(
    @JvmField val min: String?,
    @JvmField val max: String?,
  ) {
    companion object {
      @JvmStatic
      fun fromJsonMap(map: Map<String, Any?>): ReleaseVersionRange {
        return ReleaseVersionRange(
          optionalString(map["min"], null),
          optionalString(map["max"], null),
        )
      }
    }
  }

  class BundleArtifact(
    @JvmField val pageId: Int,
    @JvmField val bundlePath: String,
    @JvmField val bundleSha256: String,
    @JvmField val bundleUrl: URI,
    @JvmField val size: Int?,
  ) {
    fun toJsonMap(): Map<String, Any?> {
      val map = LinkedHashMap<String, Any?>()
      map["pageId"] = pageId
      map["bundlePath"] = bundlePath
      map["bundleSha256"] = bundleSha256
      map["bundleUrl"] = bundleUrl.toString()
      map["size"] = size
      return map
    }

    companion object {
      @JvmStatic
      fun fromJsonMap(map: Map<String, Any?>): BundleArtifact {
        return BundleArtifact(
          intValue(map["pageId"]),
          stringValue(map["bundlePath"]),
          stringValue(map["bundleSha256"]),
          URI.create(stringValue(map["remoteUrl"] ?: firstPresent(map, "bundleUrl", "bundleURL"))),
          optionalInt(map["size"]),
        )
      }
    }
  }

  class ReleaseManifest(
    @JvmField val env: Environment,
    @JvmField val hostApp: HostApp,
    lynxAppId: String?,
    @JvmField val releaseId: String,
    @JvmField val platform: Platform,
    platforms: List<Platform>?,
    bundles: List<BundleArtifact>?,
    @JvmField val status: ReleaseStatus = ReleaseStatus.ACTIVE,
  ) {
    @JvmField val lynxAppId: String = lynxAppId ?: DEFAULT_LYNX_APP_ID
    @JvmField val platforms: List<Platform> = immutableList(if (platforms.isNullOrEmpty()) singletonList(platform) else platforms)
    @JvmField val bundles: List<BundleArtifact> = immutableList(bundles)

    fun toJsonMap(): Map<String, Any?> {
      val map = LinkedHashMap<String, Any?>()
      map["env"] = env.wireValue
      map["hostApp"] = hostApp.wireValue
      map["lynxAppId"] = lynxAppId
      map["releaseId"] = releaseId
      map["platform"] = platform.wireValue
      map["platforms"] = platforms.map { it.wireValue }
      map["status"] = status.wireValue
      map["bundles"] = bundles.map { it.toJsonMap() }
      return map
    }

    companion object {
      @JvmStatic
      fun fromJsonMap(map: Map<String, Any?>, requireStatus: Boolean = false): ReleaseManifest {
        val parsedPlatforms = ArrayList<Platform>()
        val rawPlatforms = map["platforms"]
        if (rawPlatforms is List<*>) {
          for (item in rawPlatforms) {
            parsedPlatforms.add(Platform.fromWire(stringValue(item)))
          }
        }

        val parsedBundles = ArrayList<BundleArtifact>()
        for (item in OtaJson.asArray(map["bundles"], "bundles")) {
          parsedBundles.add(BundleArtifact.fromJsonMap(OtaJson.asObject(item, "bundle")))
        }

        val parsedPlatform = Platform.fromWire(stringValue(map["platform"]))
        val rawStatus = map["status"]?.toString()
        if (requireStatus && rawStatus.isNullOrBlank()) {
          throw IllegalArgumentException("Manifest status 不能为空")
        }
        return ReleaseManifest(
          Environment.fromWire(stringValue(map["env"])),
          HostApp.fromWire(stringValue(firstPresent(map, "hostApp", "app"))),
          optionalString(map["lynxAppId"], DEFAULT_LYNX_APP_ID),
          stringValue(map["releaseId"]),
          parsedPlatform,
          if (parsedPlatforms.isEmpty()) singletonList(parsedPlatform) else parsedPlatforms,
          parsedBundles,
          rawStatus?.let { ReleaseStatus.fromWire(it) } ?: ReleaseStatus.ACTIVE,
        )
      }
    }
  }

  class PolicyMatchRequest(
    @JvmField val env: Environment,
    @JvmField val hostApp: HostApp,
    @JvmField val lynxAppId: String,
    @JvmField val platform: Platform,
    @JvmField val appVersion: String,
    @JvmField val buildNumber: String,
    @JvmField val osVersion: String?,
    @JvmField val channel: String?,
    @JvmField val region: String?,
    @JvmField val userId: String?,
    @JvmField val deviceId: String?,
    @JvmField val pageId: Int,
    @JvmField val nativeProtocolVersion: String?,
    @JvmField val lynxSdkVersion: String?,
  ) {
    fun toJsonMap(): Map<String, Any?> {
      val map = LinkedHashMap<String, Any?>()
      map["env"] = env.wireValue
      map["hostApp"] = hostApp.wireValue
      map["lynxAppId"] = lynxAppId
      map["platform"] = platform.wireValue
      map["appVersion"] = appVersion
      map["buildNumber"] = buildNumber
      map["osVersion"] = osVersion
      map["channel"] = channel
      map["region"] = region
      map["userId"] = userId
      map["deviceId"] = deviceId
      map["pageId"] = pageId
      map["nativeProtocolVersion"] = nativeProtocolVersion
      map["lynxSdkVersion"] = lynxSdkVersion
      return map
    }
  }

  class PolicyMatchResponse(
    @JvmField val matched: Boolean,
    @JvmField val releaseId: String?,
    @JvmField val manifestUrl: String?,
    @JvmField val ruleId: String?,
    @JvmField val fallbackToEmbedded: Boolean?,
    @JvmField val reasonCode: String?,
  ) {
    fun toJsonMap(): Map<String, Any?> {
      val map = LinkedHashMap<String, Any?>()
      map["matched"] = matched
      map["releaseId"] = releaseId
      map["manifestUrl"] = manifestUrl
      map["ruleId"] = ruleId
      map["fallbackToEmbedded"] = fallbackToEmbedded
      map["reasonCode"] = reasonCode
      return map
    }

    companion object {
      @JvmStatic
      fun fromJsonMap(map: Map<String, Any?>): PolicyMatchResponse {
        return PolicyMatchResponse(
          map["matched"] as? Boolean ?: false,
          optionalString(map["releaseId"], null),
          optionalString(firstPresent(map, "manifestUrl", "manifestURL"), null),
          optionalString(map["ruleId"], null),
          map["fallbackToEmbedded"] as? Boolean,
          optionalString(map["reasonCode"], null),
        )
      }
    }
  }

  class CurrentReleaseContext(
    @JvmField val env: Environment,
    @JvmField val hostApp: HostApp,
    lynxAppId: String?,
    @JvmField val releaseId: String,
    @JvmField val platform: Platform,
    @JvmField val status: ReleaseStatus,
  ) {
    @JvmField val lynxAppId: String = lynxAppId ?: DEFAULT_LYNX_APP_ID

    fun toJsonMap(): Map<String, Any?> {
      val map = LinkedHashMap<String, Any?>()
      map["env"] = env.wireValue
      map["hostApp"] = hostApp.wireValue
      map["lynxAppId"] = lynxAppId
      map["releaseId"] = releaseId
      map["platform"] = platform.wireValue
      map["status"] = status.wireValue
      return map
    }

    companion object {
      @JvmStatic
      fun fromJsonMap(map: Map<String, Any?>): CurrentReleaseContext {
        return CurrentReleaseContext(
          Environment.fromWire(stringValue(map["env"])),
          HostApp.fromWire(stringValue(firstPresent(map, "hostApp", "app"))),
          optionalString(map["lynxAppId"], DEFAULT_LYNX_APP_ID),
          stringValue(map["releaseId"]),
          Platform.fromWire(stringValue(map["platform"])),
          ReleaseStatus.fromWire(stringValue(map["status"])),
        )
      }
    }
  }

  class InstalledBundle(
    @JvmField val pageId: Int,
    @JvmField val bundlePath: String,
    @JvmField val bundleSha256: String,
    @JvmField val remoteUrl: URI,
    @JvmField val localFilePath: String,
  ) {
    fun toJsonMap(): Map<String, Any?> {
      val map = LinkedHashMap<String, Any?>()
      map["pageId"] = pageId
      map["bundlePath"] = bundlePath
      map["bundleSha256"] = bundleSha256
      map["remoteURL"] = remoteUrl.toString()
      map["remoteUrl"] = remoteUrl.toString()
      map["localFilePath"] = localFilePath
      return map
    }

    companion object {
      @JvmStatic
      fun fromJsonMap(map: Map<String, Any?>): InstalledBundle {
        return InstalledBundle(
          intValue(map["pageId"]),
          stringValue(map["bundlePath"]),
          stringValue(map["bundleSha256"]),
          URI.create(stringValue(firstPresent(map, "remoteURL", "remoteUrl"))),
          stringValue(map["localFilePath"]),
        )
      }
    }
  }

  class InstalledRelease(
    @JvmField val context: CurrentReleaseContext,
    @JvmField val installedAt: Instant,
    bundles: List<InstalledBundle>?,
  ) {
    @JvmField val bundles: List<InstalledBundle> = immutableList(bundles)

    fun toJsonMap(): Map<String, Any?> {
      val map = LinkedHashMap<String, Any?>()
      map["context"] = context.toJsonMap()
      map["installedAt"] = installedAt.toString()
      val bundleMaps = ArrayList<Map<String, Any?>>()
      for (bundle in bundles) {
        bundleMaps.add(bundle.toJsonMap())
      }
      map["bundles"] = bundleMaps
      return map
    }

    companion object {
      @JvmStatic
      fun fromJsonMap(map: Map<String, Any?>): InstalledRelease {
        val bundles = ArrayList<InstalledBundle>()
        for (item in OtaJson.asArray(map["bundles"], "bundles")) {
          bundles.add(InstalledBundle.fromJsonMap(OtaJson.asObject(item, "bundle")))
        }
        return InstalledRelease(
          CurrentReleaseContext.fromJsonMap(OtaJson.asObject(map["context"], "context")),
          Instant.parse(stringValue(map["installedAt"])),
          bundles,
        )
      }
    }
  }

  /** 已完成下载和完整性校验、但尚未替换 current 的候选 Release。 */
  enum class CandidateStatus(@JvmField val wireValue: String) {
    PENDING("pending"),
    TRIAL("trial");

    companion object {
      @JvmStatic
      fun fromWire(raw: String): CandidateStatus {
        return entries.firstOrNull { it.wireValue.equals(raw, ignoreCase = true) }
          ?: throw IllegalArgumentException("未知候选状态：$raw")
      }
    }
  }

  class CandidateSnapshot(
    @JvmField val release: InstalledRelease,
    @JvmField val status: CandidateStatus,
    @JvmField val failureCount: Int,
    @JvmField val createdAt: Instant,
    @JvmField val trialStartedAt: Instant?,
  )

  class ReportPayload(
    @JvmField val env: Environment,
    @JvmField val hostApp: HostApp,
    @JvmField val lynxAppId: String?,
    @JvmField val releaseId: String?,
    @JvmField val platform: Platform,
    @JvmField val event: ReportEvent,
    @JvmField val pageId: Int?,
    @JvmField val userId: String?,
    @JvmField val deviceId: String?,
    @JvmField val deviceModel: String?,
    @JvmField val appVersion: String?,
    @JvmField val buildNumber: String?,
    @JvmField val osVersion: String?,
    @JvmField val channel: String?,
    @JvmField val region: String?,
    @JvmField val nativeProtocolVersion: String?,
    @JvmField val lynxSdkVersion: String?,
    @JvmField val bundlePath: String?,
    @JvmField val bundleSha256: String?,
    @JvmField val bundleSize: Int?,
    @JvmField val eventStage: ReportEventStage?,
    @JvmField val eventResult: ReportEventResult?,
    @JvmField val reasonCode: String?,
    @JvmField val reasonMessage: String?,
    @JvmField val fromReleaseId: String?,
    @JvmField val toReleaseId: String?,
    @JvmField val latencyMs: Int?,
    @JvmField val message: String?,
  ) {
    fun toJsonMap(): Map<String, Any?> {
      val map = LinkedHashMap<String, Any?>()
      map["env"] = env.wireValue
      map["hostApp"] = hostApp.wireValue
      map["lynxAppId"] = lynxAppId
      if (!releaseId.isNullOrBlank()) {
        map["releaseId"] = releaseId
      }
      map["platform"] = platform.wireValue
      map["event"] = event.wireValue
      map["pageId"] = pageId
      map["userId"] = userId
      map["deviceId"] = deviceId
      map["deviceModel"] = deviceModel
      map["appVersion"] = appVersion
      map["buildNumber"] = buildNumber
      map["osVersion"] = osVersion
      map["channel"] = channel
      map["region"] = region
      map["nativeProtocolVersion"] = nativeProtocolVersion
      map["lynxSdkVersion"] = lynxSdkVersion
      map["bundlePath"] = bundlePath
      map["bundleSha256"] = bundleSha256
      map["bundleSize"] = bundleSize
      map["eventStage"] = eventStage?.wireValue
      map["eventResult"] = eventResult?.wireValue
      map["reasonCode"] = reasonCode
      map["reasonMessage"] = reasonMessage
      map["fromReleaseId"] = fromReleaseId
      map["toReleaseId"] = toReleaseId
      map["latencyMs"] = latencyMs
      map["message"] = message
      return map
    }
  }

  class ReportResponse(
    @JvmField val accepted: Boolean,
    @JvmField val releaseId: String?,
    @JvmField val event: ReportEvent,
  ) {
    fun toJsonMap(): Map<String, Any?> {
      val map = LinkedHashMap<String, Any?>()
      map["accepted"] = accepted
      map["releaseId"] = releaseId
      map["event"] = event.wireValue
      return map
    }

    companion object {
      @JvmStatic
      fun fromJsonMap(map: Map<String, Any?>): ReportResponse {
        return ReportResponse(
          map["accepted"] as? Boolean ?: false,
          optionalString(map["releaseId"], null),
          ReportEvent.fromWire(stringValue(map["event"])),
        )
      }
    }
  }

  class LatestBundleList(
    @JvmField val env: Environment,
    @JvmField val hostApp: HostApp,
    lynxAppId: String?,
    @JvmField val releaseId: String,
    @JvmField val platform: Platform,
    platforms: List<Platform>?,
    @JvmField val status: ReleaseStatus,
    @JvmField val updatedAt: String?,
    @JvmField val minAppVersion: String?,
    @JvmField val maxAppVersion: String?,
    @JvmField val lynxSdkRange: ReleaseVersionRange?,
    @JvmField val nativeProtocolVersionRange: ReleaseVersionRange?,
    changedBundles: List<BundleArtifact>?,
  ) {
    @JvmField val lynxAppId: String = lynxAppId ?: DEFAULT_LYNX_APP_ID
    @JvmField val platforms: List<Platform> = immutableList(if (platforms.isNullOrEmpty()) singletonList(platform) else platforms)
    @JvmField val changedBundles: List<BundleArtifact> = immutableList(changedBundles)

    fun asManifest(): ReleaseManifest {
      return ReleaseManifest(env, hostApp, lynxAppId, releaseId, platform, platforms, changedBundles, status)
    }

    companion object {
      @JvmStatic
      fun fromJsonMap(map: Map<String, Any?>): LatestBundleList {
        val parsedPlatforms = ArrayList<Platform>()
        val rawPlatforms = map["platforms"]
        if (rawPlatforms is List<*>) {
          for (item in rawPlatforms) {
            parsedPlatforms.add(Platform.fromWire(stringValue(item)))
          }
        }
        val bundles = ArrayList<BundleArtifact>()
        for (item in OtaJson.asArray(map["changedBundles"], "changedBundles")) {
          bundles.add(BundleArtifact.fromJsonMap(OtaJson.asObject(item, "bundle")))
        }
        val platform = Platform.fromWire(stringValue(map["platform"]))
        return LatestBundleList(
          Environment.fromWire(stringValue(map["env"])),
          HostApp.fromWire(stringValue(firstPresent(map, "hostApp", "app"))),
          optionalString(map["lynxAppId"], DEFAULT_LYNX_APP_ID),
          stringValue(map["releaseId"]),
          platform,
          if (parsedPlatforms.isEmpty()) singletonList(platform) else parsedPlatforms,
          ReleaseStatus.fromWire(stringValue(map["status"])),
          optionalString(map["updatedAt"], null),
          optionalString(map["minAppVersion"], null),
          optionalString(map["maxAppVersion"], null),
          map["lynxSdkRange"]?.let { ReleaseVersionRange.fromJsonMap(OtaJson.asObject(it, "lynxSdkRange")) },
          map["nativeProtocolVersionRange"]?.let {
            ReleaseVersionRange.fromJsonMap(OtaJson.asObject(it, "nativeProtocolVersionRange"))
          },
          bundles,
        )
      }
    }
  }

  class HostLatestBundleLists(
    @JvmField val env: Environment,
    @JvmField val hostApp: HostApp,
    @JvmField val platform: Platform?,
    bundleLists: List<LatestBundleList>?,
  ) {
    @JvmField val bundleLists: List<LatestBundleList> = immutableList(bundleLists)

    companion object {
      @JvmStatic
      fun fromJsonMap(map: Map<String, Any?>): HostLatestBundleLists {
        val bundleLists = ArrayList<LatestBundleList>()
        for (item in OtaJson.asArray(map["bundleLists"], "bundleLists")) {
          bundleLists.add(LatestBundleList.fromJsonMap(OtaJson.asObject(item, "bundleList")))
        }
        val platform = map["platform"]
        return HostLatestBundleLists(
          Environment.fromWire(stringValue(map["env"])),
          HostApp.fromWire(stringValue(firstPresent(map, "hostApp", "app"))),
          if (platform == null) null else Platform.fromWire(stringValue(platform)),
          bundleLists,
        )
      }
    }
  }

  class BundleSyncSummary(
    @JvmField val releaseId: String,
    @JvmField val totalBundleCount: Int,
    @JvmField val downloadedBundleCount: Int,
    @JvmField val reusedBundleCount: Int,
  )

  class LatestBundleListUpdateResult private constructor(
    @JvmField val type: UpdateResultType,
    @JvmField val current: InstalledRelease?,
    @JvmField val installed: InstalledRelease?,
    @JvmField val summary: BundleSyncSummary?,
    @JvmField val message: String?,
    @JvmField val candidate: CandidateSnapshot? = null,
  ) {
    companion object {
      @JvmStatic
      fun noRelease(current: InstalledRelease?): LatestBundleListUpdateResult {
        return LatestBundleListUpdateResult(UpdateResultType.NO_RELEASE, current, null, null, null)
      }

      @JvmStatic
      fun skipped(current: InstalledRelease?, message: String): LatestBundleListUpdateResult {
        return LatestBundleListUpdateResult(UpdateResultType.SKIPPED, current, current, null, message)
      }

      @JvmStatic
      fun alreadyActive(installed: InstalledRelease): LatestBundleListUpdateResult {
        return LatestBundleListUpdateResult(UpdateResultType.ALREADY_ACTIVE, installed, installed, null, null)
      }

      @JvmStatic
      fun updated(
        previous: InstalledRelease?,
        installed: InstalledRelease,
        summary: BundleSyncSummary,
      ): LatestBundleListUpdateResult {
        return LatestBundleListUpdateResult(UpdateResultType.UPDATED, previous, installed, summary, null)
      }

      @JvmStatic
      fun candidate(
        previous: InstalledRelease?,
        candidate: CandidateSnapshot,
        summary: BundleSyncSummary,
      ): LatestBundleListUpdateResult {
        return LatestBundleListUpdateResult(
          UpdateResultType.CANDIDATE,
          previous,
          candidate.release,
          summary,
          null,
          candidate,
        )
      }
    }
  }

  class HostBundleListSyncResult(results: Map<String, LatestBundleListUpdateResult>) {
    @JvmField val results: Map<String, LatestBundleListUpdateResult> = Collections.unmodifiableMap(LinkedHashMap(results))

    fun updatedCount(): Int = results.values.count { it.type == UpdateResultType.UPDATED }

    fun alreadyActiveCount(): Int = results.values.count { it.type == UpdateResultType.ALREADY_ACTIVE }

    fun skippedCount(): Int = results.values.count { it.type == UpdateResultType.SKIPPED }

    fun candidateCount(): Int = results.values.count { it.type == UpdateResultType.CANDIDATE }
  }

  class Configuration {
    @JvmField val apiBaseUri: URI
    @JvmField val hostApp: HostApp
    /** 全量 latest-bundle-list 不需要宿主预先知道 App ID；失败上报可为空。 */
    @JvmField val lynxAppId: String?
    @JvmField val environment: Environment
    @JvmField val platform: Platform
    @JvmField val appVersion: String?
    @JvmField val buildNumber: String?
    @JvmField val userId: String?
    @JvmField val deviceId: String?
    @JvmField val deviceModel: String?
    @JvmField val osVersion: String?
    @JvmField val channel: String?
    @JvmField val region: String?
    @JvmField val nativeProtocolVersion: String?
    @JvmField val lynxSdkVersion: String?
    @JvmField val otaClientToken: String
    /** Android 端使用 File，避免把桌面文件类型暴露到宿主工程。 */
    @JvmField val storageDirectory: File
    /** 开启后最新 Release 先进入 candidate/trial，健康确认后才替换 current。 */
    @JvmField val candidateActivationEnabled: Boolean

    constructor(
      apiBaseUri: URI,
      hostApp: HostApp,
      lynxAppId: String?,
      environment: Environment,
      platform: Platform?,
      appVersion: String?,
      buildNumber: String?,
      userId: String?,
      deviceId: String?,
      deviceModel: String?,
      osVersion: String?,
      channel: String?,
      region: String?,
      nativeProtocolVersion: String?,
      lynxSdkVersion: String?,
      storageDirectory: File,
    ) : this(
      apiBaseUri,
      hostApp,
      lynxAppId,
      environment,
      platform,
      appVersion,
      buildNumber,
      userId,
      deviceId,
      deviceModel,
      osVersion,
      channel,
      region,
      nativeProtocolVersion,
      lynxSdkVersion,
      DEFAULT_OTA_CLIENT_TOKEN,
      storageDirectory,
      false,
    )

    constructor(
      apiBaseUri: URI,
      hostApp: HostApp,
      lynxAppId: String?,
      environment: Environment,
      platform: Platform?,
      appVersion: String?,
      buildNumber: String?,
      userId: String?,
      deviceId: String?,
      deviceModel: String?,
      osVersion: String?,
      channel: String?,
      region: String?,
      nativeProtocolVersion: String?,
      lynxSdkVersion: String?,
      otaClientToken: String?,
      storageDirectory: File,
      candidateActivationEnabled: Boolean = false,
    ) {
      this.apiBaseUri = apiBaseUri
      this.hostApp = hostApp
      this.lynxAppId = lynxAppId
      this.environment = environment
      this.platform = platform ?: Platform.ANDROID
      this.appVersion = appVersion
      this.buildNumber = buildNumber
      this.userId = userId
      this.deviceId = deviceId
      this.deviceModel = deviceModel
      this.osVersion = osVersion
      this.channel = channel
      this.region = region
      this.nativeProtocolVersion = nativeProtocolVersion
      this.lynxSdkVersion = lynxSdkVersion
      this.otaClientToken = if (otaClientToken.isNullOrBlank()) DEFAULT_OTA_CLIENT_TOKEN else otaClientToken
      this.storageDirectory = storageDirectory
      this.candidateActivationEnabled = candidateActivationEnabled
      require(apiBaseUri.scheme.equals("https", ignoreCase = true) && apiBaseUri.host?.isNotBlank() == true) {
        "OTA API 必须使用 HTTPS 且包含 Host"
      }
      require(apiBaseUri.userInfo == null && apiBaseUri.query == null && apiBaseUri.fragment == null) {
        "OTA API 地址不能包含 userInfo、query 或 fragment"
      }
    }
  }
}
