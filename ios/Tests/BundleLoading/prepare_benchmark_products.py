#!/usr/bin/env python3
"""向独立基准产物注入指定夹具，启动前校验实际字节，兼容 xctestrun 两种格式。"""

import argparse
import hashlib
import json
import plistlib
import shutil
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--build-dir", type=Path, required=True)
    parser.add_argument("--fixture-dir", type=Path, required=True)
    parser.add_argument("--label", choices=["baseline", "optimized"], required=True)
    parser.add_argument("--evidence-dir", type=Path, required=True)
    args = parser.parse_args()
    products = args.build_dir / "Build/Products"
    app = products / "Debug-iphonesimulator/LynxShellE2EHost.app"
    info_path = app / "Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    if info.get("CFBundleIdentifier") != "com.codex.lynx.bundleloading":
        raise ValueError("仅允许配置独立的 com.codex.lynx.bundleloading 测试产物")
    resources = plistlib.loads((app / "LynxResources.bundle/Info.plist").read_bytes())
    if resources.get("CFBundleIdentifier") != "org.cocoapods.LynxResources" or resources.get("CFBundleShortVersionString") != "4.1.0":
        raise ValueError("真实 LynxResources metadata 必须保持可信 ID 和 4.1.0 版本")
    metadata = json.loads((args.fixture_dir / "fixture-metadata.json").read_text())
    destination = app / "BundleLoadingFixtures"
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(args.fixture_dir, destination)
    verified = []
    for record in metadata["cases"]:
        for target in [record] + record["asyncResources"]:
            path = target["path"]
            file = destination / path
            if not file.resolve().is_relative_to(destination.resolve()):
                raise ValueError("夹具路径超出目标目录")
            data = file.read_bytes()
            digest = hashlib.sha256(data).hexdigest()
            if len(data) != target["size"] or digest != target["sha256"]:
                raise ValueError("构建产物中夹具的 size/SHA 不匹配：" + path)
            verified.append({"path": path, "size": len(data), "sha256": digest})
    info.update({"CFBundleDisplayName": "Bundle 加载基准", "BundleLoadingRunLabel": args.label,
                 "BundleLoadingExpectDetachedTab": args.label == "optimized"})
    info_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
    files = list(products.glob("*.xctestrun"))
    if len(files) != 1:
        raise ValueError("测试产物应恰有一个 xctestrun")
    run_file = files[0]
    configuration = plistlib.loads(run_file.read_bytes())
    if "TestConfigurations" in configuration:
        targets = [target for group in configuration["TestConfigurations"] for target in group["TestTargets"]]
    else:
        targets = [value for key, value in configuration.items() if not key.startswith("__") and isinstance(value, dict)]
    for target in targets:
        target["CommandLineArguments"] = ["--show-native-launcher"]
        target.setdefault("EnvironmentVariables", {})["LYNX_TEST_SKIP_STARTUP_SYNC"] = "1"
    run_file.write_bytes(plistlib.dumps(configuration, fmt=plistlib.FMT_XML))
    args.evidence_dir.mkdir(parents=True, exist_ok=True)
    evidence = {"label": args.label, "appID": info["CFBundleIdentifier"], "verifiedInputs": verified}
    (args.evidence_dir / ("ios-" + args.label + "-actual-inputs.json")).write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps(evidence, ensure_ascii=False))


if __name__ == "__main__":
    main()
