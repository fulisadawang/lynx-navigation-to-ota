plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.example.lynxshell.debug"
    compileSdk = 35

    defaultConfig {
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

// 工具本身不提供生产 variant，防止宿主误用 implementation 带入 Release。
androidComponents {
    beforeVariants(selector().all()) { variant ->
        variant.enable = variant.buildType == "debug"
    }
}

dependencies {
    implementation(project(":lynx-shell"))
    implementation("androidx.activity:activity-ktx:1.8.0")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("com.google.android.material:material:1.12.0")

    // Runtime 由 lynx-shell 提供，Debug Module 不打包第二份 Lynx。
    compileOnly("org.lynxsdk.lynx:lynx:4.1.0")
    // 仅 Debug 使用官方 Lynx 4.1 Inspector/DevTool API，用于逐 View Console 归属。
    implementation("org.lynxsdk.lynx:lynx-devtool:4.1.0")
    implementation("org.lynxsdk.lynx:lynx-service-devtool:4.1.0")
    compileOnly("org.lynxsdk.lynx:lynx-service-http:4.1.0")
}
