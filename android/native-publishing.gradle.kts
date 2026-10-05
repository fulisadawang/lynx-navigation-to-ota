import groovy.json.JsonSlurper
import org.gradle.api.component.SoftwareComponentFactory
import org.gradle.api.publish.PublishingExtension
import org.gradle.api.publish.maven.MavenPublication
import org.gradle.api.publish.maven.tasks.GenerateMavenPom
import org.gradle.api.publish.maven.tasks.PublishToMavenRepository
import org.gradle.api.publish.tasks.GenerateModuleMetadata
import org.w3c.dom.Element
import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import java.security.MessageDigest
import java.util.Locale
import javax.inject.Inject
import javax.xml.XMLConstants
import javax.xml.parsers.DocumentBuilderFactory

abstract class NativeStagedPublishingServices {
    @get:Inject
    abstract val componentFactory: SoftwareComponentFactory
}

data class NativeStagedArtifact(val file: File, val classifier: String, val extension: String)
data class NativeStagedPublication(val artifacts: List<NativeStagedArtifact>, val pom: File, val metadata: File)

fun requiredText(value: Any?, field: String): String =
    (value as? String)?.takeIf { it.isNotBlank() }
        ?: error("native-release.json 的 $field 必须是非空字符串")

fun stagedFile(directory: File, relativePath: String): File {
    val root = directory.toPath().toRealPath()
    val path = root.resolve(relativePath).normalize()
    require(path.startsWith(root)) { "Staging 文件路径超出已声明 Maven 根目录" }
    var parent = path
    while (parent != root) {
        require(!Files.isSymbolicLink(parent)) { "Staging 文件路径禁止符号链接：$relativePath" }
        parent = parent.parent
    }
    require(Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS) && Files.size(path) > 0) {
        "Staging 缺少非空文件：$relativePath"
    }
    return path.toFile()
}

fun stagedHashes(file: File): Map<String, String> {
    val algorithms = mapOf("sha256" to "SHA-256", "sha512" to "SHA-512", "sha1" to "SHA-1", "md5" to "MD5")
    val digests = algorithms.mapValues { MessageDigest.getInstance(it.value) }
    file.inputStream().use { input ->
        val block = ByteArray(64 * 1024)
        while (true) {
            val count = input.read(block)
            if (count < 0) break
            digests.values.forEach { it.update(block, 0, count) }
        }
    }
    return digests.mapValues { it.value.digest().joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) } }
}

