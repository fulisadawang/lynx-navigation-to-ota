#!/usr/bin/env python3
"""检查实际发布产物，禁止本项目 Debug Tool 代码或源码进入生产包。"""

import argparse
import io
import plistlib
import re
import struct
import subprocess
import zipfile
from pathlib import Path


ANDROID_MARKERS = (
    b"com/example/lynxshell/debug/",
    b"com.example.lynxshell.debug.",
    b"LynxDebugBridge",
    b"LynxShellDebugApplication",
    b"LYNX_DEBUG_TOOL_BEGIN",
    b"LYNX_DEBUG_TOOL_END",
)
IOS_MARKERS = re.compile(
    rb"LynxShellDebugKit|LynxShellKit\.LynxDebug|lynx_debug_invoke"
    rb"|LynxDebug(?:Bridge|Sink|Store|Tool|Panel|Floating|Passthrough|ActionButton|Toast"
    rb"|ContainerSnapshot|MethodInvocation|Console|Streaming|HTTP|Http|Install)"
)
DEBUG_CLASSES = {
    b"Lcom/example/lynxshell/debug/LynxDebugTool;",
    b"Lcom/example/lynxshell/debug/LynxDebugBridge;",
    b"Lcom/example/lynxshell/debug/DebugEventStore;",
    b"Lcom/example/lynxshell/sample/LynxShellDebugApplication;",
}


def dex_class_definitions(data):
    """读取 DEX 的 class_defs/type_ids/string_ids，区分类定义和单纯引用。"""
    if not data.startswith(b"dex\n") or struct.unpack_from("<I", data, 40)[0] != 0x12345678:
        raise ValueError("不支持的 DEX 格式，不能跳过 Debug 对照检查")
    string_offset = struct.unpack_from("<I", data, 60)[0]
    type_offset = struct.unpack_from("<I", data, 68)[0]
    class_count, class_offset = struct.unpack_from("<II", data, 96)
    definitions = set()
    for index in range(class_count):
        type_index = struct.unpack_from("<I", data, class_offset + index * 32)[0]
        string_index = struct.unpack_from("<I", data, type_offset + type_index * 4)[0]
        offset = struct.unpack_from("<I", data, string_offset + string_index * 4)[0]
        while data[offset] & 0x80:
            offset += 1
        offset += 1
        definitions.add(data[offset:data.index(b"\0", offset)])
    return definitions


def inspect_archive(data, label):
    hits = []
    source_count = 0
    code_count = 0
    definitions = set()
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        for entry in archive.infolist():
            if entry.is_dir():
                continue
            name = entry.filename
            content = archive.read(entry)
            if name.endswith((".jar", ".zip")) and zipfile.is_zipfile(io.BytesIO(content)):
                nested_hits, sources, code, nested_definitions = inspect_archive(content, f"{label}!{name}")
                hits.extend(nested_hits)
                source_count += sources
                code_count += code
                definitions.update(nested_definitions)
            else:
                source_count += int(name.endswith((".kt", ".java")))
                code_count += int(name.endswith((".class", ".dex")))
                if name.endswith(".dex"):
                    definitions.update(dex_class_definitions(content))
                if any(marker in content or marker in name.encode() for marker in ANDROID_MARKERS):
                    hits.append(f"{label}!{name}")
    return hits, source_count, code_count, definitions


def check_android(path, expect_debug=False):
    hits, sources, code, definitions = inspect_archive(path.read_bytes(), path.name)
    if path.name.endswith("-sources.jar"):
        if not sources:
            raise ValueError(f"{path.name}: 源码包为空，不能作为隔离通过证据")
    elif not code:
        raise ValueError(f"{path.name}: 未发现 class/dex，无法验证代码隔离")
    if expect_debug:
        missing = DEBUG_CLASSES - definitions
        if missing:
            raise ValueError(f"{path.name}: Debug 对照包缺少类定义 {sorted(item.decode() for item in missing)}")
    elif hits:
        raise ValueError("发现 Debug Tool 内容：\n" + "\n".join(hits[:12]))
    positive = f", required_debug_definitions={len(DEBUG_CLASSES)}" if expect_debug else ""
    print(f"PASS {path.name}: sources={sources}, code={code}, debug_matches={len(hits)}{positive}")


def check_ios(app, expect_debug=False):
    with (app / "Info.plist").open("rb") as stream:
        executable = app / plistlib.load(stream)["CFBundleExecutable"]
    # Xcode 的 Debug App 会把主体代码放在 .debug.dylib，不能只检查启动壳。
    binaries = [executable, *app.rglob("*.dylib")]
    binaries.extend(item / item.stem for item in app.rglob("*.framework") if (item / item.stem).is_file())
    has_debug = False
    for binary in binaries:
        symbols = subprocess.run(
            ["xcrun", "nm", "-j", str(binary)], check=True, capture_output=True, timeout=30
        ).stdout
        # Swift 名称压缩可能缩写 Lynx 前缀，但自有类型的 Debug 后缀仍存在。
        swift_debug = any(
            b"LynxShellKit" in symbol
            and any(name in symbol for name in (
                b"DebugBridge", b"DebugSink", b"DebugContainerSnapshot",
                b"DebugMethodInvocation", b"DebugConsole",
            ))
            for symbol in symbols.splitlines()
        )
        has_debug |= swift_debug or bool(IOS_MARKERS.search(binary.read_bytes() + symbols))
    has_debug_resource = any("LynxShellDebugKit" in item.name for item in app.rglob("*"))
    if expect_debug:
        if not has_debug:
            raise ValueError("iOS Debug 对照产物中缺少真实调试代码")
    elif has_debug or has_debug_resource:
        raise ValueError("iOS Release 产物仍包含本项目 Debug Tool 的符号、代码或资源")
    print(f"PASS {app.parent.name}/{app.name}: debug_symbols={has_debug}, debug_resources={has_debug_resource}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--android", type=Path, nargs="+", default=[])
    parser.add_argument("--ios-app", type=Path)
    parser.add_argument("--ios-inputs", type=Path)
    parser.add_argument("--debug-apk", type=Path)
    parser.add_argument("--debug-ios-app", type=Path)
    args = parser.parse_args()
    if not any((args.android, args.ios_app, args.ios_inputs, args.debug_apk, args.debug_ios_app)):
        parser.error("必须提供实际产物或 iOS 编译输入清单")
    for archive in args.android:
        check_android(archive)
    if args.ios_app:
        check_ios(args.ios_app)
    if args.ios_inputs:
        inputs = args.ios_inputs.read_text().splitlines()
        if not inputs or any("LynxDebug" in item or "LynxShellDebugKit" in item for item in inputs):
            raise ValueError("iOS Release 编译输入为空或仍包含调试源码")
        print(f"PASS iOS Release 编译输入: {len(inputs)} 个文件，无 Debug Tool 源码")
    if args.debug_apk:
        check_android(args.debug_apk, expect_debug=True)
    if args.debug_ios_app:
        check_ios(args.debug_ios_app, expect_debug=True)


if __name__ == "__main__":
    main()
