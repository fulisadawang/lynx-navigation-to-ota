#!/usr/bin/env python3
"""Lynx 4.0 HarmonyOS 壳静态验收。

只检查源码、配置和跨文件契约；不会下载 OHPM 依赖，也不会替代 DevEco/Hvigor 编译。
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KIT_ROOT = "lynx_shell_kit"
PASS: list[str] = []
WARN: list[str] = []
FAIL: list[str] = []


def ok(message: str) -> None:
    PASS.append(message)


def warn(message: str) -> None:
    WARN.append(message)


def fail(message: str) -> None:
    FAIL.append(message)


def require(condition: bool, message: str) -> None:
    (ok if condition else fail)(message)


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def shell_read(relative: str) -> str:
    """Read the reusable HAR implementation, falling back to the Entry path."""
    kit_path = ROOT / KIT_ROOT / relative
    if kit_path.is_file():
        return kit_path.read_text(encoding="utf-8")
    return read(f"lynx_shell/{relative}")


def load_json(relative: str) -> dict:
    return json.loads(read(relative))


def expected_files() -> None:
    required = [
        "README.md",
        "ARCHITECTURE.md",
        "XELEMENT_INTEGRATION.md",
        "ROUTING.md",
        "SECURITY.md",
        "VALIDATION.md",
        "SOURCE_MAPPING.md",
        "THIRD_PARTY_NOTICES.md",
        "build-profile.json5",
        "oh-package.json5",
        "parameter.json",
        "hvigorfile.ts",
        "hvigor/hvigor-config.json5",
        "AppScope/app.json5",
        "lynx_shell/build-profile.json5",
        "lynx_shell/hvigorfile.ts",
        "lynx_shell/oh-package.json5",
        "lynx_shell/src/main/module.json5",
        "lynx_shell/src/main/ets/entryability/EntryAbility.ets",
        "lynx_shell/src/main/ets/entryability/LynxAbilityStage.ets",
        "lynx_shell/src/main/ets/common/LynxRuntimeInitializer.ets",
        "lynx_shell/src/main/ets/common/XElementRuntime.ets",
        "lynx_shell/src/main/ets/common/ShellSecurityPolicy.ets",
        "lynx_shell/src/main/ets/model/LynxPageRequest.ets",
        "lynx_shell/src/main/ets/routing/LynxRouteParser.ets",
        "lynx_shell/src/main/ets/routing/LynxNavigator.ets",
        "lynx_shell_kit/src/main/ets/routing/LynxRouter.ets",
        "lynx_shell/src/main/ets/provider/ShellTemplateResourceFetcher.ets",
        "lynx_shell/src/main/ets/provider/ShellGenericResourceFetcher.ets",
        "lynx_shell/src/main/ets/provider/ShellMediaResourceFetcher.ets",
        "lynx_shell/src/main/ets/client/ShellLynxViewClient.ets",
        "lynx_shell/src/main/ets/module/LynxShellModule.ets",
        "lynx_shell/src/main/ets/pages/Index.ets",
        "lynx_shell/src/main/ets/pages/LynxContainer.ets",
        "lynx_shell_kit/build-profile.json5",
        "lynx_shell_kit/hvigorfile.ts",
        "lynx_shell_kit/oh-package.json5",
        "lynx_shell_kit/src/main/module.json5",
        "lynx_shell_kit/src/main/ets/Index.ets",
        "lynx_shell_kit/src/main/ets/common/ShellMessageHub.ets",
        "lynx_shell_kit/src/main/ets/common/ShellTypes.ets",
        "lynx_shell_kit/src/main/ets/module/LynxShellModule.ets",
        "lynx_shell_kit/src/main/ets/pages/LynxContainer.ets",
        "lynx_shell_kit/src/main/ets/ota/OtaModels.ets",
        "lynx_shell_kit/src/main/ets/ota/OtaJson.ets",
        "lynx_shell_kit/src/main/ets/ota/OtaApiClient.ets",
        "lynx_shell_kit/src/main/ets/ota/ReleaseTransaction.ets",
        "lynx_shell_kit/src/main/ets/ota/LynxOtaRuntime.ets",
        "lynx_shell/src/main/resources/base/profile/main_pages.json",
        "lynx_shell_kit/src/main/module.json5",
        "lynx_shell/src/main/resources/rawfile/bundles/README.md",
        "scripts/sync_bundle.sh",
        "examples/lynx-shell-module.d.ts",
        "integration/sparkling/README.md",
    ]
    missing = [item for item in required if not (ROOT / item).is_file()]
    require(not missing, "HarmonyOS 关键工程文件完整" if not missing else f"缺少文件: {', '.join(missing)}")


def json_and_xml() -> None:
    json_files = [
        "oh-package.json5",
        "parameter.json",
        "build-profile.json5",
        "hvigor/hvigor-config.json5",
        "AppScope/app.json5",
        "AppScope/resources/base/element/string.json",
        "lynx_shell/oh-package.json5",
        "lynx_shell/build-profile.json5",
        "lynx_shell/src/main/module.json5",
        "lynx_shell/src/main/resources/base/element/string.json",
        "lynx_shell/src/main/resources/base/element/color.json",
        "lynx_shell/src/main/resources/base/profile/main_pages.json",
    ]
    errors: list[str] = []
    for relative in json_files:
        try:
            load_json(relative)
        except Exception as exc:  # noqa: BLE001
            errors.append(f"{relative}: {exc}")
    require(not errors, f"HarmonyOS JSON/JSON5 可解析（{len(json_files)} 个）" if not errors else "; ".join(errors))

    svg_files = list(ROOT.rglob("*.svg"))
    svg_errors: list[str] = []
    for path in svg_files:
        try:
            ET.parse(path)
        except Exception as exc:  # noqa: BLE001
            svg_errors.append(f"{path.relative_to(ROOT)}: {exc}")
    require(not svg_errors, f"HarmonyOS SVG 可解析（{len(svg_files)} 个）" if not svg_errors else "; ".join(svg_errors))


def versions_and_dependencies() -> None:
    root_package = load_json("oh-package.json5")
    params = load_json("parameter.json")
    module_package = load_json("lynx_shell_kit/oh-package.json5")
    entry_package = load_json("lynx_shell/oh-package.json5")
    dependencies = module_package["dependencies"]

    require(root_package["dependencies"].get("@lynx/primjs") == "4.0.0", "HarmonyOS PrimJS 固定为 4.0.0")
    require(params["dependencies"].get("lynx_version") == "4.0.0", "HarmonyOS release/4.0 OHPM 映射固定为 4.0.0")

    expected_lynx = {
        "@lynx/lynx",
        "@lynx/lynx_base",
        "@lynx/lynx_devtool",
        "@lynx/lynx_devtool_service",
        "@lynx/lynx_log_service",
        "@lynx/lynx_http_service",
        "@lynx/lynx_image_service",
        "@lynx/xelement_markdown",
        "@lynx/xelement_svg",
        "@lynx/xelement_webview",
    }
    actual_lynx = {name for name in dependencies if name.startswith("@lynx/")}
    require(actual_lynx == expected_lynx, "HarmonyOS Lynx/Service/XElement OHPM 依赖清单完整")
    require(all(dependencies[name] == "@param:dependencies.lynx_version" for name in expected_lynx), "HarmonyOS @lynx/* 统一引用 4.0.0 参数")
    require(dependencies.get("@ohos/imageknifepro") == "1.0.9", "HarmonyOS ImageKnifePro 固定为官方 Explorer 使用的 1.0.9")
    require(
        entry_package.get("dependencies") == {"@lynx/lynx-shell-kit": "file:../lynx_shell_kit"},
        "HarmonyOS Entry 业务方只直接依赖一个 LynxShellKit HAR Module",
    )

    root_text = read("oh-package.json5") + read("build-profile.json5") + read("hvigorfile.ts")
    require("file:../../" not in root_text and "gnPlugin" not in root_text, "业务壳已移除 Lynx monorepo 本地 override 与 GN 插件")
    require("externalNativeOptions" not in read("lynx_shell/build-profile.json5"), "业务壳不依赖 Explorer 源码 CMake 构建")


def xelement_full() -> None:
    runtime = shell_read("src/main/ets/common/XElementRuntime.ets")
    container = shell_read("src/main/ets/pages/LynxContainer.ets")
    package = read("lynx_shell_kit/oh-package.json5")
    expected = [
        "BlurView",
        "Input/TextArea",
        "Overlay",
        "Refresh",
        "ScrollCoordinator",
        "ViewPager",
        "Markdown",
        "SVG",
        "WebView",
    ]
    require(all(name in runtime for name in expected), "HarmonyOS XElement 9/9 能力清单完整")
    require("XElementMarkdown.initialize()" in runtime, "HarmonyOS Markdown 通过进程级 initialize 注册")
    require("new Behavior(UISVG, undefined)" in runtime and "new Behavior(UIWebView, undefined)" in runtime, "HarmonyOS SVG/WebView Behavior 全量注入")
    require("XElementRuntime.createBehaviors()" in container, "每个 HarmonyOS LynxView 使用统一 XElement BehaviorMap")
    require(all(name in package for name in ["@lynx/xelement_markdown", "@lynx/xelement_svg", "@lynx/xelement_webview"]), "HarmonyOS 三个独立 XElement OHPM 包显式声明")
    require("xelement_video" not in package.lower() and "Video" not in runtime, "HarmonyOS XElement 严格限定 release/4.0，未混入 Video")


def runtime_and_container() -> None:
    initializer = shell_read("src/main/ets/common/LynxRuntimeInitializer.ets")
    service_index = initializer.find("LynxRuntimeInitializer.registerServices();")
    env_index = initializer.find("LynxEnv.initialize(context);")
    require(service_index >= 0 and env_index > service_index, "HarmonyOS Service 在 LynxEnv.initialize 之前注册")
    require(all(marker in initializer for marker in ["LynxLogService", "LynxDevToolService", "LynxHttpService", "LynxImageService"]), "HarmonyOS Log/DevTool/HTTP/Image Service 完整")

    container = shell_read("src/main/ets/pages/LynxContainer.ets")
    markers = [
        "LynxView({",
        "templateResourceFetcher",
        "genericResourceFetcher",
        "mediaResourceFetcher",
        "modules: this.modules",
        "behaviors: this.behaviors",
        "metaData: this.metaData",
        "context.sendGlobalEvent",
        "context.setExtraTiming",
    ]
    require(all(marker in container for marker in markers), "HarmonyOS LynxView 容器输入与生命周期完整")
    entry_wrapper = read("lynx_shell/src/main/ets/pages/LynxContainer.ets")
    require("@Component" in container and "@Entry" in entry_wrapper, "HarmonyOS 容器采用 ArkUI Entry Component")


def route_and_security() -> None:
    route = shell_read("src/main/ets/routing/LynxRouteParser.ets")
    aliases = [
        "file://lynx?local://",
        "lynxshell://",
        "lynx://",
        "hybrid://",
        "lynxview_page",
        "hide_nav_bar",
        "hide_status_bar",
        "screen_orientation",
        "initial_data",
        "global_props",
        "allow_http_in_debug",
        "screenOrientation",
        "allowHttp",
    ]
    require(all(alias in route for alias in aliases), "HarmonyOS 路由兼容 Explorer、Sparkling 与统一别名")
    require("validateRequest" in route and "ShellSecurityPolicy.validateTemplateUrl" in route, "HarmonyOS 路由进入容器前执行安全校验")
    require(
        all(marker in route for marker in [
            "params.get('lynxAppId')",
            "params.get('appId')",
            "lastPathSegment",
            "request.lynxAppId = ''",
            "Direct Remote",
            "isSafeOtaBundleName",
        ]),
        "HarmonyOS scheme 支持 appId/bundleName，HTTPS 强制保持直连而不误入 OTA",
    )

    security = shell_read("src/main/ets/common/ShellSecurityPolicy.ets")
    template = shell_read("src/main/ets/provider/ShellTemplateResourceFetcher.ets")
    generic = shell_read("src/main/ets/provider/ShellGenericResourceFetcher.ets")
    require("REMOTE_BUNDLE_HOST_ALLOWLIST" not in security and "REMOTE_RESOURCE_HOST_ALLOWLIST" not in security, "HarmonyOS 远程资源不限制 Host")
    require("protocol === 'https:'" in security and "requireBundleSuffix" in security, "HarmonyOS 远程资源保留 HTTPS 与 Bundle 后缀校验")
    require("ALLOW_DEBUG_HTTP: boolean = false" in security, "HarmonyOS HTTP 调试默认关闭")
    require("MAX_BUNDLE_BYTES" in template and "response.responseCode" in template, "HarmonyOS Template Provider 校验状态码和 20 MB 上限")
    require("callback(undefined, binary)" in template and "callback(undefined, data.buffer as ArrayBuffer)" in template, "HarmonyOS Template Provider 成功回调不携带 BusinessError")
    require("activeRequests" in generic and "active.destroy()" in generic and "cancelAll()" in generic, "HarmonyOS Generic Provider 支持单请求与批量取消")
    require("callback(this.success()" not in generic and "callback(undefined" in generic, "HarmonyOS Generic Provider 成功回调不携带 BusinessError")
    require("activeRequests" in template and "cancelAll()" in template, "HarmonyOS Template Provider 支持容器级批量取消")
    container = shell_read("src/main/ets/pages/LynxContainer.ets")
    require("this.cancelPendingRequests();" in container, "HarmonyOS 页面退出与重试释放 Provider 请求")
    require("resource://rawfile/" in shell_read("src/main/ets/provider/ShellMediaResourceFetcher.ets"), "HarmonyOS Media Provider 转换 rawfile 逻辑地址")


def bridge_contract() -> None:
    module = shell_read("src/main/ets/module/LynxShellModule.ets")
    expected = {
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
        # 与 Android/iOS 对齐的页面消息协议。
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
        "chooseMedia",
        "uploadFile",
        "uploadImage",
        "downloadFile",
        "saveDataURL",
    }
    actual = set(re.findall(r"public\s+(\w+)\s*\(", module))
    require(actual == expected, f"HarmonyOS Bridge 方法完整：{', '.join(sorted(actual))}")
    require("extends LynxModule" in module and "constructor(context: LynxContext" in module, "HarmonyOS Native Module 遵循 LynxModule 构造协议")
    require("preferences.getPreferencesSync" in module and "flushSync" in module, "HarmonyOS Storage 使用独立 Preferences 持久化")
    require("platform: 'harmony'" in module, "HarmonyOS AppInfo platform 字段稳定")
    require("getNavigationState invoked" in module, "HarmonyOS Bridge 关键方法包含可观测调用日志")
    require("code: 1004" in module and "尚未接入" in module, "HarmonyOS 暂未接入能力返回稳定 1004")
    require("lynx_shell_storage" in shell_read("src/main/ets/common/ShellConstants.ets"), "HarmonyOS Storage Name 与三端契约对齐")


def manifest_and_permissions() -> None:
    module = load_json("lynx_shell/src/main/module.json5")["module"]
    require(module.get("type") == "entry" and module.get("srcEntry", "").endswith("LynxAbilityStage.ets"), "HarmonyOS 使用 Stage 模型 entry 模块")
    require(set(module.get("deviceTypes", [])) == {"phone", "tablet", "2in1"}, "HarmonyOS 壳支持 phone/tablet/2in1")
    permissions = {item["name"] for item in module.get("requestPermissions", [])}
    require(permissions == {"ohos.permission.INTERNET"}, "HarmonyOS 壳仅申请必要 INTERNET 权限")
    manifest_text = read("lynx_shell/src/main/module.json5")
    require(all(value in manifest_text for value in ["lynxshell", "lynx", "hybrid"]), "HarmonyOS Module Manifest 注册三类深链")


def sparkling_boundary() -> None:
    doc = read("integration/sparkling/README.md")
    require("不伪造 Sparkling Harmony Runtime" in doc and "hybrid://lynxview_page" in doc, "HarmonyOS Sparkling 只保留可追溯协议兼容，不伪造 Runtime")
    require(not list((ROOT / "integration/sparkling").rglob("*.ets")), "HarmonyOS Sparkling 边界说明不进入默认 ArkTS 编译链")


def comments_and_structure() -> None:
    ets_files = list((ROOT / "lynx_shell/src/main/ets").rglob("*.ets")) + list((ROOT / KIT_ROOT / "src/main/ets").rglob("*.ets"))
    uncommented: list[str] = []
    for path in ets_files:
        text = path.read_text(encoding="utf-8")
        if not re.search(r"(^|\n)\s*(//|/\*\*)", text):
            uncommented.append(str(path.relative_to(ROOT)))
    require(not uncommented, "HarmonyOS ArkTS 业务源码均包含说明性注释")
    require(len(ets_files) >= 20, f"HarmonyOS ArkTS 分层源码数量合理（{len(ets_files)} 个）")

    index = read("lynx_shell/src/main/ets/pages/Index.ets")
    require(all(name in index for name in ["Scroll()", "Column(", "Text(", "Button("]), "HarmonyOS 启动页使用原生 ArkUI 组件")
    require(
        "TextInput(" not in index and "ShellConstants.DEFAULT_ROUTE" not in index,
        "HarmonyOS 默认首页不再暴露输入地址或 main.lynx.bundle 入口",
    )
    require(
        all(marker in index for marker in ["原生壳", "OTA 验收入口", "删除全部 OTA Bundle", "platform=android", "后端开放 harmony"]),
        "HarmonyOS 原生壳首页调用真实 OTA API 并标明临时 Android 服务端兼容",
    )
    entryability = read("lynx_shell/src/main/ets/entryability/EntryAbility.ets")
    require(
        "lynx_ota_client_token" in entryability and "want.parameters" in entryability,
        "HarmonyOS Demo 支持通过 Want 临时注入 OTA 令牌且不写死秘密",
    )

    router = shell_read("src/main/ets/routing/LynxRouter.ets")
    container = shell_read("src/main/ets/pages/LynxContainer.ets")
    provider = shell_read("src/main/ets/provider/ShellTemplateResourceFetcher.ets")
    transaction = shell_read("src/main/ets/ota/ReleaseTransaction.ets")
    runtime = shell_read("src/main/ets/ota/LynxOtaRuntime.ets")
    require(all(marker in router for marker in ["openOta(", "deleteOtaBundles(", "deleteAllOtaBundles("]), "HarmonyOS Router 暴露 appId + bundleName OTA 与删除 API")
    require(all(marker in container for marker in ["prepareOtaBundle", "正在准备 OTA 页面", "attemptRollback", "PreparedPageBundle"]), "HarmonyOS 容器先 prepare/Loading 后创建 LynxView，首屏失败只回滚一次")
    require(all(marker in provider for marker in ["loadPreparedFile", "preparedStorageRoot", "ArrayBuffer", "NOFOLLOW"]), "HarmonyOS Provider 把受控 prepared file 读取为 Lynx ArrayBuffer")
    require(all(marker in transaction for marker in [".staging", "bundleSha256", "fs.fsyncSync", "currentReleaseId", "previousReleaseId", "deleteAllBundles"]), "HarmonyOS ReleaseTransaction 包含 staging/SHA/state/current-previous/直接删除")
    require(all(marker in runtime for marker in ["syncAllBundlesAsync", "pageRefreshIntervalMillis", "ensureBundleReady", "rollback("]), "HarmonyOS OTA Runtime 对齐启动全量、页面 30 分钟、repair 与 rollback")
    ota_models = shell_read("src/main/ets/ota/OtaModels.ets")
    require("platform: string = 'harmony'" in ota_models and "serverPlatform: string = ''" in ota_models,
            "HarmonyOS OTA 保留宿主平台，并支持可撤销的服务端 platform 兼容值")
    require("requestPlatform()" in ota_models and "config.requestPlatform()" in shell_read("src/main/ets/ota/OtaApiClient.ets") and
            "config.requestPlatform()" in transaction,
            "HarmonyOS OTA 请求、Manifest 与 Release 校验统一使用服务端 platform")


def structural_text(text: str) -> str:
    output: list[str] = []
    index = 0
    state = "code"
    quote = ""
    while index < len(text):
        current = text[index]
        following = text[index + 1] if index + 1 < len(text) else ""
        if state == "code":
            if current == "/" and following == "/":
                state = "line"
                index += 2
                continue
            if current == "/" and following == "*":
                state = "block"
                index += 2
                continue
            if current in {'"', "'", "`"}:
                state = "string"
                quote = current
                index += 1
                continue
            output.append(current)
            index += 1
            continue
        if state == "line":
            if current == "\n":
                output.append("\n")
                state = "code"
            index += 1
            continue
        if state == "block":
            if current == "*" and following == "/":
                state = "code"
                index += 2
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
    return "".join(output)


def delimiter_and_script_syntax() -> None:
    source_files = list(ROOT.rglob("*.ets")) + list(ROOT.rglob("*.ts"))
    problems: list[str] = []
    for path in source_files:
        stripped = structural_text(path.read_text(encoding="utf-8"))
        for opening, closing in (("{", "}"), ("(", ")"), ("[", "]")):
            if stripped.count(opening) != stripped.count(closing):
                problems.append(f"{path.relative_to(ROOT)}: {opening}{closing} 不平衡")
    require(not problems, "HarmonyOS ArkTS/TypeScript 基础分隔符检查通过" if not problems else "; ".join(problems))

    bash = shutil.which("bash")
    if bash:
        proc = subprocess.run([bash, "-n", str(ROOT / "scripts/sync_bundle.sh")], capture_output=True, text=True)
        require(proc.returncode == 0, "HarmonyOS Bundle 同步脚本 Bash 语法通过")
    else:
        warn("当前环境无 Bash，跳过同步脚本语法")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    checks = [
        expected_files,
        json_and_xml,
        versions_and_dependencies,
        xelement_full,
        runtime_and_container,
        route_and_security,
        bridge_contract,
        manifest_and_permissions,
        sparkling_boundary,
        comments_and_structure,
        delimiter_and_script_syntax,
    ]
    for check in checks:
        try:
            check()
        except Exception as exc:  # noqa: BLE001
            fail(f"检查器内部异常 {check.__name__}: {exc}")

    if not args.quiet:
        print("Lynx 4.0 HarmonyOS Shell 静态验收")
        print(f"工程目录: {ROOT}")
        print("说明: 本脚本只检查源码与配置；DevEco/Hvigor/HAP 构建结果需单独验收。\n")
        for message in PASS:
            print(f"[PASS] {message}")
        for message in WARN:
            print(f"[WARN] {message}")
        for message in FAIL:
            print(f"[FAIL] {message}")
        print(f"\n结果: {len(PASS)} PASS, {len(WARN)} WARN, {len(FAIL)} FAIL")
    else:
        print(json.dumps({"pass": len(PASS), "warn": len(WARN), "fail": len(FAIL), "failures": FAIL}, ensure_ascii=False))
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
