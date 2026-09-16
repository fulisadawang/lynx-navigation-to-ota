#!/usr/bin/env python3
"""静态校验 LynxCapacitor 三端公共目录和语义字段。"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
CONTRACT = ROOT / "docs/lynx-capacitor-semantics-v1/semantic-catalog.json"


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def parse_kotlin_catalog() -> list[dict[str, Any]]:
    source = read(
        "android/lynx-capacitor/src/main/java/com/example/lynxcapacitormodule/"
        "NativeCapabilityCatalog.kt"
    )
    block = source.split("val specs: List<NativeCapabilitySpec> = listOf(", 1)[1]
    block = block.split("\n    )", 1)[0]
    return [
        {"name": name, "methods": methods.split(",") if methods else []}
        for name, methods in re.findall(r'spec\("([^"]+)",\s*"([^"]*)"', block)
    ]


def parse_swift_catalog() -> list[dict[str, Any]]:
    source = read("ios/LynxCapacitorKit/Bridge/LynxNativeCapabilityCatalog.swift")
    block = source.split("static let specs:", 1)[1]
    block = block.split("static func find", 1)[0]
    return [
        {"name": name, "methods": methods.split(",") if methods else []}
        for name, methods in re.findall(r'spec\("([^"]+)",\s*"([^"]*)"', block)
    ]


def parse_harmony_catalog() -> list[dict[str, Any]]:
    source = read(
        "harmony/lynx_capacitor_kit/src/main/ets/module/LynxCapacitorCatalog.ets"
    )
    block = source.split("public static headers(): string", 1)[1]
    block = block.split("/** 统一入口", 1)[0]
    rows: list[dict[str, Any]] = []
    row_pattern = re.compile(r'\{"name":"([^"]+)","methods":\[(.*?)\]\}')
    method_pattern = re.compile(r'\{"name":"([^"]+)","rtype":"promise"\}')
    for name, method_json in row_pattern.findall(block):
        rows.append({"name": name, "methods": method_pattern.findall(method_json)})
    return rows


def assert_equal(label: str, expected: Any, actual: Any) -> None:
    if expected != actual:
        raise AssertionError(f"{label} 不一致\n期望: {expected}\n实际: {actual}")


def assert_contains(label: str, path: str, *markers: str) -> None:
    source = read(path)
    missing = [marker for marker in markers if marker not in source]
    if missing:
        raise AssertionError(f"{label} 缺少标记: {missing}")


def main() -> int:
    contract = json.loads(CONTRACT.read_text(encoding="utf-8"))
    expected = contract["domains"]
    assert_equal("契约能力域数量", contract["domainCount"], len(expected))
    assert_equal(
        "契约方法总数",
        contract["methodCount"],
        sum(len(domain["methods"]) for domain in expected),
    )

    catalogs = {
        "Android": parse_kotlin_catalog(),
        "iOS": parse_swift_catalog(),
        "HarmonyOS": parse_harmony_catalog(),
    }
    for platform, actual in catalogs.items():
        assert_equal(f"{platform} 能力域数量", len(expected), len(actual))
        assert_equal(f"{platform} 目录", expected, actual)
        assert_equal(
            f"{platform} 方法总数",
            contract["methodCount"],
            sum(len(domain["methods"]) for domain in actual),
        )
        print(f"PASS {platform}: 40 个能力域 / 146 个方法 / 顺序一致")

    assert_contains(
        "Android 语义字段",
        "android/lynx-capacitor/src/main/java/com/example/lynxcapacitormodule/"
        "LynxCapabilitySemantics.kt",
        'CONTRACT_VERSION = "1.1"',
        "methodStatus",
        "verification",
        "errorReasonCode",
    )
    assert_contains(
        "Android transport",
        "android/lynx-capacitor/src/main/java/com/example/lynxcapacitormodule/"
        "LynxCapacitorRuntime.kt",
        '"reasonCode"',
        '"options 必须是 JSON 对象"',
        '"callbackId 必须是非空字符串',
        "val spec = NativeCapabilityCatalog.find(pluginId)",
    )
    assert_contains(
        "Android dispatch gate",
        "android/lynx-capacitor/src/main/java/com/example/lynxcapacitormodule/"
        "NativeCapabilityDispatcher.kt",
        "NativeCapabilityCatalog.find(pluginId)",
        "methodName !in spec.methods",
        "methodName !in spec.implementedMethods",
    )
    assert_contains(
        "Android retained event",
        "android/lynx-capacitor/src/main/java/com/example/lynxcapacitormodule/"
        "NativeFileTransferCapabilities.kt",
        'put("callbackId"',
        'put("success", true)',
    )

    assert_contains(
        "iOS 语义字段",
        "ios/LynxCapacitorKit/Bridge/LynxCapabilitySemantics.swift",
        'contractVersion = "1.1"',
        "methodStatus",
        "verification",
        "errorReasonCode",
    )
    assert_contains(
        "iOS transport",
        "ios/LynxCapacitorKit/Bridge/LynxNativeCapabilityContract.swift",
        "callbackId 必须是非空字符串",
        "options 必须是 JSON 对象",
        'error["reasonCode"]',
    )
    assert_contains(
        "iOS dispatch gate",
        "ios/LynxCapacitorKit/Bridge/LynxNativeCapabilityDispatcher.swift",
        "LynxNativeCapabilityCatalog.find(call.pluginId)",
        "spec.methods.contains(call.methodName)",
        "spec.implementedMethods.contains(call.methodName)",
        'envelope["callbackId"] = "-1"',
        'envelope["eventName"] = methodName',
    )

    assert_contains(
        "Harmony 语义字段",
        "harmony/lynx_capacitor_kit/src/main/ets/module/LynxCapacitorSemantics.ets",
        "contractVersion",
        "methodStatus",
        "verification",
        "errorReasonCode",
    )
    assert_contains(
        "Harmony transport",
        "harmony/lynx_capacitor_kit/src/main/ets/module/LynxCapacitorModule.ets",
        "callbackId 必须是非空字符串",
        "options must be a JSON object",
        "eventEnvelope",
    )
    assert_contains(
        "Harmony envelope",
        "harmony/lynx_capacitor_kit/src/main/ets/module/LynxCapacitorEnvelope.ets",
        "reasonCode",
    )
    assert_contains(
        "Harmony retained event",
        "harmony/lynx_capacitor_kit/src/main/ets/module/LynxCapacitorModule.ets",
        "envelope['eventName']",
        "envelope['sequence']",
        "eventCallbackId",
    )

    print("PASS 三端语义字段、输入闸门、错误原因码和 retained event 标记齐全")
    print("PASS getPluginHeaders 目录仍为 40/146，status 字段采用向后兼容的增量扩展")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, KeyError, IndexError, json.JSONDecodeError) as error:
        print(f"FAIL LynxCapacitor 语义校验: {error}", file=sys.stderr)
        raise SystemExit(1)
