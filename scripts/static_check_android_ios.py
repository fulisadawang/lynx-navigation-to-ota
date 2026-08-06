#!/usr/bin/env python3
"""Lynx 4.0 原生壳静态验收脚本。

本脚本只验证源码结构、配置、语法可解析性与跨端契约一致性；
不会下载 Maven/CocoaPods 依赖，也不会替代 Gradle/Xcode 真正编译。
"""
from __future__ import annotations

import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PASS: list[str] = []
FAIL: list[str] = []
WARN: list[str] = []


def ok(message: str) -> None:
    PASS.append(message)


def fail(message: str) -> None:
    FAIL.append(message)


def warn(message: str) -> None:
    WARN.append(message)


def require(condition: bool, message: str) -> None:
    (ok if condition else fail)(message)


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def expected_files() -> None:
    required = [
        "README.md",
        "PROJECT_MAP.md",
        "ARCHITECTURE.md",
        "BRIDGE_CONTRACT.md",
        "NAVIGATION_README.md",
        "TRANSITIONS_README.md",
        "MODULE_INTEGRATION.md",
        "COMPATIBILITY.md",
        "XELEMENT_INTEGRATION.md",
        "XElement_FULL_CHANGELOG.md",
        "ROUTING.md",
        "SECURITY.md",
        "SOURCE_MAPPING.md",
        "THIRD_PARTY_NOTICES.md",
        "VALIDATION.md",
        "examples/lynx-shell-module.d.ts",
        "examples/lynx-shell-module.harmony.d.ts",
        "scripts/sync_bundle.sh",
        "android/settings.gradle.kts",
        "android/build.gradle.kts",
        "android/lynx-shell/build.gradle.kts",
        "android/lynx-shell/consumer-rules.pro",
        "android/lynx-shell/src/main/AndroidManifest.xml",
        "android/lynx-shell/src/main/java/com/example/lynxshell/LynxShell.kt",
        "android/lynx-shell/src/main/java/com/example/lynxshell/LynxRouter.kt",
        "android/app/src/main/AndroidManifest.xml",
        "android/app/src/main/java/com/example/lynxshell/sample/LynxShellSampleApplication.kt",
        "android/app/src/main/java/com/example/lynxshell/sample/MainActivity.kt",
        "android/lynx-shell/src/main/java/com/example/lynxshell/container/LynxShellActivity.kt",
        "android/lynx-shell/src/main/java/com/example/lynxshell/runtime/XElementRuntime.kt",
        "android/lynx-shell/src/main/java/com/example/lynxshell/resource/ShellTemplateProvider.kt",
        "android/lynx-shell/src/main/java/com/example/lynxshell/routing/LynxRouteParser.kt",
        "android/lynx-shell/src/main/java/com/example/lynxshell/routing/LynxNavigator.kt",
        "android/lynx-shell/src/main/java/com/example/lynxshell/bridge/LynxShellModule.kt",
        "android/lynx-shell/src/main/java/com/example/lynxshell/bridge/ShellMessageHub.kt",
        "android/lynx-shell/src/main/java/com/example/lynxshell/bridge/ShellMediaBridge.kt",
        "android/lynx-shell/src/main/java/com/example/lynxshell/bridge/ShellMediaPickerActivity.kt",
        "android/lynx-shell/src/main/java/com/example/lynxshell/transition/LynxColorParser.kt",
        "android/lynx-shell/src/main/java/com/example/lynxshell/transition/LynxCompatEdgeBackLayout.kt",
        "android/lynx-shell/src/main/java/com/example/lynxshell/transition/LynxElementResolver.kt",
        "android/lynx-shell/src/main/java/com/example/lynxshell/transition/LynxMotionPolicy.kt",
        "android/lynx-shell/src/main/java/com/example/lynxshell/transition/LynxOpenContainerMorphView.kt",
        "android/lynx-shell/src/main/java/com/example/lynxshell/transition/LynxSnapshotStore.kt",
        "android/lynx-shell/src/main/java/com/example/lynxshell/transition/LynxSnapshotter.kt",
        "android/lynx-shell/src/main/java/com/example/lynxshell/transition/LynxTransitionCoordinator.kt",
        "android/lynx-shell/src/main/java/com/example/lynxshell/transition/LynxTransitionRuntime.kt",
        "android/lynx-shell/src/main/java/com/example/lynxshell/transition/LynxTransitionSpec.kt",
        "android/lynx-shell/src/main/java/com/example/lynxshell/transition/LynxTransitionState.kt",
        "android/lynx-shell/src/main/java/com/example/lynxshell/transition/PreparedRouteStore.kt",
        "ios/Podfile",
        "ios/LynxShellKit.podspec",
        "ios/project.yml",
        "ios/LynxShell.xcodeproj/project.pbxproj",
        "ios/LynxShellKit/LynxShell.swift",
        "ios/LynxShellKit/LynxRouter.swift",
        "ios/LynxShellSample/App/AppDelegate.swift",
        "ios/LynxShellSample/App/SceneDelegate.swift",
        "ios/LynxShellKit/Container/LynxContainerViewController.swift",
        "ios/LynxShellKit/Resource/ShellTemplateProvider.swift",
        "ios/LynxShellKit/Routing/LynxRouteParser.swift",
        "ios/LynxShellKit/Routing/ShellNavigator.swift",
        "ios/LynxShellKit/Bridge/LynxShellModule.swift",
        "ios/LynxShellKit/Runtime/ShellMessageHub.swift",
        "ios/LynxShellKit/Native/LynxNativeRuntime.h",
        "ios/LynxShellKit/Native/LynxNativeRuntime.m",
        "ios/LynxShellKit/Model/ShellTransitionSpec.swift",
        "ios/LynxShellKit/Resource/ShellPreparedRouteStore.swift",
        "ios/LynxShellKit/Transition/LynxFirstScreenObserver.swift",
        "ios/LynxShellKit/Transition/ShellNavigationAnimator.swift",
        "ios/LynxShellKit/Transition/ShellTransitionCoordinator.swift",
        "ios/LynxShellKit/UI/UIColor+ShellHex.swift",
        "ios/LynxShellSample/Supporting/Info.plist",
        "ios/LynxShellSample/Supporting/Info-Debug.plist",
        "ios/LynxShellSample/UI/LauncherViewController.swift",
        "playground/src/data/goLynxBundleUrls.ts",
        "playground/src/pages/go-bundles/App.tsx",
        "playground/src/pages/go-bundles/App.css",
        "playground/src/pages/go-bundles/index.tsx",
        "playground/src/pages/transition-gallery/App.tsx",
        "playground/src/pages/transition-gallery/App.css",
        "playground/src/pages/transition-gallery/index.tsx",
        "playground/src/pages/transition-detail/App.tsx",
        "playground/src/pages/transition-detail/App.css",
        "playground/src/pages/transition-detail/index.tsx",
        "playground/src/components/ShareElement/index.tsx",
    ]
    missing = [path for path in required if not (ROOT / path).is_file()]
    require(not missing, "关键工程文件完整" if not missing else f"缺少关键文件: {', '.join(missing)}")


