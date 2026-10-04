#!/usr/bin/env python3
"""只读核对自有 iOS 隐私资源和宿主配置，不执行构建或权限请求。"""

import argparse
import hashlib
import json
import plistlib
import re
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path


WORKFLOW = Path(".workflow/lynx-native-readiness-ios-android/results")
RESOURCE_SPECS = (
    ("Shell", "ios/LynxShellKit/Resources/PrivacyInfo.xcprivacy", "LynxShellKitPrivacy.bundle",
     ("ios/LynxShellKit.podspec", "ios/LynxShellKitE2ECore.podspec")),
    ("Cap", "ios/LynxCapacitorKit/Resources/PrivacyInfo.xcprivacy", "LynxCapacitorKitPrivacy.bundle",
     ("ios/LynxCapacitorKit.podspec",)),
)
USAGE_KEYS = (
    "NSCameraUsageDescription", "NSMicrophoneUsageDescription",
    "NSPhotoLibraryUsageDescription", "NSPhotoLibraryAddUsageDescription",
    "NSContactsUsageDescription", "NSCalendarsUsageDescription",
    "NSCalendarsFullAccessUsageDescription", "NSCalendarsWriteOnlyAccessUsageDescription",
    "NSLocationWhenInUseUsageDescription", "NSLocationAlwaysAndWhenInUseUsageDescription",
    "NSFaceIDUsageDescription",
)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def duplicate_xml_keys(path):
    data = path.read_bytes()
    if data.startswith(b"bplist"):
        return []
    root = ET.fromstring(data)
    duplicates = []
    for index, node in enumerate(root.iter("dict")):
        seen = set()
        for child in node:
            if child.tag != "key":
                continue
            key = child.text or ""
            if key in seen:
                duplicates.append({"dictionaryIndex": index, "key": key})
            seen.add(key)
    return duplicates


