import java.util.Properties
import java.io.File

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// 本机验收优先从环境变量读取；没有环境变量时读取被 .gitignore 忽略的本地文件。
// token 不进入源码、README 或提交记录，CI 仍然可以只通过环境变量注入。
val localOtaPropertiesFile = rootProject.file("ota.local.properties")
val localOtaToken = if (localOtaPropertiesFile.isFile) {
    Properties().also { properties ->
        localOtaPropertiesFile.inputStream().use(properties::load)
    }.getProperty("lynx.ota.clientToken").orEmpty()
} else {
    ""
}
val otaClientToken = (
    providers.environmentVariable("LYNX_OTA_CLIENT_TOKEN").orNull
        ?.takeIf { it.isNotBlank() }
        ?: localOtaToken
)
    .replace("\\", "\\\\")
    .replace("\"", "\\\"")
val candidateActivationEnabled = providers.environmentVariable("LYNX_OTA_CANDIDATE_MODE").orNull
    ?.trim()
    ?.lowercase()
    ?.let { it == "1" || it == "true" || it == "yes" || it == "on" }
    ?: false
val localOtaServerEnabled = providers.environmentVariable("LYNX_OTA_LOCAL_SERVER").orNull
    ?.trim()
    ?.lowercase()
    ?.let { it == "1" || it == "true" || it == "yes" || it == "on" }
    ?: false
val otaUserSelectionTestEnabled = providers.environmentVariable("LYNX_TEST_OTA_USER_SELECTION").orNull
    ?.trim()?.lowercase()?.let { it in setOf("1", "true", "yes", "on") } ?: false
val otaDebugVersionCode = providers.environmentVariable("LYNX_OTA_DEBUG_VERSION_CODE").orNull?.let {
    it.toIntOrNull()?.takeIf { value -> value > 0 }
        ?: error("LYNX_OTA_DEBUG_VERSION_CODE 必须为正整数，例如 1000")
}
require(!otaUserSelectionTestEnabled || localOtaServerEnabled) {
    "用户灰度验收必须同时设置 LYNX_OTA_LOCAL_SERVER=1"
}
val localOtaBaseUrl = providers.environmentVariable("LYNX_OTA_LOCAL_BASE_URL").orNull
    ?.takeIf { it.isNotBlank() }
    ?: if (otaUserSelectionTestEnabled) "http://127.0.0.1:18770" else "http://127.0.0.1:18765"
val escapedLocalOtaBaseUrl = localOtaBaseUrl.replace("\"", "\\\"")
val amapApiKey = providers.environmentVariable("AMAP_API_KEY").orNull
    ?.takeIf { it.isNotBlank() }
    ?: providers.environmentVariable("KMP_CAPP_ANDROID_APP_CONFIG").orNull
        ?.let { path ->
            val file = rootProject.file(path)
            if (file.isFile) {
                Properties().also { properties -> file.inputStream().use(properties::load) }
                    .getProperty("amap.ApiKey")
                    .orEmpty()
            } else {
                ""
            }
        }
        .orEmpty()
val escapedAmapApiKey = amapApiKey.replace("\\", "\\\\").replace("\"", "\\\"")
val kmpAndroidConfigFile = providers.environmentVariable("KMP_CAPP_ANDROID_APP_CONFIG").orNull
    ?.takeIf { it.isNotBlank() }
    ?.let { file(it).takeIf(File::isFile) }
val kmpAndroidSigningProperties = kmpAndroidConfigFile?.let { file ->
    Properties().also { properties -> file.inputStream().use(properties::load) }
}
val kmpAndroidStoreFile = kmpAndroidSigningProperties
    ?.getProperty("app.storeFile")
    ?.takeIf { it.isNotBlank() }
    ?.let { rawPath ->
        val candidate = File(rawPath)
        if (candidate.isAbsolute) {
            candidate
        } else {
            listOf(
                File(kmpAndroidConfigFile!!.parentFile, rawPath),
                File(kmpAndroidConfigFile.parentFile, "app/$rawPath"),
            ).firstOrNull(File::isFile) ?: File(kmpAndroidConfigFile.parentFile, rawPath)
        }
    }
