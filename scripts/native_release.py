#!/usr/bin/env python3
"""三端原生版本与发布资产的统一入口；不自动编译或上传。"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import zipfile


ROOT = Path(__file__).resolve().parents[1]
VERSION = re.compile(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?")


def run(*command, env=None):
    return subprocess.check_output(command, cwd=ROOT, env=env, text=True).strip()


def config():
    data = json.loads((ROOT / "native-release.json").read_text())
    if data["schemaVersion"] != 1 or not VERSION.fullmatch(data["version"]):
        raise ValueError("native-release.json 版本格式不合法")
    if data["tagPrefix"] != "native-v":
        raise ValueError("原生发布 tag 前缀必须为 native-v")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", data["repository"]):
        raise ValueError("GitHub repository 必须为 owner/repo")
    if data["harmony"]["gfxVersion"] != data["lynxVersion"]:
        raise ValueError("gfx 与 Lynx Core 必须为同一 ABI 版本")
    if not re.fullmatch(r"[a-z][a-z0-9]*(?:\.[a-z][a-z0-9]*)+", data["android"]["groupId"]):
        raise ValueError("Maven groupId 必须为合法小写命名空间")
    if set(data["android"]["modules"]) != {"lynx-shell", "lynx-capacitor", "lynx-map", "lynx-debug-tool"}:
        raise ValueError("Android 发布模块必须与既有四模块一致")
    if any(not re.fullmatch(r"[a-z][a-z0-9-]+", name) for name in data["android"]["modules"].values()):
        raise ValueError("Maven artifactId 不合法")
    return data


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def check_versions(data):
    for relative in data["ios"]["podspecs"]:
        text = (ROOT / relative).read_text()
        found = re.search(r"spec\.version\s*=\s*'([^']+)'", text)
        if found is None or found.group(1) != data["version"]:
            raise ValueError(f"{relative} 未同步到 {data['version']}")
        dependencies = re.findall(r"(?:spec|map)\.dependency\s+'(LynxShellKit|LynxMapKit|LynxCapacitorKit|LynxShellDebugKit)',\s*'([^']+)'", text)
        if any(version != data["version"] for _, version in dependencies):
            raise ValueError(f"{relative} 的自有依赖未同步同版")
    for module in ("lynx_shell_kit", "lynx_capacitor_kit"):
        package = json.loads((ROOT / f"harmony/{module}/oh-package.json5").read_text())
        if package["version"] != data["version"]:
            raise ValueError(f"{module} 未同步到 {data['version']}")
    parameter = json.loads((ROOT / "harmony/parameter.json").read_text())
    if parameter["dependencies"] != {"lynx_version": data["lynxVersion"], "primjs_version": data["primjsVersion"]}:
        raise ValueError("发布配置与已安装的 Harmony 引擎版本不一致")


def set_version(value):
    if not VERSION.fullmatch(value):
        raise ValueError("版本必须为 SemVer，不能包含路径或构建元数据")
    data = config()
    changes = {}
    for relative in data["ios"]["podspecs"]:
        path = ROOT / relative
        text, count = re.subn(r"spec\.version\s*=\s*'[^']+'", f"spec.version = '{value}'", path.read_text())
        if count != 1:
            raise ValueError(f"{relative} 版本声明数量异常，未写入任何文件")
        text = re.sub(r"((?:spec|map)\.dependency\s+'(?:LynxShellKit|LynxMapKit|LynxCapacitorKit|LynxShellDebugKit)',\s*)'[^']+'", lambda match: match.group(1) + repr(value), text)
        changes[path] = text
    for module in ("lynx_shell_kit", "lynx_capacitor_kit"):
        path = ROOT / f"harmony/{module}/oh-package.json5"
        package = json.loads(path.read_text())
        package["version"] = value
        changes[path] = json.dumps(package, ensure_ascii=False, indent=2) + "\n"
    data["version"] = value
    changes[ROOT / "native-release.json"] = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
    for path, text in changes.items():
        path.write_text(text)
    print(f"已同步原生版本 {value}；未打 tag、未构建、未发布")


def metadata(mode, requested_tag):
    data = config()
    check_versions(data)
    sha = run("git", "rev-parse", "HEAD")
    expected_sha = os.environ.get("GITHUB_SHA", sha)
    if sha != expected_sha:
        raise ValueError("checkout 与本次 workflow sourceSHA 不一致")
    tag = data["tagPrefix"] + data["version"]
    if requested_tag and requested_tag != tag:
        raise ValueError("输入 tag 与原生版本不一致")
    main_dispatch = os.environ.get("GITHUB_REF") == "refs/heads/main"
    trusted = main_dispatch and run("git", "rev-parse", "origin/main") == sha
    if mode == "publish" and not trusted:
        raise ValueError("发布必须从当前 main 手动触发，不接受分支、旧提交或移动后的 main")
    harmony_enabled = trusted and os.environ.get("HARMONY_RUNNER_READY") == "true"
    if mode == "publish" and not harmony_enabled:
        raise ValueError("发布需要已配置的 Harmony Runner；请先设置 HARMONY_RUNNER_READY=true")
    result = {"version": data["version"], "tag": tag, "source_sha": sha,
              "trusted": str(trusted).lower(), "gradle": data["android"]["gradleVersion"],
              "java": data["android"]["javaVersion"], "repository": data["repository"],
              "harmony_enabled": str(harmony_enabled).lower(),
              "artifact_suffix": os.environ.get("GITHUB_RUN_ID", "local") + "-" + os.environ.get("GITHUB_RUN_ATTEMPT", "local"),
              "attempt": os.environ.get("GITHUB_RUN_ATTEMPT", "local")}
    if os.environ.get("GITHUB_REPOSITORY", data["repository"]) != data["repository"]:
        raise ValueError("当前 workflow 仓库与发布元数据不一致")
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a") as stream:
            for key, value in result.items():
                stream.write(f"{key}={value}\n")
    print(json.dumps(result, ensure_ascii=False))


def archive(directory, output):
    files = sorted(path for path in directory.rglob("*") if path.is_file())
    if not files:
        raise ValueError(f"没有发布文件：{directory}")
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as bundle:
        for path in files:
            if path.is_symlink():
                raise ValueError(f"发布文件不允许软链接：{path.name}")
            bundle.write(path, path.relative_to(directory).as_posix())


def package_android(output):
    data = config()
    maven = output / "maven"
    group = data["android"]["groupId"]
    release_aars = []
    for artifact in data["android"]["modules"].values():
        version_dir = maven / group.replace(".", "/") / artifact / data["version"]
        module_file = version_dir / f"{artifact}-{data['version']}.module"
        module = json.loads(module_file.read_text())
        component = module["component"]
        if (component["group"], component["module"], component["version"]) != (group, artifact, data["version"]):
            raise ValueError(f"错误 Maven 坐标：{artifact}")
        variants = module["variants"]
        builds = {variant.get("attributes", {}).get("com.android.build.api.attributes.BuildTypeAttr") for variant in variants}
        expected = {"debug"} if artifact == data["android"]["modules"]["lynx-debug-tool"] else {"debug", "release"}
        if not expected.issubset(builds) or (expected == {"debug"} and "release" in builds):
            raise ValueError(f"{artifact} 的 Debug/Release 发布 variant 不正确")
        for variant in variants:
            for item in variant.get("files", []):
                name = item["name"]
                if Path(name).name != name or not (version_dir / name).is_file():
                    raise ValueError(f"{artifact} 引用缺失或越界产物")
                if variant.get("attributes", {}).get("com.android.build.api.attributes.BuildTypeAttr") == "release" and name.endswith(".aar"):
                    release_aars.append(str(version_dir / name))
    # 复用项目现有产物检查，保护正式 AAR 不携带真实 Debug SPI。
    subprocess.run([sys.executable, str(ROOT / "scripts/check_debug_tool_release.py"), "--android", *sorted(set(release_aars))], check=True)
    archive(maven, output / f"lynx-android-maven-{data['version']}.zip")


def export_ios(output):
    data = config()
    specs = output / "Specs"
    env = dict(os.environ, LYNX_NATIVE_REMOTE_SPEC="1")
    own_names = {Path(path).stem for path in data["ios"]["podspecs"]}
    observed_names = set()
    roots = {name: f"ios/{name}/" for name in own_names}

    def brace_patterns(pattern):
        match = re.search(r"\{([^{}]+)\}", pattern)
        if match is None:
            return [pattern]
        result = []
        for option in match.group(1).split(","):
            result.extend(brace_patterns(pattern[:match.start()] + option + pattern[match.end():]))
        return result

    def paths(name, field, value):
        patterns = [value] if isinstance(value, str) else value
        if not isinstance(patterns, list) or not patterns:
            raise ValueError(f"{name}.{field} 必须声明真实路径")
        for pattern in patterns:
            if not isinstance(pattern, str) or "\\" in pattern or ".." in Path(pattern).parts:
                raise ValueError(f"{name}.{field} 不允许越界路径")
            allowed = (roots[name],)
            if name == "LynxShellKit" and field == "source_files":
                allowed += ("ios/OtaIOSSDK/Sources/OtaIOSSDK/",)
            if not pattern.startswith(allowed):
                raise ValueError(f"{name}.{field} 未使用本模块的 Git 根路径")
            matches = [path for expanded in brace_patterns(pattern) for path in ROOT.glob(expanded) if path.is_file()]
            def contains_symlink(path):
                current = ROOT
                for part in path.relative_to(ROOT).parts:
                    current = current / part
                    if current.is_symlink():
                        return True
                return False
            if not matches or any(contains_symlink(path) or not path.resolve().is_relative_to(ROOT) for path in matches):
                raise ValueError(f"{name}.{field} 没有实际文件或含软链接")

    def validate_own(spec):
        name = spec["name"]
        if spec["version"] != data["version"] or spec["source"] != {"git": f"https://github.com/{data['repository']}.git", "tag": data["tagPrefix"] + spec["version"]}:
            raise ValueError(f"{name} 的源码仓库、tag或版本错误")
        def attributes(values):
            for field in ("source_files", "public_header_files"):
                if field in values:
                    paths(name, field, values[field])
            for value in values.get("resource_bundles", {}).values():
                paths(name, "resource_bundles", value)
            for dependency, requirements in values.get("dependencies", {}).items():
                if dependency.split("/")[0] in own_names and requirements not in ([data["version"]], ["= " + data["version"]]):
                    raise ValueError(f"{name} 的自有依赖 {dependency} 未固定同版")
            for subspec in values.get("subspecs", []):
                attributes(subspec)
        attributes(spec)
        privacy = {
            "LynxShellKit": {"LynxShellKitPrivacy": ["ios/LynxShellKit/Resources/PrivacyInfo.xcprivacy"]},
            "LynxCapacitorKit": {"LynxCapacitorKitPrivacy": ["ios/LynxCapacitorKit/Resources/PrivacyInfo.xcprivacy"]},
        }
        if name in privacy and spec.get("resource_bundles") != privacy[name]:
            raise ValueError(f"{name} 隐私资源Bundle声明不正确")
    for relative in data["ios"]["podspecs"] + data["ios"]["additionalSpecs"]:
        spec = json.loads(run("pod", "ipc", "spec", str(ROOT / relative), env=env))
        name, version = spec["name"], spec["version"]
        if name != Path(relative).stem or name in observed_names:
            raise ValueError("Pod名字与发布清单不一致或重复")
        observed_names.add(name)
        if relative in data["ios"]["podspecs"]:
            validate_own(spec)
        write_json(specs / name / version / f"{name}.podspec.json", spec)
    if not own_names.issubset(observed_names):
        raise ValueError("未导出全部自有Pod")
    archive(specs, output / f"lynx-ios-specs-{data['version']}.zip")


def receipt(platform, output):
    data = config()
    sha = run("git", "rev-parse", "HEAD")
    if sha != os.environ.get("NATIVE_SOURCE_SHA", sha):
        raise ValueError("产物 sourceSHA 与构建 checkout 不一致")
    files = sorted(path for path in output.iterdir() if path.is_file() and path.suffix in (".zip", ".har"))
    expected = {"android": 1, "ios": 1, "harmony": 3}[platform]
    if len(files) != expected:
        raise ValueError(f"{platform} 发布文件数量错误")
    write_json(output / "platform.json", {"schemaVersion": 1, "platform": platform, "version": data["version"],
        "sourceSHA": sha, "runId": os.environ.get("GITHUB_RUN_ID", "local"),
        "runAttempt": os.environ.get("GITHUB_RUN_ATTEMPT", "local"),
        "files": [{"name": path.name, "size": path.stat().st_size, "sha256": digest(path)} for path in files]})


def android_consumer(maven, output):
    data = config()
    android = data["android"]
    if output.exists() and any(output.iterdir()):
        raise ValueError("最小消费工程目录必须为空，禁止覆盖业务工程")
    output.mkdir(parents=True, exist_ok=True)
    repository_uri = maven.resolve().as_uri()
    (output / "settings.gradle.kts").write_text('''pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement { repositories {
    maven { url = uri("%s") }; google(); mavenCentral()
} }
rootProject.name = "LynxNativeConsumer"
include(":app")
''' % repository_uri)
    (output / "build.gradle.kts").write_text('''plugins {
    id("com.android.application") version "%s" apply false
    id("org.jetbrains.kotlin.android") version "%s" apply false
}
''' % (android["agpVersion"], android["kotlinVersion"]))
    app = output / "app"
    app.mkdir()
    coordinate = lambda name: android["groupId"] + ":" + android["modules"][name] + ":" + data["version"]
    (app / "build.gradle.kts").write_text('''plugins { id("com.android.application"); id("org.jetbrains.kotlin.android") }
android {
    namespace = "io.github.lynx.nativeconsumer"
    compileSdk = %d
    defaultConfig { applicationId = "io.github.lynx.nativeconsumer"; minSdk = %d; targetSdk = %d }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
}
dependencies {
    implementation("%s")
    implementation("%s")
    debugImplementation("%s")
}
''' % (android["compileSdk"], android["minSdk"], android["compileSdk"], coordinate("lynx-shell"), coordinate("lynx-capacitor"), coordinate("lynx-debug-tool")))
    source = app / "src/main/java/io/github/lynx/nativeconsumer"
    source.mkdir(parents=True)
    (app / "src/main/AndroidManifest.xml").write_text('<manifest xmlns:android="http://schemas.android.com/apk/res/android"><application android:theme="@android:style/Theme.Material.Light.NoActionBar" /></manifest>\n')
    (source / "SdkTypes.kt").write_text('''package io.github.lynx.nativeconsumer
import com.example.lynxshell.LynxRouter
import com.example.lynxcapacitormodule.LynxCapacitorModule
object SdkTypes { val types = arrayOf(LynxRouter::class.java, LynxCapacitorModule::class.java) }
''')
    debug = app / "src/debug/java/io/github/lynx/nativeconsumer"
    debug.mkdir(parents=True)
    (debug / "DebugTypes.kt").write_text('''package io.github.lynx.nativeconsumer
import com.example.lynxshell.debug.LynxDebugTool
object DebugTypes { val type = LynxDebugTool::class.java }
''')
    print(f"已生成仅依赖 Staging Maven 的最小消费工程：{output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check")
    version = commands.add_parser("set-version")
    version.add_argument("version")
    meta = commands.add_parser("ci-metadata")
    meta.add_argument("--mode", choices=("verify", "publish"), required=True)
    meta.add_argument("--tag", default="")
    package = commands.add_parser("package")
    package.add_argument("--platform", choices=("android", "ios", "harmony"), required=True)
    package.add_argument("--output", type=Path, required=True)
    consumer = commands.add_parser("android-consumer")
    consumer.add_argument("--maven", type=Path, required=True)
    consumer.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "set-version":
        set_version(args.version)
    elif args.command == "ci-metadata":
        metadata(args.mode, args.tag)
    elif args.command == "check":
        check_versions(config())
        print("原生版本配置一致；未构建或发布")
    elif args.command == "android-consumer":
        android_consumer(args.maven, args.output)
    else:
        args.output.mkdir(parents=True, exist_ok=True)
        if args.platform == "android":
            package_android(args.output)
        elif args.platform == "ios":
            export_ios(args.output)
        receipt(args.platform, args.output)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        print(f"原生发布操作失败：{error}", file=sys.stderr)
        sys.exit(1)