def read_plist(path):
    with path.open("rb") as handle:
        value = plistlib.load(handle)
    if not isinstance(value, dict):
        raise ValueError("plist 根必须为 dict")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--app", type=Path, help="明确指定本轮构建的 .app")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    app = (args.app or root / WORKFLOW / "ios-derived-data/Build/Products/Debug-iphonesimulator/LynxShellE2EHost.app").resolve()
    output = args.output or root / WORKFLOW / "ios-config-check.json"
    checks = []

    def record(identifier, status, observed, **evidence):
        checks.append({"id": identifier, "status": status, "observed": observed, **evidence})

    for owner, source_rel, bundle_name, podspecs in RESOURCE_SPECS:
        source = root / source_rel
        product = app / bundle_name / "PrivacyInfo.xcprivacy"
        try:
            source_value = read_plist(source)
            duplicates = duplicate_xml_keys(source)
            record(owner + "-source", "FAIL" if duplicates else "PASS",
                   "源隐私清单可解析；XML 重复键数=" + str(len(duplicates)),
                   source=source_rel, sha256=sha256(source), duplicateKeys=duplicates)
        except (OSError, ValueError, plistlib.InvalidFileException, ET.ParseError) as error:
            record(owner + "-source", "FAIL", "源隐私清单解析失败：" + type(error).__name__, source=source_rel)
            source_value = None
        for spec_rel in podspecs:
            try:
                spec_text = (root / spec_rel).read_text()
                bundled = bool(re.search(r"spec\.resource_bundles\s*=.*?['\"]" + re.escape(bundle_name[:-7]) + r"['\"]", spec_text))
                points_to_source = source_rel.removeprefix("ios/") in spec_text
                minimum = re.search(r"spec\.platform\s*=\s*:ios,\s*['\"]([^'\"]+)", spec_text)
                correct_minimum = minimum is not None and minimum.group(1) == "14.0"
                record(spec_rel, "PASS" if bundled and points_to_source and correct_minimum else "FAIL",
                       "resource_bundles 与源路径核对；声明最低 iOS=" + (minimum.group(1) if minimum else "缺失"),
                       resourceBundle=bundle_name, resourceDeclared=bundled and points_to_source,
                       sourceMinimumIOS=minimum.group(1) if minimum else None, sha256=sha256(root / spec_rel))
            except OSError as error:
                record(spec_rel, "FAIL", "Podspec 无法读取：" + type(error).__name__)
        if not product.exists():
            record(owner + "-product", "NOT RUN", "指定 App 未包含该隐私资源；不能据源配置推断产物正确", product=str(product))
            continue
        try:
            product_value = read_plist(product)
            matches = source_value is not None and product_value == source_value
            record(owner + "-product", "PASS" if matches else "FAIL",
                   "实际 App 中资源逐 dict 比较" + ("一致" if matches else "不一致"),
                   product=str(product), source=source_rel, productSha256=sha256(product),
                   sourceSha256=sha256(source) if source.exists() else None, dictEqual=matches)
        except (OSError, ValueError, plistlib.InvalidFileException) as error:
            record(owner + "-product", "FAIL", "产物隐私清单解析失败：" + type(error).__name__, product=str(product))

    for source_rel in ("ios/LynxShellSample/Supporting/Info.plist", "ios/LynxShellSample/Supporting/Info-Debug.plist"):
        try:
            source = root / source_rel
            value = read_plist(source)
            duplicates = duplicate_xml_keys(source)
            present = {key: isinstance(value.get(key), str) and bool(value[key].strip()) for key in USAGE_KEYS}
            record(source_rel, "PASS" if not duplicates and all(present.values()) else "FAIL",
                   "源 Info.plist 重复键与用途文案存在性核对；不输出文案内容",
                   sha256=sha256(source), duplicateKeys=duplicates, usageDescriptions=present)
        except (OSError, ValueError, plistlib.InvalidFileException, ET.ParseError) as error:
            record(source_rel, "FAIL", "源 Info.plist 解析失败：" + type(error).__name__)
    built_info = app / "Info.plist"
    if built_info.exists():
        try:
            value = read_plist(built_info)
            present = {key: isinstance(value.get(key), str) and bool(value[key].strip()) for key in USAGE_KEYS}
            record("Host-Info-product", "PASS" if all(present.values()) else "FAIL",
                   "实际测试宿主用途文案非空核对；该检查不代表权限已授予",
                   product=str(built_info), sha256=sha256(built_info), usageDescriptions=present,
                   productMinimumOS=value.get("MinimumOSVersion"), platform=value.get("DTPlatformName"),
                   sdk=value.get("DTSDKName"))
        except (OSError, ValueError, plistlib.InvalidFileException) as error:
            record("Host-Info-product", "FAIL", "宿主 Info.plist 解析失败：" + type(error).__name__)
    else:
        record("Host-Info-product", "NOT RUN", "指定 App 不存在，实际用途文案未核对", product=str(built_info))
    try:
        project = root / "ios/project.yml"
        minima = re.findall(r"(?:iOS|deploymentTarget):\s*['\"]([0-9.]+)", project.read_text())
        record("Project-minimum", "PASS" if minima and set(minima) == {"14.0"} else "FAIL",
               "project.yml 支持基线声明核对", sourceMinimumIOS=sorted(set(minima)), sha256=sha256(project))
    except OSError as error:
        record("Project-minimum", "FAIL", "project.yml 无法读取：" + type(error).__name__)
    status = "FAIL" if any(item["status"] == "FAIL" for item in checks) else "NOT RUN" if any(item["status"] == "NOT RUN" for item in checks) else "PASS"
    result = {
        "schemaVersion": 1, "generatedAt": datetime.now(timezone.utc).isoformat(),
        "status": status, "app": str(app), "checks": checks,
        "minimumRuntime": {"status": "BLOCKED", "sourceMinimumIOS": "14.0", "reason": "本机无 iOS 14 runtime／真机；配置和新系统构建不能替代最低系统运行验证"},
        "limits": ["本脚本不构建、不运行权限 API，不验证 App Store 审核或真实业务数据用途", "两份资源的字典相等不代表整个 App 的隐私声明已覆盖业务和第三方 SDK"],
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"status": status, "checks": len(checks), "output": str(output)}, ensure_ascii=False))
    return 1 if status == "FAIL" else 0


if __name__ == "__main__":
    sys.exit(main())