fun readStagedPublication(directory: File, group: String, artifact: String, version: String, debugOnly: Boolean): NativeStagedPublication {
    val versionPath = "${group.replace('.', '/')}/$artifact/$version"
    val prefix = "$artifact-$version"
    val pom = stagedFile(directory, "$versionPath/$prefix.pom")
    val metadata = stagedFile(directory, "$versionPath/$prefix.module")
    val xml = DocumentBuilderFactory.newInstance().apply {
        isNamespaceAware = true
        setFeature("http://apache.org/xml/features/disallow-doctype-decl", true)
        setAttribute(XMLConstants.ACCESS_EXTERNAL_DTD, "")
        setAttribute(XMLConstants.ACCESS_EXTERNAL_SCHEMA, "")
    }.newDocumentBuilder().parse(pom).documentElement
    require(xml.localName == "project") { "Staging POM 根元素必须为 project" }
    val pomCoordinates = mutableMapOf<String, String>()
    for (index in 0 until xml.childNodes.length) {
        val child = xml.childNodes.item(index) as? Element ?: continue
        if (child.localName in setOf("groupId", "artifactId", "version")) {
            require(pomCoordinates.put(child.localName, child.textContent.trim()) == null) { "Staging POM 坐标字段重复" }
        }
    }
    require(pomCoordinates["groupId"] == group && pomCoordinates["artifactId"] == artifact && pomCoordinates["version"] == version) {
        "Staging POM 坐标与 native-release.json 不一致：$artifact:$version"
    }
    val module = JsonSlurper().parse(metadata) as? Map<*, *> ?: error("Staging .module 必须为对象")
    val component = module["component"] as? Map<*, *> ?: error("Staging .module 缺少 component")
    require(component["group"] == group && component["module"] == artifact && component["version"] == version) {
        "Staging .module 坐标与 native-release.json 不一致：$artifact:$version"
    }
    val variants = module["variants"] as? List<*> ?: error("Staging .module 缺少 variants")
    val artifacts = linkedMapOf<String, NativeStagedArtifact>()
    val hashes = mutableMapOf<String, Map<String, String>>()
    val pattern = Regex("${Regex.escape(prefix)}-(debug|release)(-sources)?\\.(aar|jar)")
    for (rawVariant in variants) {
        val variant = rawVariant as? Map<*, *> ?: error("Staging .module variant 必须为对象")
        val files = variant["files"] as? List<*> ?: error("Staging .module variant 缺少 files")
        for (rawFile in files) {
            val declared = rawFile as? Map<*, *> ?: error("Staging .module file 必须为对象")
            val url = declared["url"] as? String ?: error("Staging .module file 缺少 url")
            val match = pattern.matchEntire(url) ?: error("Staging artifact 文件名不属于已声明坐标：$url")
            val buildType = match.groupValues[1]
            val sources = match.groupValues[2].isNotEmpty()
            val extension = match.groupValues[3]
            require((sources && extension == "jar") || (!sources && extension == "aar")) { "Staging artifact 类型与 classifier 不一致：$url" }
            require(!debugOnly || buildType == "debug") { "DebugTool Staging 禁止包含 release artifact" }
            if (!sources) {
                val attributes = variant["attributes"] as? Map<*, *> ?: error("Staging AAR variant 缺少 attributes")
                require(attributes["com.android.build.api.attributes.BuildTypeAttr"] == buildType) { "Staging AAR variant 的 BuildTypeAttr 与文件名不一致" }
            }
            val file = stagedFile(directory, "$versionPath/$url")
            val size = (declared["size"] as? Number)?.toString()?.toLongOrNull()
            require(size == file.length()) { "Staging artifact 大小与 .module 不一致：$url" }
            val digest = hashes.getOrPut(url) { stagedHashes(file) }
            require((declared["sha256"] as? String)?.matches(Regex("[0-9a-fA-F]{64}")) == true) { "Staging artifact 缺少合法 sha256：$url" }
            for ((algorithm, actual) in digest) {
                if (declared[algorithm] != null) {
                    require((declared[algorithm] as? String)?.lowercase(Locale.ROOT) == actual) { "Staging artifact $algorithm 与 .module 不一致：$url" }
                }
            }
            artifacts[url] = NativeStagedArtifact(file, "$buildType${if (sources) "-sources" else ""}", extension)
        }
    }
    val buildTypes = if (debugOnly) listOf("debug") else listOf("debug", "release")
    val expected = buildTypes.flatMap { listOf("$prefix-$it.aar", "$prefix-$it-sources.jar") }.toSet()
    require(artifacts.keys == expected) { "Staging AAR/sources 集合不完整或存在未声明 artifact：$artifact:$version" }
    val versionDirectory = pom.parentFile
    val declaredNames = expected + setOf(pom.name, metadata.name)
    val versionFiles = versionDirectory.listFiles() ?: error("Staging 版本目录无法读取：$artifact:$version")
    versionFiles.filter { it.extension in setOf("aar", "jar", "pom", "module") }.forEach {
        require(it.name in declaredNames) { "Staging 版本目录包含其它 artifact：${it.name}" }
    }
    return NativeStagedPublication(artifacts.values.toList(), pom, metadata)
}

val release = JsonSlurper().parse(rootProject.file("../native-release.json")) as? Map<*, *>
    ?: error("native-release.json 必须为对象")
val androidRelease = release["android"] as? Map<*, *>
    ?: error("native-release.json 缺少 android 配置")
val nativeModules = androidRelease["modules"] as? Map<*, *>
    ?: error("native-release.json 缺少 android.modules 配置")
val nativeVersion = requiredText(release["version"], "version")
val nativeGroup = requiredText(androidRelease["groupId"], "android.groupId")
val repositoryPath = providers.environmentVariable("GITHUB_REPOSITORY")
    .orElse(requiredText(release["repository"], "repository")).get()
require(Regex("[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+").matches(repositoryPath)) {
    "GITHUB_REPOSITORY/native-release.json repository 必须为 owner/repository"
}
val repositoryUrl = "https://github.com/$repositoryPath"
val githubPackagesUrl = "https://maven.pkg.github.com/${repositoryPath.lowercase(Locale.ROOT)}"
val githubUsername = providers.environmentVariable("GITHUB_USERNAME")
    .orElse(providers.environmentVariable("GITHUB_ACTOR"))