def parse_xml_and_plist() -> None:
    xml_files = list((ROOT / "android").rglob("*.xml"))
    xml_files.append(ROOT / "ios/LynxShellSample/Supporting/LaunchScreen.storyboard")
    errors: list[str] = []
    for path in xml_files:
        try:
            ET.parse(path)
        except Exception as exc:  # noqa: BLE001 - 输出具体配置错误
            errors.append(f"{path.relative_to(ROOT)}: {exc}")
    require(not errors, f"Android XML 与 iOS Storyboard 可解析（{len(xml_files)} 个文件）" if not errors else "; ".join(errors))

    plist_paths = [
        ROOT / "ios/LynxShellSample/Supporting/Info.plist",
        ROOT / "ios/LynxShellSample/Supporting/Info-Debug.plist",
    ]
    plists: list[dict] = []
    for path in plist_paths:
        try:
            with path.open("rb") as file:
                plists.append(plistlib.load(file))
        except Exception as exc:  # noqa: BLE001
            fail(f"Plist 解析失败 {path.relative_to(ROOT)}: {exc}")
            return
    ok("Info.plist 与 Info-Debug.plist 可解析")

    release_ats = plists[0].get("NSAppTransportSecurity", {}).get("NSAllowsArbitraryLoads")
    debug_ats = plists[1].get("NSAppTransportSecurity", {}).get("NSAllowsArbitraryLoads")
    require(release_ats is False, "iOS Release 禁止任意明文网络加载")
    require(debug_ats is True, "iOS Debug 为调试 HTTP 保留 ATS 开关")
    require(
        "LynxAllowedBundleHosts" not in plists[0]
        and "LynxAllowedBundleHosts" not in plists[1],
        "iOS Demo 不配置远程 Bundle Host 白名单",
    )


