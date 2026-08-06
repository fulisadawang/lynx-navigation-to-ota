import org.gradle.api.publish.maven.MavenPublication

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
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.activity:activity-ktx:1.8.0")
    implementation("com.google.android.material:material:1.12.0")

    // Lynx 4.0 核心与 JS Runtime。
    implementation("org.lynxsdk.lynx:lynx:4.0.0")
    implementation("org.lynxsdk.lynx:lynx-jssdk:4.0.0")
    implementation("org.lynxsdk.lynx:lynx-trace:4.0.0")
    implementation("org.lynxsdk.lynx:primjs:4.0.0")

    // Lynx Service 由 Module 内的 RuntimeInitializer 统一注册。
    implementation("org.lynxsdk.lynx:lynx-service-image:4.0.0")
    implementation("org.lynxsdk.lynx:lynx-service-log:4.0.0")
    implementation("org.lynxsdk.lynx:lynx-service-http:4.0.0")

    // release/4.0 Explorer 对应的 XElement 全量组件。
    implementation("org.lynxsdk.lynx:xelement:4.0.0")
    implementation("org.lynxsdk.lynx:xelement-input:4.0.0")
    implementation("org.lynxsdk.lynx:xelement-overlay:4.0.0")
    implementation("org.lynxsdk.lynx:xelement-viewpager:4.0.0")
    implementation("org.lynxsdk.lynx:xelement-scroll-coordinator:4.0.0")
    implementation("org.lynxsdk.lynx:xelement-svg:4.0.0")
    implementation("org.lynxsdk.lynx:xelement-markdown:4.0.0")
    implementation("org.lynxsdk.lynx:xelement-refresh:4.0.0")
    implementation("org.lynxsdk.lynx:xelement-blur-view:4.0.0")
    implementation("org.lynxsdk.lynx:xelement-webview:4.0.0")

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
                description.set("Lynx 4.0 Runtime、NativeModules、Activity-first 路由、转场和内置 OTA Runtime")
                }
            }
        }
    }
}