val githubToken = providers.environmentVariable("GITHUB_TOKEN")
val stagingDirectory = rootProject.layout.projectDirectory.dir("../dist/native/android/maven")
val modulePaths = listOf(":lynx-shell", ":lynx-capacitor", ":lynx-map", ":lynx-debug-tool")
val stagedInput = providers.environmentVariable("NATIVE_MAVEN_INPUT").orNull?.let {
    require(it.isNotBlank()) { "NATIVE_MAVEN_INPUT 不能为空" }
    File(it).also { directory -> require(directory.isDirectory) { "NATIVE_MAVEN_INPUT 必须指向完整 Maven 目录" } }
}
if (stagedInput != null) {
    val allowed = modulePaths.map { "$it:publishNativePublicationToGitHubPackagesRepository" }.toSet() + ":publishNativeAndroidToGitHubPackages"
    val requested = gradle.startParameter.taskNames.map { if (it.startsWith(":")) it else ":$it" }
    require(requested.isNotEmpty() && requested.all { it in allowed }) { "NATIVE_MAVEN_INPUT 只允许显式 GitHubPackages 发布任务" }
}

// 只在远程发布任务执行时要求凭据，本地 Staging 与普通构建不读取凭据文件。
val validateGitHubPublishingCredentials = tasks.register("validateGitHubPublishingCredentials") {
    group = "publishing"
    description = "确认 GitHub Packages 发布所需环境变量已提供"
    doLast {
        check(!githubUsername.orNull.isNullOrBlank()) {
            "GitHub Packages 发布缺少 GITHUB_USERNAME 或 GITHUB_ACTOR"
        }
        check(!githubToken.orNull.isNullOrBlank()) {
            "GitHub Packages 发布缺少 GITHUB_TOKEN"
        }
    }
}

subprojects {
    if (path !in modulePaths) return@subprojects
    val nativeModuleName = name
    val nativeArtifact = requiredText(nativeModules[nativeModuleName], "android.modules.$nativeModuleName")
    group = nativeGroup
    version = nativeVersion
    pluginManager.withPlugin("maven-publish") {
        extensions.configure<PublishingExtension> {
            publications.register<MavenPublication>("native") {
                groupId = nativeGroup
                artifactId = nativeArtifact
                version = nativeVersion
                pom {
                    name.set(nativeArtifact)
                    description.set("$nativeModuleName Android 原生模块")
                    url.set(repositoryUrl)
                    scm {
                        url.set(repositoryUrl)
                        connection.set("scm:git:$repositoryUrl.git")
                    }
                }
                // AGP 在项目配置结束后才提供 multipleVariants 对应的组件。
                afterEvaluate {
                    if (stagedInput == null) {
                        from(components["native"])
                    } else {
                        val staged = readStagedPublication(stagedInput, nativeGroup, nativeArtifact, nativeVersion, nativeModuleName == "lynx-debug-tool")
                        // 空组件没有原 AAR 构建依赖；变体信息保留在已验收的 .module 字节中。
                        val services = objects.newInstance(NativeStagedPublishingServices::class.java)
                        val marker = services.componentFactory.adhoc("nativeStagedInput")
                        components.add(marker)
                        from(marker)
                        setArtifacts(staged.artifacts.map { mapOf("source" to it.file, "classifier" to it.classifier, "extension" to it.extension) })
                        tasks.named<GenerateMavenPom>("generatePomFileForNativePublication") {
                            destination = staged.pom
                            actions.clear()
                            setDependsOn(emptyList<Any>())
                            enabled = true
                        }
                        tasks.named<GenerateModuleMetadata>("generateMetadataFileForNativePublication") {
                            outputFile.set(staged.metadata)
                            actions.clear()
                            setDependsOn(emptyList<Any>())
                            enabled = true
                        }
                    }
                }
            }
            repositories {
                maven {
                    name = "Staging"
                    url = stagingDirectory.asFile.toURI()
                }
                maven {
                    name = "GitHubPackages"
                    url = uri(githubPackagesUrl)
                    credentials {
                        username = githubUsername.orNull
                        password = githubToken.orNull
                    }
                }
            }
        }
        tasks.withType<PublishToMavenRepository>().configureEach {
            if (name.endsWith("ToGitHubPackagesRepository")) {
                dependsOn(validateGitHubPublishingCredentials)
            }
        }
    }
}

tasks.register("publishNativeAndroidToStaging") {
    group = "publishing"
    description = "将四个 Android 原生模块及变体元数据发布到本地 Staging Maven"
    dependsOn(modulePaths.map { "$it:publishNativePublicationToStagingRepository" })
}

tasks.register("publishNativeAndroidToGitHubPackages") {
    group = "publishing"
    description = "将四个 Android 原生模块及变体元数据发布到 GitHub Packages"
    dependsOn(modulePaths.map { "$it:publishNativePublicationToGitHubPackagesRepository" })
}