def swift_parse() -> None:
    swiftc = shutil.which("swiftc")
    if not swiftc:
        warn("当前环境没有 swiftc，跳过 Swift 语法解析")
        return

    swift_files = sorted((ROOT / "ios/LynxShellKit").rglob("*.swift"))
    swift_files += sorted((ROOT / "ios/LynxShellSample").rglob("*.swift"))
    sample_files = sorted((ROOT / "ios/Integration").rglob("*.swift.sample"))
    errors: list[str] = []

    for path in swift_files:
        proc = subprocess.run(
            [swiftc, "-parse", str(path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        if proc.returncode != 0:
            errors.append(f"{path.relative_to(ROOT)}: {proc.stderr.strip()}")

    # swiftc 只按扩展名识别 Swift；把 .sample 临时复制成 .swift 后解析。
    with tempfile.TemporaryDirectory(prefix="lynx-shell-swift-") as directory:
        for index, path in enumerate(sample_files):
            temp = Path(directory) / f"sample_{index}.swift"
            temp.write_text(path.read_text(encoding="utf-8"), encoding="utf-8")
            proc = subprocess.run(
                [swiftc, "-parse", str(temp)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
            if proc.returncode != 0:
                errors.append(f"{path.relative_to(ROOT)}: {proc.stderr.strip()}")

    require(
        not errors,
        f"Swift 主工程与 Sparkling 样例均通过 swiftc -parse（{len(swift_files) + len(sample_files)} 个文件）"
        if not errors
        else "Swift 语法错误:\n" + "\n".join(errors),
    )


def versions() -> None:
    gradle = read("android/lynx-shell/build.gradle.kts")
    podspec = read("ios/LynxShellKit.podspec")
    podfile = read("ios/Podfile")

    android_core_artifacts = [
        "org.lynxsdk.lynx:lynx",
        "org.lynxsdk.lynx:lynx-jssdk",
        "org.lynxsdk.lynx:lynx-trace",
        "org.lynxsdk.lynx:primjs",
        "org.lynxsdk.lynx:lynx-service-image",
        "org.lynxsdk.lynx:lynx-service-log",
        "org.lynxsdk.lynx:lynx-service-http",
    ]
    missing_core = [artifact for artifact in android_core_artifacts if f'{artifact}:4.0.0' not in gradle]
    require(
        not missing_core,
        "Android Lynx/PrimJS/Service 核心依赖统一为 4.0.0"
        if not missing_core
        else f"Android 缺少 4.0.0 核心依赖: {', '.join(missing_core)}",
    )

    expected_android_xelement = {
        "xelement",
        "xelement-input",
        "xelement-overlay",
        "xelement-viewpager",
        "xelement-scroll-coordinator",
        "xelement-svg",
        "xelement-markdown",
        "xelement-refresh",
        "xelement-blur-view",
        "xelement-webview",
    }
    actual_android_xelement = set(
        re.findall(
            r'implementation\("org\.lynxsdk\.lynx:(xelement(?:-[a-z-]+)?):4\.0\.0"\)',
            gradle,
        )
    )
    missing_android_xelement = expected_android_xelement - actual_android_xelement
    extra_android_xelement = actual_android_xelement - expected_android_xelement
    require(
        not missing_android_xelement and not extra_android_xelement,
        "Android XElement 10/10 Maven 产物均显式接入"
        if not missing_android_xelement and not extra_android_xelement
        else (
            "Android XElement 清单不一致；"
            f"缺少={sorted(missing_android_xelement)}，额外={sorted(extra_android_xelement)}"
        ),
    )

    android_xelement_companions = [
        "org.lynxsdk.lynx:lynxtextra:0.1.1",
        "org.lynxsdk.lynx:servalsvg:0.0.2",
        "org.lynxsdk.lynx:serval_markdown:0.1.1",
        "io.github.scwang90:refresh-layout-kernel:3.0.0-alpha",
    ]
    missing_companions = [item for item in android_xelement_companions if item not in gradle]
    require(
        not missing_companions,
        "Android XElement SVG/Markdown/Refresh 配套依赖完整"
        if not missing_companions
        else f"Android XElement 缺少配套依赖: {', '.join(missing_companions)}",
    )

    android_factory = read(
        "android/lynx-shell/src/main/java/com/example/lynxshell/container/LynxContainerFactory.kt"
    )
    android_xelement_runtime = read(
        "android/lynx-shell/src/main/java/com/example/lynxshell/runtime/XElementRuntime.kt"
    )
    android_proguard = read("android/lynx-shell/consumer-rules.pro")
    require(
        "XElementRuntime.install(builder)" in android_factory
        and "XElementBehaviors().create()" in android_xelement_runtime,
        "Android 每个 LynxViewBuilder 统一注册完整 XElement BehaviorBundle",
    )
    require(
        "com.lynx.xelement.BehaviorGenerator" in android_proguard
        and "com.lynx.xelement.svg.BehaviorGenerator" in android_proguard,
        "Android R8 保留 XElement BehaviorGenerator 反射入口",
    )

    pod_patterns = [
        r"spec\.dependency 'Lynx/Framework', '4\.0\.0'",
        r"spec\.dependency 'PrimJS/quickjs', '4\.0\.0'",
        r"spec\.dependency 'LynxService/Image', '4\.0\.0'",
        r"spec\.dependency 'XElement/Behavior', '4\.0\.0'",
    ]
    require(
        all(re.search(pattern, podspec) for pattern in pod_patterns),
        "iOS LynxShellKit Podspec 的 Lynx/PrimJS/Service/XElement 统一为 4.0.0",
    )
    lynx_ota_sources = "OtaIOSSDK/Sources/OtaIOSSDK/**/*.swift" in podspec
    single_ios_module = (
        lynx_ota_sources
        and "spec.dependency 'OtaIOSSDK'" not in podspec
        and "pod 'OtaIOSSDK'" not in podfile
    )
    require(
        single_ios_module,
        "iOS Router 与内置 OTA SDK 打包为单一 LynxShellKit Module"
        if single_ios_module
        else "iOS 仍需要业务方显式引入独立 OtaIOSSDK，未满足单模块接入",
    )

    expected_ios_xelement = {
        "Input",
        "BlurView",
        "Overlay",
        "ScrollCoordinator",
        "ViewPager",
        "WebView",
        "SVG",
        "Refresh",
        "Markdown",
        "Behavior",
    }
    actual_ios_xelement = set(
        re.findall(
            r"spec\.dependency 'XElement/([A-Za-z]+)', '4\.0\.0'",
            podspec,
        )
    )
    missing_ios_xelement = expected_ios_xelement - actual_ios_xelement
    extra_ios_xelement = actual_ios_xelement - expected_ios_xelement
    require(
        not missing_ios_xelement and not extra_ios_xelement,
        "iOS LynxShellKit 10/10 XElement subspec 均显式接入"
        if not missing_ios_xelement and not extra_ios_xelement
        else (
            "iOS XElement subspec 清单不一致；"
            f"缺少={sorted(missing_ios_xelement)}，额外={sorted(extra_ios_xelement)}"
        ),
    )

    ios_runtime = read("ios/LynxShellKit/Native/LynxNativeRuntime.m")
    public_headers = {
        "LynxUIBlurView",
        "LynxUIInput",
        "LynxUIMarkdown",
        "LynxUIOverlay",
        "LynxUIRefresh",
        "LynxUIScrollCoordinator",
        "LynxUISVG",
        "LynxUITextArea",
        "LynxUIViewPager",
        "LynxUIWebView",
    }
    registry_headers = {f"{name}AutoRegistry" for name in public_headers}
    missing_public_headers = [
        name for name in sorted(public_headers) if f"<XElement/{name}.h>" not in ios_runtime
    ]
    missing_registry_headers = [
        name for name in sorted(registry_headers) if f"<XElement/{name}.h>" not in ios_runtime
    ]
    require(
        not missing_public_headers,
        "iOS 导入 10/10 XElement 公开元素头作为编译期哨兵"
        if not missing_public_headers
        else f"iOS 缺少公开元素头: {', '.join(missing_public_headers)}",
    )
    require(
        not missing_registry_headers,
        "iOS 导入 10/10 XElement AutoRegistry 头"
        if not missing_registry_headers
        else f"iOS 缺少 AutoRegistry 头: {', '.join(missing_registry_headers)}",
    )

    project_yml = read("ios/project.yml")
    pbxproj = read("ios/LynxShell.xcodeproj/project.pbxproj")
    require(
        "OTHER_LDFLAGS:" in project_yml
        and "- $(inherited)" in project_yml
        and "- -ObjC" in project_yml,
        "iOS XcodeGen 配置包含 XElement AutoRegistry 所需 -ObjC",
    )
    ldflags_settings = re.findall(
        r'OTHER_LDFLAGS\s*=\s*(?:"[^"]*"\s*;|\(.*?\)\s*;)',
        pbxproj,
        flags=re.DOTALL,
    )
    require(
        sum("-ObjC" in setting for setting in ldflags_settings) == 2,
        "iOS Debug/Release Target 均包含 -ObjC",
    )

    require(
        "3.9.0" not in gradle and "3.9.0" not in podspec,
        "默认编译链没有混入 Lynx 3.9.0",
    )
    require(
        "xelement-video" not in gradle and "XElement/Video" not in podspec,
        "XElement 清单严格限定 release/4.0，未混入后续 nightly Video",
    )

    xelement_doc = read("XELEMENT_INTEGRATION.md")
    require(
        all(name in xelement_doc for name in expected_android_xelement)
        and all(name in xelement_doc for name in expected_ios_xelement),
        "XElement 接入文档覆盖 Android/iOS 全量清单",
    )


def bridge_contract() -> None:
    shared_methods = {
        "open",
        "close",
        "back",
        "popTo",
        "popToWithOptions",
        "closeAll",
        "closeAllWithOptions",
        "reLaunch",
        "redirect",
        "getNavigationState",
        "closeWithResult",
        "consumeNavigationResult",
        # 三端统一消息协议：页面 -> 宿主、全局广播、按 pageId 定向发送。
        "emitToNative",
        "broadcast",
        "sendToPage",
        "prepareRoute",
        "cancelPreparedRoute",
        "markTransitionReady",
        "getTransitionState",
        "setStorageItem",
        "getStorageItem",
        "removeStorageItem",
        "clearStorage",
        "getAppInfo",
    }
    media_methods = {
        "chooseMedia",
        "uploadFile",
        "uploadImage",
        "downloadFile",
        "saveDataURL",
    }
    # Android/iOS Router 都暴露 OTA 磁盘清理能力；Harmony 的 ArkTS Router 使用
    # 宿主级 API，不通过这个 LynxShellModule methodLookup 暴露。OTA 仍是可选扩展，
    # 不改变三端基础 Bridge 契约。
    ota_methods = {"deleteOtaBundles", "deleteAllOtaBundles"}
    android = read("android/lynx-shell/src/main/java/com/example/lynxshell/bridge/LynxShellModule.kt")
    ios = read("ios/LynxShellKit/Bridge/LynxShellModule.swift")
    typescript = read("examples/lynx-shell-module.d.ts")
    playground_typescript = read("playground/src/typing.d.ts")

    android_methods = set(re.findall(r"@LynxMethod\s+fun\s+(\w+)\s*\(", android))
    lookup_match = re.search(r"methodLookup[^\{]*\{(.*?)\n\s*\}", ios, flags=re.S)
    ios_methods = set(re.findall(r'"([A-Za-z]\w*)"\s*:', lookup_match.group(1) if lookup_match else ""))
    interface_match = re.search(r"export interface LynxShellModule\s*\{(.*?)\n\}", typescript, flags=re.S)
    # d.ts 中 OTA 方法是可选的（`method?: (...) => void`），静态检查仍需识别它们。
    ts_methods = set(re.findall(r"^\s*(\w+)\??\s*(?::\s*)?\(", interface_match.group(1) if interface_match else "", flags=re.M))
    # 回调参数本身也符合 `callback: (`，它不是 NativeModules 方法。
    ts_methods.discard("callback")
    playground_match = re.search(
        r"LynxShellModule:\s*\{(.*?)\n\s*\};",
        playground_typescript,
        flags=re.S,
    )
    playground_methods = set(
        re.findall(
            r"^\s*(\w+)\??\s*(?::\s*)?\(",
            playground_match.group(1) if playground_match else "",
            flags=re.M,
        )
    )
    playground_methods.discard("callback")

    require(
        android_methods == shared_methods | media_methods | ota_methods,
        f"Android Bridge 方法完整：{', '.join(sorted(android_methods))}",
    )
    require(
        ios_methods == shared_methods | media_methods | ota_methods,
        f"iOS Bridge methodLookup 完整：{', '.join(sorted(ios_methods))}",
    )
    require(
        ts_methods == shared_methods | ota_methods,
        f"跨端 TypeScript NativeModules 声明完整：{', '.join(sorted(ts_methods))}",
    )
    require(
        playground_methods == shared_methods | media_methods | ota_methods,
        f"Playground NativeModules 声明完整：{', '.join(sorted(playground_methods))}",
    )
    require(
        android_methods - media_methods - ota_methods
        == ios_methods - media_methods - ota_methods
        == playground_methods - media_methods - ota_methods
        == ts_methods - ota_methods
        == shared_methods
        and ota_methods <= android_methods
        and ota_methods <= ios_methods
        and ota_methods <= ts_methods
        and ota_methods <= playground_methods,
        "Android、iOS 与 Playground NativeModules 基础契约一致（OTA 为 Android/iOS 可选扩展）",
    )
    advanced_navigation_methods = {
        "back",
        "popTo",
        "popToWithOptions",
        "closeAll",
        "closeAllWithOptions",
        "reLaunch",
        "redirect",
        "getNavigationState",
        "closeWithResult",
        "consumeNavigationResult",
    }
    require(
        advanced_navigation_methods <= android_methods
        and advanced_navigation_methods <= ios_methods
        and advanced_navigation_methods <= playground_methods,
        "Android/iOS/Playground 高级导航方法完整",
    )
    require(
        android.count("/**") >= 20 and ios.count("/**") >= 20,
        "Android/iOS LynxShellModule 公共能力包含完整中文职责注释",
    )
    forbidden = ("sparkling-method", "spkPipe", "autolink", "codegen")
    playground_native = read("playground/src/lib/nativeModules.ts")
    android_media = read(
        "android/lynx-shell/src/main/java/com/example/lynxshell/bridge/ShellMediaBridge.kt"
    )
    ios_media = read("ios/LynxShellKit/Bridge/ShellMediaBridge.swift")
    require(
        "NativeModules.LynxShellModule" in playground_native,
        "Playground 只通过官方 NativeModules.LynxShellModule 进入宿主",
    )
    require(
        not any(name in _structural_code(android_media) for name in forbidden)
        and not any(name in _structural_code(ios_media) for name in forbidden),
        "Android/iOS 媒体能力未引入 Sparkling autolink 运行链",
    )
    require(
        "Arguments.makeNativeMap" in android
        and "private fun nativeMap" in android
        and "Arguments.makeNativeMap" in android_media
        and re.search(r"callback\.invoke\(\s*hashMapOf", android) is None
        and re.search(r"callback\.invoke\(\s*hashMapOf", android_media) is None,
        "Android 对象型 NativeModule 回调递归编码为 JavaOnlyMap",
    )


def transition_contract() -> None:
    """验证简洁预设、真实容器动画和系统返回单一所有权。"""
    navigation = read("playground/src/lib/navigation.ts")
    gallery = read("playground/src/pages/transition-gallery/App.tsx")
    detail = read("playground/src/pages/transition-detail/App.tsx")
    share_component = read("playground/src/components/ShareElement/index.tsx")
    config = read("playground/lynx.shared.config.ts")
    home = read("playground/src/pages/main/App.tsx")

    wrapper_tokens = [
        "export type TransitionPreset",
        "export function navigateWithPreset",
        "export function navigateSharedElement",
        "export function navigateSharedElements",
        "export function navigateOpenContainer",
        "export function shareElementSelector",
        "export function onRouteDone",
        "bundle: string",
        "sharedElements?: SharedElementSpec[]",
        "routeConfig?: SkylineRouteConfig",
        "routeOptions?: SkylineRouteOptions",
    ]
    require(
        all(token in navigation for token in wrapper_tokens),
        "Playground 提供 bundle/preset/key/selector 最小参数与完整声明式转场 API",
    )
    require(
        "durationMs:" not in navigation[navigation.index("function presetTransition"):navigation.index(
            "/**\n * 推荐给业务使用的转场入口"
        )],
        "业务预设不暴露或重复写入 duration/fallback/readyTimeout 框架参数",
    )
    require(
        "navigateSharedElements(" in gallery
        and "navigateOpenContainer(" in gallery
        and "navigateWithPreset(" in gallery
        and 'id="transition-card-source"' in gallery
        and 'shareKey="product-cover-10001"' in gallery
        and 'shareKey="product-cover-10001"' in detail
        and 'shareKey="product-title-10001"' in gallery
        and 'shareKey="product-title-10001"' in detail
        and 'shareKey="product-price-10001"' in gallery
        and 'shareKey="product-price-10001"' in detail
        and "product-sneaker.jpg?inline" in gallery
        and "product-sneaker.jpg?inline" in detail
        and "shareElementSelector(props.shareKey)" in share_component
        and "flatten={false}" in share_component
        and "onRouteDone(" in detail,
        "丰富商品演示使用封面/标题/价格三个真实原生共享节点、内联图片与路由完成事件",
    )
    route_types = [
        "wx://bottom-sheet",
        "wx://upwards",
        "wx://zoom",
        "wx://cupertino-modal",
        "wx://cupertino-modal-inside",
        "wx://modal-navigation",
        "wx://modal",
    ]
    require(
        all(route_type in navigation and route_type in gallery for route_type in route_types),
        "Playground 七种 Skyline preset-route 均有 typed 映射与可点击演示",
    )
    require(
        "shuttleOnPush" in navigation
        and "shuttleOnPop" in navigation
        and "rectTweenType" in navigation
        and "transitionOnGesture: item.transitionOnGesture ?? true" in navigation
        and "items.length === 0 || items.length > 8" in navigation,
        "Playground 共享元素支持 shuttle、内置曲线、手势和最多八元素约束",
    )
    route_config_fields = [
        "opaque?: boolean",
        "maintainState?: boolean",
        "transitionDuration?: number",
        "reverseTransitionDuration?: number",
        "barrierColor?: string",
        "barrierDismissible?: boolean",
        "barrierLabel?: string",
        "canTransitionTo?: boolean",
        "canTransitionFrom?: boolean",
        "allowEnterRouteSnapshotting?: boolean",
        "allowExitRouteSnapshotting?: boolean",
        "fullscreenDrag?: boolean",
        "popGestureDirection?: 'horizontal' | 'vertical' | 'multi'",
    ]
    require(
        all(field in navigation for field in route_config_fields)
        and "round?: boolean" in navigation
        and "height?: number" in navigation,
        "Playground 完整声明 routeConfig 与 bottom-sheet routeOptions",
    )
    require(
        "closedCornerRadius: 20" not in navigation
        and "transitionDuration?: number" in navigation
        and "transitionType?: 'fade' | 'fadeThrough'" in navigation,
        "Open Container 简洁 helper 使用原生 white/0/300/fade 默认且保留九项覆盖",
    )
    open_demo_fields = [
        "closedColor:",
        "middleColor:",
        "openColor:",
        "closedCornerRadius:",
        "openCornerRadius:",
        "closedElevation:",
        "openElevation:",
        "transitionType:",
        "transitionDuration:",
    ]
    require(
        all(field in gallery for field in open_demo_fields),
        "Open Container 演示显式覆盖颜色、圆角、影深、内容过渡和时长",
    )
    require(
        "'transition-gallery': './src/pages/transition-gallery/index.tsx'" in config
        and "'transition-detail': './src/pages/transition-detail/index.tsx'" in config
        and "transition-gallery.lynx.bundle" in home,
        "转场 Gallery/Detail 已注册并接入 Playground 首页",
    )
    demo_code = _structural_code(gallery + "\n" + detail + "\n" + share_component)
    require(
        re.search(r"<(?:div|span|img|p)(?:\\s|>)", demo_code) is None,
        "ReactLynx 转场页面未使用 Web DOM 元素",
    )

    android_coordinator = read(
        "android/lynx-shell/src/main/java/com/example/lynxshell/transition/LynxTransitionCoordinator.kt"
    )
    android_activity = read(
        "android/lynx-shell/src/main/java/com/example/lynxshell/container/LynxShellActivity.kt"
    )
    android_navigator = read(
        "android/lynx-shell/src/main/java/com/example/lynxshell/routing/LynxNavigator.kt"
    )
    android_compat = read(
        "android/lynx-shell/src/main/java/com/example/lynxshell/transition/LynxCompatEdgeBackLayout.kt"
    )
    android_runtime = read(
        "android/lynx-shell/src/main/java/com/example/lynxshell/transition/LynxTransitionRuntime.kt"
    )
    android_resolver = read(
        "android/lynx-shell/src/main/java/com/example/lynxshell/transition/LynxElementResolver.kt"
    )
    android_snapshotter = read(
        "android/lynx-shell/src/main/java/com/example/lynxshell/transition/LynxSnapshotter.kt"
    )
    android_spec = read(
        "android/lynx-shell/src/main/java/com/example/lynxshell/transition/LynxTransitionSpec.kt"
    )
    android_morph = read(
        "android/lynx-shell/src/main/java/com/example/lynxshell/transition/LynxOpenContainerMorphView.kt"
    )
    require(
        "private fun handleSystemBackCommit()" in android_coordinator
        and "predictiveBackCallback.isEnabled = interceptSystemBack" in android_coordinator
        and "runFallbackPop(" in android_coordinator
        and "onBackPressedDispatcher.onBackPressed()" not in android_coordinator,
        "Android 显式自定义转场始终拦截 Back，失败时也不回落系统返回动画",
    )
    require(
        "overrideActivityTransition(" in android_activity
        and "overridePendingTransition(0, 0)" in android_activity
        and "suppressCloseAnimation(activity)" in android_navigator,
        "Android 自定义视觉与 Activity Window 动画保持单一所有权",
    )
    require(
        "progress >= 0.42f" in android_compat
        and "progress >= 0.12f" in android_compat
        and "forwardVelocityDp >= 700f" in android_compat
        and "systemGestureExclusionRects" in android_compat,
        "Android API 24-33 edge 返回包含阈值、速度、RTL 与有界系统手势排除",
    )
    require(
        "handleOnBackStarted" in android_coordinator
        and "handleOnBackProgressed" in android_coordinator
        and "handleOnBackCancelled" in android_coordinator,
        "Android 14+ Predictive Back progress 生命周期已接入",
    )
    require(
        "override fun onFirstScreen()" in android_activity
        and "findViewByIdSelector" in android_resolver
        and "getRectToWindow()" in android_resolver,
        "Android 共享元素使用 Lynx 首屏与原生 Window 几何",
    )
    require(
        "ActivityOptions" not in android_runtime
        and "makeCustomAnimation" not in android_runtime
        and "ActivityOptions" not in android_navigator
        and "makeCustomAnimation" not in android_navigator,
        "Android 显式转场启动链不再调用 framework Activity 动画",
    )
    require(
        "fun clearWindowRects(" in android_snapshotter
        and "sampleBackdropColor(windowBitmap, local)" in android_snapshotter
        and "canvas.drawRect(local, backdropPaint)" in android_snapshotter
        and "PorterDuff.Mode.CLEAR" not in android_snapshotter
        and "source_underlay_redaction_failed" in android_runtime,
        "Android shared/open 会以邻近背景回填 source underlay 且失败时显式降级",
    )
    require(
        "targetFrameReady = false" in android_coordinator
        and "targetFrameReady = true" in android_coordinator
        and "!firstScreenReady || !targetFrameReady" in android_coordinator
        and "TARGET_FRAME_SETTLE_MS = 64L" in android_coordinator,
        "Android shared/open 等待 Lynx 首屏后的真实原生绘制帧",
    )
    require(
        "if (!firstScreenReady && isWaitingForEnter())" in android_coordinator
        and "transitionCoordinator.onLoadError()" in android_activity,
        "Android 首屏后的图片等子资源错误不会取消整页转场",
    )
    require(
        "val originalAlpha = view.alpha" in android_snapshotter
        and "view.alpha = 1f" in android_snapshotter
        and "view.alpha = originalAlpha" in android_snapshotter,
        "Android 目标页离屏快照临时恢复 alpha 并立即还原",
    )
    require(
        "DEFAULT_ANDROID_TRANSITION_DURATION_MS = 420L" in android_spec
        and "DEFAULT_ANDROID_READY_TIMEOUT_MS = 1_000L" in android_spec,
        "Android 默认转场时长与首屏门禁适配真实 Activity Window 交接",
    )
    require(
        "if (!activity.isFinishing)" in android_coordinator
        and "交给\n            // onDestroy 统一清理" in android_coordinator,
        "Android pop 在上一页 Surface 恢复前保留共享元素冻结尾帧",
    )
    require(
        android_navigator.count("finishEntriesWithTransition(") >= 8
        and "transitionSpecOverride = options.transitionSpec" in android_navigator
        and "forceTransaction = true" in android_navigator
        and "batch_target_snapshot_unavailable" in android_navigator
        and "finishEntries(context, entries, animated = false)" in android_navigator,
        "Android clearTop/singleTask/back/popTo/closeAll/reLaunch 只动画一次并静默提交剩余栈",
    )
    require(
        "enter_route_snapshotting_disabled" in android_runtime
        and "exit_route_snapshotting_disabled" in android_coordinator
        and "enforceSecondaryTransitionPolicy()" in android_coordinator,
        "Android snapshot flags 是硬边界，canTransition 仅控制次级 route",
    )
    require(
        "releaseContentForRouteSnapshot()" in android_runtime
        and "restoreContentReleasedForRouteSnapshot()" in android_runtime
        and "maintain_state_false_host_activity_not_releasable" in android_runtime,
        "Android maintainState=false 会释放可重建的 Lynx 内容并报告宿主边界",
    )
    require(
        "LynxTransitionStatus.FAILED" in android_runtime
        and '"onTransitionSettled"' in android_runtime
        and "LynxTransitionStatus.FAILED" in android_coordinator
        and '"onTransitionSettled"' in android_coordinator,
        "Android 启动、提交失败与 none 路径均有原生终态事件",
    )
    require(
        "coerceAtLeast(80L)" not in android_coordinator
        and "remainingDuration(" in android_coordinator
        and "LynxContainerContentTransition.FADE_THROUGH" in android_morph
        and "middleColor 只参与 fadeThrough" in android_morph,
        "Android 反向时长按剩余比例计算，middleColor 只参与 fadeThrough",
    )

    ios_coordinator = read(
        "ios/LynxShellKit/Transition/ShellTransitionCoordinator.swift"
    )
    ios_animator = read(
        "ios/LynxShellKit/Transition/ShellNavigationAnimator.swift"
    )
    ios_container = read(
        "ios/LynxShellKit/Container/LynxContainerViewController.swift"
    )
    require(
        "UIScreenEdgePanGestureRecognizer" in ios_coordinator
        and "UIPercentDrivenInteractiveTransition" in ios_coordinator
        and "let usesCustom" in ios_coordinator
        and "interactivePopGestureRecognizer?.isEnabled" in ios_coordinator
        and "shouldRecognizeSimultaneouslyWith" in ios_coordinator,
        "iOS 系统侧滑与壳 edge 手势由同一 coordinator 互斥管理",
    )
    require(
        "if animationController is ShellNavigationAnimator" in ios_coordinator
        and "return transitionCoordinator.interactionController" in ios_coordinator,
        "iOS 壳 animator 不接受宿主 downstream 的交互控制器",
    )
    require(
        "UIViewPropertyAnimator" in ios_animator
        and "transitionWasCancelled" in ios_animator
        and "completeTransition(!cancelled)" in ios_animator,
        "iOS 自定义转场使用可中断 animator 并正确提交或取消",
    )
    require(
        "waitUntilFirstScreen" in ios_container
        and "view(withIdSelector:" in ios_container,
        "iOS 共享元素使用 Lynx 首屏与原生 UIView selector",
    )
    require(
        "func beginPop(" in ios_coordinator
        and "forceCustomAnimator" in ios_coordinator
        and "forceCustomAnimator: true" in read(
            "ios/LynxShellKit/Routing/ShellNavigator.swift"
        )
        and "func completeImmediatePop(" in ios_coordinator
        and "func failActiveTransition(" in ios_coordinator,
        "iOS clearTop/singleTask/批量 pop 使用显式壳事务，none 与失败路径也会收口",
    )
    require(
        "effectiveStyle == spec.baseEffectiveStyle" in ios_animator
        and "route_snapshot_disabled" in ios_animator
        and "route_snapshot_unavailable" in ios_animator,
        "iOS preset 仅在未降级时使用对应 renderer，snapshot 禁用或失败会显式 fallback",
    )
    require(
        r".filter(\.transitionOnGesture)" in ios_coordinator
        and "shadowHost" in ios_animator
        and "clipHost" in ios_animator,
        "iOS 共享元素逐项消费手势开关，并分离阴影层与裁剪层",
    )
    ios_spec = read("ios/LynxShellKit/Model/ShellTransitionSpec.swift")
    ios_color = read("ios/LynxShellKit/UI/UIColor+ShellHex.swift")
    require(
        "optionalColorAllowingEmpty" in ios_spec
        and "middleColor: String?" in ios_spec
        and "darkgray" in ios_color
        and "rgba" in ios_color,
        "iOS Open Container middleColor 可空，颜色名与 rgb/rgba/hex 解析完整",
    )
    require(
        "onTransitionSettled" in ios_coordinator
        and "state.status == .failed" in ios_coordinator
        and "allowsSystemChromeAnimation" in ios_coordinator
        and "scrollViewsAllowPop" in ios_coordinator,
        "iOS 终态事件、导航栏动画抑制与滚动边界手势仲裁均由 coordinator 收口",
    )

    android_prepared = read(
        "android/lynx-shell/src/main/java/com/example/lynxshell/transition/PreparedRouteStore.kt"
    )
    ios_prepared = read(
        "ios/LynxShellKit/Resource/ShellPreparedRouteStore.swift"
    )
    require(
        "TTL_MS = 30_000L" in android_prepared
        and "MAX_ENTRIES = 4" in android_prepared
        and "MAX_TOTAL_BYTES = 32L * 1024L * 1024L" in android_prepared
        and "private let ttl: TimeInterval = 30" in ios_prepared
        and "private let maximumEntries = 4" in ios_prepared
        and "private let maximumTotalBytes = 32 * 1024 * 1024" in ios_prepared,
        "Android/iOS prepareRoute 缓存冻结为 30 秒、4 条、32 MB",
    )

    transition_doc = read("TRANSITIONS_README.md")
    require(
        "navigateWithPreset" in transition_doc
        and "navigateSharedElement" in transition_doc
        and "navigateOpenContainer" in transition_doc
        and "系统" in transition_doc
        and "单一" in transition_doc,
        "转场 README 覆盖最小参数 API 与系统/自定义动画单一所有权",
    )


def route_and_provider() -> None:
    android_route = read("android/lynx-shell/src/main/java/com/example/lynxshell/routing/LynxRouteParser.kt")
    ios_route = read("ios/LynxShellKit/Routing/LynxRouteParser.swift")
    aliases = [
        "file://lynx?local://",
        "hybrid",
        "lynxview_page",
        "hide_nav_bar",
        "hide_status_bar",
        "screen_orientation",
        "initial_data",
        "global_props",
    ]
    require(all(alias in android_route for alias in aliases), "Android 路由兼容 Explorer 与 Sparkling 参数")
    require(all(alias in ios_route for alias in aliases), "iOS 路由兼容 Explorer 与 Sparkling 参数")
    harmony_route = read("harmony/lynx_shell_kit/src/main/ets/routing/LynxRouteParser.ets")
    harmony_policy = read("harmony/lynx_shell_kit/src/main/ets/common/ShellSecurityPolicy.ets")
    android_request = read(
        "android/lynx-shell/src/main/java/com/example/lynxshell/model/LynxPageRequest.kt"
    )
    require(
        "val isDirectRemote = LynxPageRequest.isRemoteBundleUrl(bundleUrl)" in android_route
        and "?.takeUnless { isDirectRemote }" in android_route
        and "val isDirectRemote = LynxPageRequest.isRemoteBundleUrl(base.bundleUrl)" in android_route
        and "HTTPS Bundle 是直连页面，不能携带 OTA" in android_request
        and "RemoteBundlePolicy.isRemote(bundleURL) ? nil : requestedAppId" in ios_route
        and "if (ShellSecurityPolicy.isRemoteUrl(request.bundleUrl))" in harmony_route
        and "request.lynxAppId = '';" in harmony_route
        and "request.bundleName = '';" in harmony_route
        and "static isRemoteUrl" in harmony_policy,
        "三端 Direct HTTPS 与 OTA 身份严格隔离",
    )
    android_activity = read(
        "android/lynx-shell/src/main/java/com/example/lynxshell/container/LynxShellActivity.kt"
    )
    android_launcher = read(
        "android/app/src/main/java/com/example/lynxshell/sample/MainActivity.kt"
    )
    android_launcher_layout = read("android/app/src/main/res/layout/activity_launcher.xml")
    require(
        "val fullscreen: Boolean = true" in android_request
        and "val hideStatusBar: Boolean = false" in android_request
        and 'bool(first(query, "fullscreen"), true)' in android_route
        and "getBooleanExtra(LynxPageRequest.EXTRA_FULLSCREEN, true)" in android_route
        and "getBooleanExtra(LynxPageRequest.EXTRA_HIDE_STATUS_BAR, false)" in android_route
        and "Color.TRANSPARENT else background" in android_activity
        and "WindowCompat.setDecorFitsSystemWindows(window, !request.fullscreen)" in android_activity
        and "WindowManager.LayoutParams.FLAG_FULLSCREEN" in android_activity
        and (
            "fullscreenSwitch.isChecked = true" in android_launcher
            or (
                "open_ota_button" in android_launcher_layout
                and "clear_ota_button" in android_launcher_layout
            )
        ),
        "Android Bundle 默认无 Toolbar、状态栏透明可见且 LynxView edge-to-edge",
    )
    ios_scene = read("ios/LynxShellSample/App/SceneDelegate.swift")
    ios_launcher = read("ios/LynxShellSample/UI/LauncherViewController.swift")
    ios_container = read(
        "ios/LynxShellKit/Container/LynxContainerViewController.swift"
    )
    require(
        'let fullscreen = bool(first(query, keys: ["fullscreen"]), default: true)' in ios_route
        # Launcher 已经从旧的参数表单改为三端统一的原生壳验收页；
        # 启动页隐藏 UINavigationBar，Lynx 页面本身仍由 LynxPageRequest 的
        # fullscreen/showNavigationBar/hideStatusBar 默认值控制。
        and "setNavigationBarHidden(true, animated: false)" in ios_launcher
        and "原生壳" in ios_launcher
        and "OTA 验收入口" in ios_launcher
        and "override var prefersStatusBarHidden: Bool { request.hideStatusBar }" in ios_container
        and "shellIsLightColor" in ios_container,
        "iOS Bundle 默认无导航栏、状态栏透明可见且 LynxView edge-to-edge",
    )
    android_global_props = read(
        "android/lynx-shell/src/main/java/com/example/lynxshell/runtime/ShellGlobalPropsFactory.kt"
    )
    ios_global_props = read(
        "ios/LynxShellKit/Runtime/ShellGlobalPropsFactory.swift"
    )
    require(
        all(
            field in android_global_props and field in ios_global_props
            for field in [
                'queryItems["fullscreen"]',
                'queryItems["hide_nav_bar"]',
                'queryItems["hide_status_bar"]',
                'queryItems["trans_status_bar"]',
            ]
        ),
        "Android/iOS 向 Lynx 注入最终采用的沉浸式容器状态",
    )

    android_provider = read("android/lynx-shell/src/main/java/com/example/lynxshell/resource/ShellTemplateProvider.kt")
    ios_provider = read("ios/LynxShellKit/Resource/ShellTemplateProvider.swift")
    require("MAX_BUNDLE_BYTES" in android_provider and "20L * 1024L * 1024L" in android_provider, "Android Provider 限制 Bundle 最大体积")
    require("maximumBundleBytes" in ios_provider and "20 * 1024 * 1024" in ios_provider, "iOS Provider 限制 Bundle 最大体积")
    require("activeCalls" in android_provider and "Call::cancel" in android_provider, "Android Provider 支持生命周期取消")
    require("activeTasks" in ios_provider and "invalidateAndCancel" in ios_provider, "iOS Provider 支持生命周期取消")
    require(
        "isRemoteHostAllowed" not in android_provider
        and "RemoteBundlePolicy.isAllowed" not in ios_provider,
        "Android/iOS Provider 不限制远程 Host",
    )
    require(
        "finalUrl.scheme" in android_provider and "finalScheme" in ios_provider,
        "Android/iOS Provider 继续校验重定向协议",
    )

    android_navigator = read(
        "android/lynx-shell/src/main/java/com/example/lynxshell/routing/LynxNavigator.kt"
    )
    ios_navigator = read("ios/LynxShellKit/Routing/ShellNavigator.swift")
    launch_modes = ["push", "singleTop", "clearTop", "singleTask"]
    require(
        all(mode in android_navigator for mode in launch_modes)
        and all(mode in ios_navigator for mode in launch_modes),
        "Android/iOS 四种 launch mode 语义均已实现",
    )
    navigation_tokens = [
        "entryID",
        "sessionID",
        "getNavigationState",
        "closeWithResult",
        "consumeNavigationResult",
        "deduplicateWindowMs",
    ]
    # Swift 对应方法名为 navigationState，但 Module 对外仍是 getNavigationState。
    require(
        all(token in android_navigator for token in navigation_tokens)
        and all(
            (token in ios_navigator)
            or (token == "getNavigationState" and "navigationState" in ios_navigator)
            or (
                token == "deduplicateWindowMs"
                and "deduplicateWindowMilliseconds" in ios_navigator
            )
            for token in navigation_tokens
        ),
        "Android/iOS 导航身份、栈查询、页面结果与防重复实现完整",
    )
    require("finishAffinity" not in _structural_code(android_navigator), "Android 导航未清空整个 task")
    require(
        "EXTRA_ENTRY_ORDER" in android_navigator
        and "restoreNavigationStackIfPossible" in ios_navigator
        and "navigationSnapshot" in ios_navigator,
        "Android Activity 重建元数据与 iOS Scene 快照恢复已接入",
    )
    navigation_doc = read("NAVIGATION_README.md")
    document_tokens = [
        "NativeModules.LynxShellModule",
        "back(delta)",
        "singleTop",
        "clearTop",
        "singleTask",
        "closeWithResult",
        "consumeNavigationResult",
        "路由拦截",
        "AppHomeHandler",
        "ShellAppHomeHandler",
    ]
    require(
        all(token in navigation_doc for token in document_tokens),
        "高级导航 README 覆盖页面调用、宿主接线、结果、launch mode 与排除项",
    )


def build_config_safety() -> None:
    manifest = read("android/app/src/main/AndroidManifest.xml")
    app_gradle = read("android/app/build.gradle.kts")
    module_gradle = read("android/lynx-shell/build.gradle.kts")
    require('android:usesCleartextTraffic="${usesCleartextTraffic}"' in manifest, "Android Manifest 使用构建类型明文网络占位符")
    require('manifestPlaceholders["usesCleartextTraffic"] = "true"' in app_gradle, "Android Sample Debug 显式配置调试期 HTTP 能力")
    require('manifestPlaceholders["usesCleartextTraffic"] = "false"' in app_gradle, "Android Sample Release 从系统层关闭明文 HTTP")
    require(
        "ALLOWED_REMOTE_BUNDLE_HOSTS" not in module_gradle,
        "Android Library 不配置远程 Bundle Host 白名单",
    )

    pbx = read("ios/LynxShell.xcodeproj/project.pbxproj")
    require(
        re.search(
            r'INFOPLIST_FILE\s*=\s*"?LynxShellSample/Supporting/Info-Debug\.plist"?;',
            pbx,
        ) is not None,
        "Xcode Debug 指向 Info-Debug.plist",
    )
    require(
        re.search(
            r'INFOPLIST_FILE\s*=\s*"?LynxShellSample/Supporting/Info\.plist"?;',
            pbx,
        ) is not None,
        "Xcode Release 指向 Info.plist",
    )
    require("Bundles in Resources" in pbx, "Xcode 资源阶段包含 Bundles 文件夹")
    require(pbx.count("{") == pbx.count("}"), "Xcode project.pbxproj 花括号平衡")

    plutil = shutil.which("plutil")
    if plutil:
        with tempfile.NamedTemporaryFile("w", suffix=".pbxproj", delete=False, encoding="utf-8") as file:
            # Apple 的首行 UTF8 标记是注释；Linux plutil 的 OpenStep 解析器需要先移除。
            file.write("\n".join(pbx.splitlines()[1:]))
            temporary_path = file.name
        try:
            proc = subprocess.run(
                [plutil, "-lint", temporary_path],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
            require(proc.returncode == 0, "Xcode project.pbxproj 通过 OpenStep plist 解析")
        finally:
            Path(temporary_path).unlink(missing_ok=True)
    else:
        warn("当前环境没有 plutil，跳过 project.pbxproj OpenStep 解析")


def official_bundle_library() -> None:
    """验证 go.lynxjs.org 示例页、565 条数据快照和双端 HTTPS 加载策略。"""
    data = read("playground/src/data/goLynxBundleUrls.ts")
    match = re.search(r"String\.raw`(.*?)`\.trim\(\)\.split", data, flags=re.S)
    paths = [
        line.strip()
        for line in (match.group(1).splitlines() if match else [])
        if line.strip()
    ]
    require(
        len(paths) == 565
        and len(set(paths)) == 565
        and all(path.endswith(".lynx.bundle") for path in paths),
        "官方 Bundle 示例清单包含 565/565 个唯一 Lynx Bundle",
    )

    config = read("playground/lynx.shared.config.ts")
    home = read("playground/src/pages/main/App.tsx")
    page = read("playground/src/pages/go-bundles/App.tsx")
    require(
        "'go-bundles': './src/pages/go-bundles/index.tsx'" in config
        and "go-bundles.lynx.bundle" in home
        and "GO_LYNX_BUNDLE_EXAMPLES" in page
        and "PAGE_SIZE = 40" in page,
        "Playground 已注册可搜索、分类和分批渲染的官方 Bundle 页面",
    )
    require(
        "navigate({" in page and "path: item.url" in page,
        "官方 Bundle 页面通过手写 NativeModules 导航封装打开远程 URL",
    )

    gradle = read("android/lynx-shell/build.gradle.kts")
    with (ROOT / "ios/LynxShellSample/Supporting/Info.plist").open("rb") as file:
        release_plist = plistlib.load(file)
    with (ROOT / "ios/LynxShellSample/Supporting/Info-Debug.plist").open("rb") as file:
        debug_plist = plistlib.load(file)
    require(
        "go.lynxjs.org" in data
        and "https://" in data
        and "LynxAllowedBundleHosts" not in release_plist
        and "LynxAllowedBundleHosts" not in debug_plist
        and "ALLOWED_REMOTE_BUNDLE_HOSTS" not in gradle,
        "官方 Bundle 示例使用 HTTPS，Android/iOS Demo 不配置远程 Host 白名单",
    )


def script_syntax() -> None:
    bash = shutil.which("bash")
    if bash:
        proc = subprocess.run(
            [bash, "-n", str(ROOT / "scripts/sync_bundle.sh")],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        require(proc.returncode == 0, "Bundle 同步 Bash 脚本语法通过")
    else:
        warn("当前环境没有 bash，跳过同步脚本语法检查")

    ruby = shutil.which("ruby")
    if ruby:
        ruby_files = [
            ROOT / "ios/Podfile",
            ROOT / "ios/LynxShellKit.podspec",
            ROOT / "ios/scripts/sync_sample_project.rb",
        ]
        errors: list[str] = []
        for path in ruby_files:
            proc = subprocess.run(
                [ruby, "-c", str(path)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
            if proc.returncode != 0:
                errors.append(f"{path.relative_to(ROOT)}: {proc.stderr.strip()}")
        require(
            not errors,
            "iOS Podfile、Podspec 与工程同步脚本 Ruby 语法通过"
            if not errors
            else "; ".join(errors),
        )
    else:
        warn("当前环境没有 Ruby，跳过 Podfile 语法检查")


def sparkling_isolation() -> None:
    # LynxScreens-Android 是历史交付物，内含 Git 自带的 *.sample hook；这些不是
    # Sparkling 适配样例，不能被跨平台样例隔离检查误判。
    samples = sorted(
        path for path in ROOT.rglob("*.sample") if ".git" not in path.parts
    )
    require(bool(samples), "提供 Android/iOS Sparkling 可选适配样例")
    require(all("integration" in str(path).lower() for path in samples), "Sparkling 样例全部位于隔离目录")

    android_main = list((ROOT / "android/app/src/main").rglob("*.sample"))
    require(not android_main, "Android 默认 sourceSet 未包含 Sparkling .sample")

    pbx = read("ios/LynxShell.xcodeproj/project.pbxproj")
    sample_names = [path.name for path in samples if "ios" in str(path).lower()]
    require(not any(name in pbx for name in sample_names), "iOS 默认 Xcode target 未包含 Sparkling .sample")


def comments_and_shell_style() -> None:
    source_paths = (
        list((ROOT / "android/lynx-shell/src/main/java").rglob("*.kt"))
        + list((ROOT / "android/app/src/main/java").rglob("*.kt"))
        + list((ROOT / "ios/LynxShellKit").rglob("*.swift"))
        + list((ROOT / "ios/LynxShellSample").rglob("*.swift"))
        + list((ROOT / "ios/LynxShellKit/Native").rglob("*.m"))
        + list((ROOT / "ios/LynxShellKit/Native").rglob("*.h"))
    )
    uncommented = []
    for path in source_paths:
        text = path.read_text(encoding="utf-8")
        if not re.search(r"(^|\n)\s*(///|/\*\*|//)", text):
            uncommented.append(str(path.relative_to(ROOT)))
    require(not uncommented, "Kotlin、Swift、Objective-C 业务源码均包含说明性注释")

    require("MaterialToolbar" in read("android/lynx-shell/src/main/res/layout/activity_lynx_shell.xml"), "Android 使用 Material 原生导航栏")
    require("UINavigationController" in read("ios/LynxShellSample/App/SceneDelegate.swift"), "iOS Sample 使用 UIKit UINavigationController 原生导航")


def _structural_code(text: str) -> str:
    """移除注释和字符串，只保留参与分隔符检查的源码字符。"""
    output: list[str] = []
    index = 0
    state = "code"
    quote = ""
    while index < len(text):
        current = text[index]
        following = text[index + 1] if index + 1 < len(text) else ""

        if state == "code":
            if text.startswith('"""', index):
                state = "triple"
                index += 3
                continue
            if current == "/" and following == "/":
                state = "line_comment"
                index += 2
                continue
            if current == "/" and following == "*":
                state = "block_comment"
                index += 2
                continue
            if current in {'"', "'"}:
                quote = current
                state = "string"
                index += 1
                continue
            output.append(current)
            index += 1
            continue

        if state == "line_comment":
            if current == "\n":
                output.append("\n")
                state = "code"
            index += 1
            continue

        if state == "block_comment":
            if current == "*" and following == "/":
                state = "code"
                index += 2
            else:
                index += 1
            continue

        if state == "triple":
            if text.startswith('"""', index):
                state = "code"
                index += 3
            else:
                index += 1
            continue

        if state == "string":
            if current == "\\":
                index += 2
            elif current == quote:
                state = "code"
                index += 1
            else:
                index += 1
            continue

    return "".join(output)


def basic_delimiter_scan() -> None:
    # 不替代编译器，仅用于在无法解析 Android/iOS SDK 依赖时捕获明显截断。
    paths = list((ROOT / "android/lynx-shell/src/main/java").rglob("*.kt"))
    paths += list((ROOT / "android/app/src/main/java").rglob("*.kt"))
    paths += list((ROOT / "android").glob("*.kts"))
    paths += list((ROOT / "android/app").glob("*.kts"))
    paths += list((ROOT / "android/lynx-shell").glob("*.kts"))
    paths += list((ROOT / "ios/LynxShellKit/Native").rglob("*.[mh]"))
    problems = []
    for path in paths:
        stripped = _structural_code(path.read_text(encoding="utf-8"))
        for opening, closing in (("{", "}"), ("(", ")"), ("[", "]")):
            if stripped.count(opening) != stripped.count(closing):
                problems.append(f"{path.relative_to(ROOT)}: {opening}{closing} 数量不平衡")
    require(not problems, "Kotlin/Objective-C 基础分隔符检查通过" if not problems else "; ".join(problems))


def main() -> int:
    checks = [
        expected_files,
        parse_xml_and_plist,
        swift_parse,
        versions,
        bridge_contract,
        transition_contract,
        route_and_provider,
        build_config_safety,
        official_bundle_library,
        script_syntax,
        sparkling_isolation,
        comments_and_shell_style,
        basic_delimiter_scan,
    ]
    for check in checks:
        try:
            check()
        except Exception as exc:  # noqa: BLE001
            fail(f"检查器内部异常 {check.__name__}: {exc}")

    print("Lynx 4.0 Native Shell 静态验收")
    print(f"工程目录: {ROOT}")
    print("范围: 结构 / XML / Plist / Swift parse / 版本 / XElement 全量 / 路由 / Bridge / 安全配置")
    print("说明: 未下载依赖，未执行 Gradle、CocoaPods 或 Xcode 编译。\n")

    for message in PASS:
        print(f"[PASS] {message}")
    for message in WARN:
        print(f"[WARN] {message}")
    for message in FAIL:
        print(f"[FAIL] {message}")

    print(f"\n结果: {len(PASS)} PASS, {len(WARN)} WARN, {len(FAIL)} FAIL")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