val kmpAndroidSigningAvailable = kmpAndroidSigningProperties != null &&
    !kmpAndroidSigningProperties.getProperty("app.keyAlias").isNullOrBlank() &&
    !kmpAndroidSigningProperties.getProperty("app.keyPassword").isNullOrBlank() &&
    !kmpAndroidSigningProperties.getProperty("app.storePassword").isNullOrBlank() &&
    kmpAndroidStoreFile?.isFile == true

android {
    namespace = "com.example.lynxshell.sample"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.hugboga.custom"
        minSdk = 24
        targetSdk = 35
        versionCode = 1
        versionName = "1.0.0"
        buildConfigField("String", "LYNX_OTA_CLIENT_TOKEN", "\"$otaClientToken\"")
        buildConfigField("String", "AMAP_API_KEY", "\"$escapedAmapApiKey\"")
        buildConfigField("boolean", "LYNX_OTA_CANDIDATE_MODE", candidateActivationEnabled.toString())
        buildConfigField("boolean", "LYNX_OTA_LOCAL_SERVER", localOtaServerEnabled.toString())
        buildConfigField("String", "LYNX_OTA_LOCAL_BASE_URL", "\"$escapedLocalOtaBaseUrl\"")
        buildConfigField("boolean", "LYNX_TEST_OTA_USER_SELECTION", "false")
    }

    signingConfigs {
        if (kmpAndroidSigningAvailable) {
            create("kmpCapp") {
                keyAlias = kmpAndroidSigningProperties!!.getProperty("app.keyAlias")
                keyPassword = kmpAndroidSigningProperties.getProperty("app.keyPassword")
                storeFile = kmpAndroidStoreFile
                storePassword = kmpAndroidSigningProperties.getProperty("app.storePassword")
                isV1SigningEnabled = true
                isV2SigningEnabled = true
            }
        }
    }

    buildTypes {
        debug {
            versionNameSuffix = "-debug"
            buildConfigField("boolean", "LYNX_TEST_OTA_USER_SELECTION", otaUserSelectionTestEnabled.toString())
            if (otaUserSelectionTestEnabled) {
                buildConfigField("String", "LYNX_OTA_CLIENT_TOKEN", "\"ota-user-gray-local-client-token\"")
            }
            // Debug 可由 LynxShell 的页面参数进一步决定是否允许 HTTP。
            manifestPlaceholders["usesCleartextTraffic"] = "true"
            manifestPlaceholders["amapApiKey"] = amapApiKey
            if (kmpAndroidSigningAvailable) signingConfig = signingConfigs.getByName("kmpCapp")
        }
        release {
            isMinifyEnabled = false
            manifestPlaceholders["usesCleartextTraffic"] = "false"
            manifestPlaceholders["amapApiKey"] = amapApiKey
            if (kmpAndroidSigningAvailable) signingConfig = signingConfigs.getByName("kmpCapp")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        buildConfig = true
    }
}

// 只改变验收 Debug APK 的真实 PackageInfo 构建号，Release 仍保持 defaultConfig。
androidComponents {
    onVariants(selector().withBuildType("debug")) { variant ->
        otaDebugVersionCode?.let { code -> variant.outputs.forEach { it.versionCode.set(code) } }
    }
}

dependencies {
    // 示例 App 只显式依赖可复用 Lynx Android Library。
    implementation(project(":lynx-shell"))
    implementation(project(":lynx-map"))
    // Debug 入口、NativeModule 和面板不进入 Release 依赖图。
    debugImplementation(project(":lynx-debug-tool"))

    // 下面仅是示例启动页自身使用的 Android UI 依赖，不属于 Lynx Runtime。
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.fragment:fragment-ktx:1.8.5")
    implementation("com.google.android.material:material:1.12.0")
}
