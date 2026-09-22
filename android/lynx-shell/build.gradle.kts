import org.gradle.api.publish.maven.MavenPublication
import com.android.build.api.variant.BuildConfigField
import org.gradle.api.artifacts.component.ModuleComponentIdentifier
import org.gradle.api.tasks.testing.Test

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("maven-publish")
}

android {
    namespace = "com.example.lynxshell"
    compileSdk = 35

    defaultConfig {
        minSdk = 24
        buildConfigField(
            "String",
            "DEFAULT_BUNDLE_URL",
            "\"assets://bundles/main.lynx.bundle\"",
        )
        consumerProguardFiles("consumer-rules.pro")
    }

    buildTypes {
        release {
            isMinifyEnabled = false
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
    publishing {
        singleVariant("release") {
            withSourcesJar()
        }
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")

    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.activity:activity-ktx:1.8.0")
    implementation("androidx.fragment:fragment-ktx:1.8.5")
    // WindowMetrics/FoldingFeature 用于当前 Activity 的真实窗口与折叠能力快照。
    implementation("androidx.window:window:1.5.0")
    implementation("com.google.android.material:material:1.12.0")

    // Lynx 4.1 核心与 JS Runtime；官方 4.1 组合使用 PrimJS 4.1.1。
    implementation("org.lynxsdk.lynx:lynx:4.1.0")
    implementation("org.lynxsdk.lynx:lynx-jssdk:4.1.0")
    implementation("org.lynxsdk.lynx:lynx-trace:4.1.0")
    implementation("org.lynxsdk.lynx:primjs:4.1.1")

    // 调试实现只进入 Debug variant，发布的 Release AAR 不携带 DevTool。
    debugImplementation("org.lynxsdk.lynx:lynx-devtool:4.1.0")
    debugImplementation("org.lynxsdk.lynx:lynx-service-devtool:4.1.0")

    // Lynx Service 由 Module 内的 RuntimeInitializer 统一注册。
    implementation("org.lynxsdk.lynx:lynx-service-image:4.1.0")
    implementation("org.lynxsdk.lynx:lynx-service-log:4.1.0")
    implementation("org.lynxsdk.lynx:lynx-service-http:4.1.0")

    // Lynx 4.1 Explorer 对应的 XElement 全量组件。
    // xelement:4.1.0 的聚合 BehaviorGenerator 已包含 Video 注册入口；
    // 升级主分支不显式接入 AnimaX；官方聚合器可能携带其传递依赖，专项分支再启用该组件。
    implementation("org.lynxsdk.lynx:xelement:4.1.0")
    implementation("org.lynxsdk.lynx:xelement-input:4.1.0")
    implementation("org.lynxsdk.lynx:xelement-overlay:4.1.0")
    implementation("org.lynxsdk.lynx:xelement-viewpager:4.1.0")
    implementation("org.lynxsdk.lynx:xelement-scroll-coordinator:4.1.0")
    implementation("org.lynxsdk.lynx:xelement-svg:4.1.0")
    implementation("org.lynxsdk.lynx:xelement-markdown:4.1.0")
    implementation("org.lynxsdk.lynx:xelement-refresh:4.1.0")
    implementation("org.lynxsdk.lynx:xelement-blur-view:4.1.0")
    implementation("org.lynxsdk.lynx:xelement-webview:4.1.0")
    implementation("org.lynxsdk.lynx:xelement-video:4.1.0")

    implementation("org.lynxsdk.lynx:lynxtextra:0.1.1")
    implementation("org.lynxsdk.lynx:servalsvg:0.0.2")
    implementation("org.lynxsdk.lynx:serval_markdown:0.1.1")
    implementation("io.github.scwang90:refresh-layout-kernel:3.0.0-alpha")

    implementation("com.facebook.fresco:fresco:2.3.0")
    implementation("com.facebook.fresco:animated-gif:2.3.0")
    implementation("com.facebook.fresco:animated-webp:2.3.0")
    implementation("com.facebook.fresco:webpsupport:2.3.0")
    implementation("com.facebook.fresco:animated-base:2.3.0")
    implementation("com.squareup.okhttp3:okhttp:4.9.0")
}

// Lynx AAR 的 getter 固定返回 0.0.1，Manifest 也不是 Maven semver。
// 从当前 variant 实际解析到的 Runtime 组件生成版本，不使用业务默认值或声明文本。
androidComponents {
    onVariants(selector().all()) { variant ->
        val runtimeVersion = providers.provider {
            val versions = variant.runtimeConfiguration.incoming.resolutionResult.allComponents
                .mapNotNull { it.id as? ModuleComponentIdentifier }
                .filter { it.group == "org.lynxsdk.lynx" && it.module == "lynx" }
                .map { it.version }.toSet()
            check(versions.size == 1) { "${variant.name} 必须解析到唯一 Lynx Runtime" }
            versions.single().also { check(Regex("[0-9]+(?:\\.[0-9]+){0,2}").matches(it)) { "Lynx Runtime 必须使用稳定数字版本" } }
        }
        variant.buildConfigFields.put("LYNX_RUNTIME_VERSION", runtimeVersion.map { version ->
            BuildConfigField("String", "\"$version\"", "Resolved Lynx Runtime version for this variant")
        })
    }
}

tasks.withType<Test>().configureEach {
    val origin = providers.environmentVariable("OTA_USER_GRAY_SERVER_ORIGIN").orElse("")
    inputs.property("otaUserGrayOrigin", origin)
    inputs.property("otaUserGrayEvidenceDirectory", providers.environmentVariable("OTA_USER_GRAY_EVIDENCE_DIR").orElse(""))
    // 真实 Server 是外部可变状态；显式协议验收每次实跑，不能复用曾经的 skipped/通过结果。
    outputs.upToDateWhen { origin.get().isBlank() }
}

afterEvaluate {
    publishing {
        publications {
            create<MavenPublication>("release") {
                from(components["release"])
                groupId = "com.example.lynx"
                artifactId = "lynx-shell-android"
                version = "1.0.0"
                pom {
                    name.set("Lynx Shell Android")
                description.set("Lynx 4.1 Runtime、NativeModules、Activity-first 路由、转场和内置 OTA Runtime")
                }
            }
        }
    }
}
