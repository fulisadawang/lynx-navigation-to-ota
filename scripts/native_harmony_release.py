#!/usr/bin/env python3
"""暂存/收集Harmony HAR，以及从固定GitHub Release安装已校验资产。"""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import zipfile


DEFAULT_REPOSITORY = "fulisadawang/lynx-navigation-to-ota"
TAG_PREFIX = "native-v"
MODULES = {
    "lynx_shell_kit": "@lynx/lynx-shell-kit",
    "lynx_capacitor_kit": "@lynx/lynx-capacitor-kit",
    "lynx_gfx": "@lynx/gfx",
}
STAGE_RECORD = ".native-harmony-release-stage.json"
SEMVER = re.compile(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?\Z")
EXCLUDED_PARTS = {"oh_modules", ".ohpm", ".hvigor", "build", ".git", "ohosTest", "test", "tests"}
CREDENTIAL_SUFFIXES = {".p12", ".pfx", ".pem", ".key", ".jks", ".keystore", ".cer", ".crt", ".p7b", ".mobileprovision", ".provisionprofile"}


class ReleaseError(Exception):
    pass


def read_object(path):
    try:
        if path.stat().st_size > 1024 * 1024:
            raise ReleaseError(f"配置超过读取预算：{path.name}")
        result = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ReleaseError(f"无法读取严格JSON配置：{path.name}") from error
    if not isinstance(result, dict):
        raise ReleaseError(f"配置根必须是对象：{path.name}")
    return result


def write_object(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def config(path):
    value = read_object(path)
    if value.get("schemaVersion") != 1 or value.get("tagPrefix") != TAG_PREFIX:
        raise ReleaseError("发行描述的schemaVersion/tagPrefix不符合客户端协议")
    for field in ("version", "lynxVersion", "primjsVersion"):
        if not isinstance(value.get(field), str) or not SEMVER.fullmatch(value[field]):
            raise ReleaseError(f"发行描述的{field}必须为有效版本")
    if not isinstance(value.get("repository"), str) or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", value["repository"]):
        raise ReleaseError("repository必须为owner/repo")
    harmony = value.get("harmony")
    if not isinstance(harmony, dict) or not isinstance(harmony.get("assets"), dict) or set(harmony["assets"]) != set(MODULES):
        raise ReleaseError("发行描述缺少Shell/Cap/Gfx资产映射")
    if type(harmony.get("sdkApi")) is not int or harmony["sdkApi"] < 13:
        raise ReleaseError("sdkApi必须为明确的目标SDK整数")
    if not isinstance(harmony.get("gfxVersion"), str) or not SEMVER.fullmatch(harmony["gfxVersion"]):
        raise ReleaseError("gfxVersion必须为有效版本")
    if harmony["gfxVersion"] != value["lynxVersion"]:
        raise ReleaseError("Gfx ABI版本必须与冻结Lynx版本一致")
    frozen = harmony.get("gfxSha256")
    if not isinstance(frozen, dict) or set(frozen) != {"arm64-v8a", "x86_64"}:
        raise ReleaseError("发行描述必须冻结两种Gfx ABI的SHA256")
    if any(not isinstance(sha, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", sha) for sha in frozen.values()):
        raise ReleaseError("Gfx冻结SHA256格式不合法")
    for name in harmony["assets"].values():
        if not isinstance(name, str) or not re.fullmatch(r"[a-z0-9-]+", name):
            raise ReleaseError("HAR资产前缀不合法")
    return value


def asset_name(value, module):
    version = value["harmony"]["gfxVersion"] if module == "lynx_gfx" else value["version"]
    return f'{value["harmony"]["assets"][module]}-{version}.har'


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(64 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def copy_source(source, target):
    # 只遍历显式HAR输入，不复制安装产物、测试、签名或用户凭据。
    if not source.exists():
        raise ReleaseError(f"缺少HAR源码输入：{source.name}")
    paths = [source] if source.is_file() else [source, *source.rglob("*")]
    for path in paths:
        relative = Path() if path == source else path.relative_to(source)
        if any(part in EXCLUDED_PARTS for part in relative.parts):
            continue
        if path.is_symlink():
            raise ReleaseError(f"发布输入不接受符号链接：{relative}")
        if path.suffix.lower() in CREDENTIAL_SUFFIXES or path.name == ".env" or path.name.startswith(".env."):
            raise ReleaseError(f"发布输入含凭据文件：{relative.name}")
        destination = target if path == source else target / relative
        if path.is_dir():
            destination.mkdir(parents=True, exist_ok=True)
        elif path.is_file():
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, destination)


def prepare(args):
    repo = Path(args.repo_root).resolve()
    value = config(repo / "native-release.json")
    for abi, expected in value["harmony"]["gfxSha256"].items():
        source = repo / "harmony" / "lynx_gfx" / "libs" / abi / "liblynxgfx.so"
        if source.is_symlink() or not source.is_file() or digest(source) != expected.lower():
            raise ReleaseError(f"Gfx源码{abi}二进制与冻结SHA256不一致")
    output = Path(args.output).resolve()
    if output == repo or repo in output.parents:
        raise ReleaseError("stage必须放在源码仓之外的临时目录")
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        raise ReleaseError("stage已存在且非空；拒绝覆盖")
    output.mkdir(parents=True, exist_ok=True)
    for module in MODULES:
        source = repo / "harmony" / module
        target = output / module
        for filename in ("oh-package.json5", "build-profile.json5", "hvigorfile.ts"):
            copy_source(source / filename, target / filename)
        copy_source(source / "src" / "main", target / "src" / "main")
        if module == "lynx_gfx":
            copy_source(source / "Index.ets", target / "Index.ets")
            copy_source(source / "libs", target / "libs")
        metadata = read_object(target / "oh-package.json5")
        if metadata.get("name") != MODULES[module]:
            raise ReleaseError(f"{module}源码包名与发行协议不一致")
        if module == "lynx_gfx" and metadata.get("version") != value["harmony"]["gfxVersion"]:
            raise ReleaseError("不能用新metadata版本重标未更新的Gfx原生ABI")
        metadata["version"] = value["harmony"]["gfxVersion"] if module == "lynx_gfx" else value["version"]
        for key, dependency in metadata.get("dependencies", {}).items():
            if key == "@lynx/gfx":
                if dependency != value["harmony"]["gfxVersion"]:
                    raise ReleaseError("Shell源码Gfx依赖与冻结ABI不一致")
                metadata["dependencies"][key] = value["harmony"]["gfxVersion"]
            elif key.startswith("@lynx/"):
                if dependency != value["lynxVersion"]:
                    raise ReleaseError(f"不能隐式升级源码SDK依赖：{key}")
                metadata["dependencies"][key] = value["lynxVersion"]
            elif isinstance(dependency, str) and "@param:" in dependency:
                raise ReleaseError(f"未解析的依赖参数：{key}")
        metadata["devDependencies"] = {}
        write_object(target / "oh-package.json5", metadata)

    parameters = read_object(repo / "harmony" / "parameter.json")
    if parameters.get("dependencies", {}).get("primjs_version") != value["primjsVersion"]:
        raise ReleaseError("PrimJS源码参数与冻结发行SDK不一致")

    source_profile = read_object(repo / "harmony" / "build-profile.json5")
    product = next((item for item in source_profile["app"]["products"] if item["name"] == "default"), None)
    if product is None or not str(product.get("targetSdkVersion", "")).endswith(f'({value["harmony"]["sdkApi"]})'):
        raise ReleaseError("源码default产品的目标SDK与发行描述不一致")
    profile = {
        "app": {
            "products": [{key: product[key] for key in ("name", "compatibleSdkVersion", "targetSdkVersion", "runtimeOS")}],
            "buildModeSet": [{"name": "debug"}, {"name": "release"}],
            "signingConfigs": [],
        },
        "modules": [{"name": name, "srcPath": f"./{name}", "targets": [{"name": "default", "applyToProducts": ["default"]}]} for name in MODULES],
    }
    write_object(output / "build-profile.json5", profile)
    write_object(output / "oh-package.json5", {
        "name": "lynx-native-har-release-stage", "version": value["version"], "modelVersion": "5.0.0",
        "dependencies": {"@lynx/primjs": value["primjsVersion"]},
        "overrides": {"@lynx/gfx": "file:./lynx_gfx"}, "devDependencies": {},
    })
    copy_source(repo / "harmony" / "hvigorfile.ts", output / "hvigorfile.ts")
    copy_source(repo / "harmony" / "hvigor" / "hvigor-config.json5", output / "hvigor" / "hvigor-config.json5")
    # appTasks仍需要公共AppScope配置，但stage不包含Demo Ability、应用签名或用户配置。
    write_object(output / "AppScope" / "app.json5", {"app": {
        "bundleName": "io.github.fulisadawang.lynx.har.release", "vendor": "LynxShell",
        "versionCode": 1, "versionName": value["version"], "icon": "$media:stage_icon", "label": "$string:stage_name",
    }})
    write_object(output / "AppScope" / "resources" / "base" / "element" / "string.json", {"string": [{"name": "stage_name", "value": "Native HAR Release"}]})
    icon = output / "AppScope" / "resources" / "base" / "media" / "stage_icon.svg"
    icon.parent.mkdir(parents=True, exist_ok=True)
    icon.write_text('<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><rect width="32" height="32" fill="#2563eb"/></svg>\n', encoding="utf-8")
    write_object(output / STAGE_RECORD, value)
    return {"stage": str(output), "modules": list(MODULES), "version": value["version"], "sdkApi": value["harmony"]["sdkApi"]}


class HarContents:
    def __init__(self, path):
        self.archive = zipfile.ZipFile(path) if zipfile.is_zipfile(path) else tarfile.open(path, "r:*")
        self.entries = {}
        entries = self.archive.infolist() if isinstance(self.archive, zipfile.ZipFile) else self.archive.getmembers()
        for entry in entries:
            name = entry.filename if isinstance(self.archive, zipfile.ZipFile) else entry.name
            parts = PurePosixPath(name)
            if "\\" in name or re.match(r"^[A-Za-z]:", name) or parts.is_absolute() or ".." in parts.parts:
                self.close()
                raise ReleaseError("HAR包含不安全的归档路径")
            if isinstance(self.archive, zipfile.ZipFile):
                link = stat.S_ISLNK(entry.external_attr >> 16)
                regular = not entry.is_dir()
                mode = stat.S_IFMT(entry.external_attr >> 16)
                if mode in (stat.S_IFCHR, stat.S_IFBLK, stat.S_IFIFO, stat.S_IFSOCK):
                    self.close()
                    raise ReleaseError("HAR不能含设备或其它特殊文件")
            else:
                link = entry.issym() or entry.islnk()
                regular = entry.isfile()
                if not regular and not entry.isdir() and not link:
                    self.close()
                    raise ReleaseError("HAR不能含设备或其它特殊文件")
            if link:
                self.close()
                raise ReleaseError("HAR不能含符号或硬链接")
            normalized = str(parts)
            if regular:
                if normalized in self.entries:
                    self.close()
                    raise ReleaseError("HAR存在重复文件路径")
                self.entries[normalized] = entry

    def close(self):
        self.archive.close()

    def read_prefix(self, name, size):
        entry = self.entries[name]
        stream = self.archive.open(entry) if isinstance(self.archive, zipfile.ZipFile) else self.archive.extractfile(entry)
        with stream:
            return stream.read(size)

    def sha256(self, name):
        entry = self.entries[name]
        stream = self.archive.open(entry) if isinstance(self.archive, zipfile.ZipFile) else self.archive.extractfile(entry)
        result = hashlib.sha256()
        with stream:
            for chunk in iter(lambda: stream.read(64 * 1024), b""):
                result.update(chunk)
        return result.hexdigest()

    def metadata(self):
        candidates = [name for name in self.entries if PurePosixPath(name).name == "oh-package.json5"]
        if not candidates:
            raise ReleaseError("HAR缺少oh-package.json5")
        depth = min(len(PurePosixPath(name).parts) for name in candidates)
        candidates = [name for name in candidates if len(PurePosixPath(name).parts) == depth]
        if len(candidates) != 1:
            raise ReleaseError("HAR顶层metadata不唯一")
        name = candidates[0]
        entry = self.entries[name]
        size = entry.file_size if isinstance(self.archive, zipfile.ZipFile) else entry.size
        if size <= 0 or size > 1024 * 1024:
            raise ReleaseError("HAR metadata大小不合法")
        stream = self.archive.open(entry) if isinstance(self.archive, zipfile.ZipFile) else self.archive.extractfile(entry)
        with stream:
            data = json.loads(stream.read().decode("utf-8"))
        if not isinstance(data, dict):
            raise ReleaseError("HAR metadata必须为对象")
        return name, data


def validate_har(path, module, value):
    contents = HarContents(path)
    try:
        metadata_path, metadata = contents.metadata()
        expected_version = value["harmony"]["gfxVersion"] if module == "lynx_gfx" else value["version"]
        if metadata.get("name") != MODULES[module] or metadata.get("version") != expected_version:
            raise ReleaseError(f"{module} HAR name/version与发行描述不一致")
        if module == "lynx_shell_kit" and metadata.get("dependencies", {}).get("@lynx/gfx") != value["harmony"]["gfxVersion"]:
            raise ReleaseError("Shell HAR缺少固定Gfx ABI依赖")
        if "@param:" in json.dumps(metadata):
            raise ReleaseError(f"{module} HAR仍含未解析参数")
        package_root = PurePosixPath(metadata_path).parent
        for field in ("dependencies", "devDependencies", "dynamicDependencies"):
            dependencies = metadata.get(field, {})
            if not isinstance(dependencies, dict):
                raise ReleaseError(f"{module} {field}必须为对象")
            for key, dependency in dependencies.items():
                if not isinstance(dependency, str):
                    raise ReleaseError(f"{module}依赖必须为固定字符串")
                if dependency.startswith("file:"):
                    relative = PurePosixPath(dependency[5:])
                    if relative.is_absolute() or re.match(r"^[A-Za-z]:", dependency[5:]) or ".." in relative.parts or "\\" in dependency:
                        raise ReleaseError(f"{module}依赖逃逸HAR目录：{key}")
                    target = str(package_root / relative)
                    if not any(name == target or name.startswith(target + "/") for name in contents.entries):
                        raise ReleaseError(f"{module}内部file依赖未进入HAR：{key}")
                if key == "@lynx/gfx" and dependency != value["harmony"]["gfxVersion"]:
                    raise ReleaseError("Shell Gfx依赖必须为发行ABI固定版本")
                if key.startswith("@lynx/") and key != "@lynx/gfx" and dependency != value["lynxVersion"]:
                    raise ReleaseError(f"{module} Lynx依赖未固定SDK版本：{key}")
        if module == "lynx_gfx":
            for abi in ("arm64-v8a", "x86_64"):
                suffix = f"libs/{abi}/liblynxgfx.so"
                matches = [name for name in contents.entries if name == suffix or name.endswith("/" + suffix)]
                if len(matches) != 1:
                    raise ReleaseError(f"Gfx HAR必须包含唯一{abi}原生库")
                entry = contents.entries[matches[0]]
                size = entry.file_size if isinstance(contents.archive, zipfile.ZipFile) else entry.size
                if size <= 0:
                    raise ReleaseError(f"Gfx {abi}原生库为空")
                header = contents.read_prefix(matches[0], 20)
                if len(header) != 20 or header[:4] != b"\x7fELF" or header[4] != 2 or header[5] != 1:
                    raise ReleaseError(f"Gfx {abi}不是预期ELF64原生库")
                machine = struct.unpack("<H", header[18:20])[0]
                if machine != (183 if abi == "arm64-v8a" else 62):
                    raise ReleaseError(f"Gfx {abi}目录与真实ELF架构不一致")
                if contents.sha256(matches[0]) != value["harmony"]["gfxSha256"][abi].lower():
                    raise ReleaseError(f"Gfx HAR的{abi}二进制与冻结SHA256不一致")
    finally:
        contents.close()


def publish_exclusive(source, target, expected):
    if target.is_symlink():
        raise ReleaseError(f"拒绝覆盖符号链接：{target.name}")
    if target.exists():
        if not target.is_file() or digest(target) != expected:
            raise ReleaseError(f"已存在不同内容，拒绝覆盖：{target.name}")
        return False
    descriptor, temporary = tempfile.mkstemp(prefix=".native-release-", dir=target.parent)
    try:
        with os.fdopen(descriptor, "wb") as output, source.open("rb") as incoming:
            shutil.copyfileobj(incoming, output, 64 * 1024)
            output.flush()
            os.fsync(output.fileno())
        if digest(Path(temporary)) != expected:
            raise ReleaseError("发布前文件摘要变化")
        try:
            os.link(temporary, target)
        except FileExistsError:
            if target.is_symlink() or not target.is_file() or digest(target) != expected:
                raise ReleaseError(f"并发创建了不同文件：{target.name}")
            return False
        return True
    finally:
        Path(temporary).unlink(missing_ok=True)


def collect(args):
    stage = Path(args.stage).resolve()
    value = config(stage / STAGE_RECORD)
    output = Path(args.output).resolve()
    found = {}
    for module in MODULES:
        candidates = sorted((stage / module / "build").glob("**/outputs/**/*.har"))
        if len(candidates) != 1:
            raise ReleaseError(f"{module}必须有唯一实际构建HAR，当前{len(candidates)}个")
        validate_har(candidates[0], module, value)
        found[module] = candidates[0]
    output.mkdir(parents=True, exist_ok=True)
    assets = []
    for module, source in found.items():
        target = output / asset_name(value, module)
        sha = digest(source)
        publish_exclusive(source, target, sha)
        assets.append({"name": target.name, "path": str(target), "sha256": sha})
    return {"version": value["version"], "assets": assets}


def gh_download(repository, tag, filename, directory):
    command = ["gh", "release", "download", tag, "--repo", f"https://github.com/{repository}", "--pattern", filename, "--dir", str(directory)]
    try:
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    except FileNotFoundError as error:
        raise ReleaseError("请先安装gh并使用现有账号认证") from error
    if result.returncode != 0:
        # gh错误可能包含签名下载URL，不把原始stderr写到日志。
        raise ReleaseError(f"gh下载{filename}失败（退出码{result.returncode}），请本地核对认证和固定tag")


def checksums(path):
    if path.stat().st_size > 1024 * 1024:
        raise ReleaseError("SHA256SUMS超过读取预算")
    entries = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        match = re.fullmatch(r"([0-9a-fA-F]{64})[ \t]+\*?([A-Za-z0-9_.+-]+)", line)
        if match is None or match[2] in entries:
            raise ReleaseError("SHA256SUMS存在非法路径或重复条目")
        entries[match[2]] = match[1].lower()
    return entries


def install(args):
    if not SEMVER.fullmatch(args.version) or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
        raise ReleaseError("version/repository格式不合法")
    tag = TAG_PREFIX + args.version
    destination = Path(args.destination).resolve()
    config_root = Path(args.config_root).resolve()
    with tempfile.TemporaryDirectory(prefix="native-har-download-") as temporary:
        directory = Path(temporary)
        for filename in ("SHA256SUMS", "native-release.json"):
            gh_download(args.repository, tag, filename, directory)
        sums = checksums(directory / "SHA256SUMS")
        if sums.get("native-release.json") != digest(directory / "native-release.json"):
            raise ReleaseError("发行描述SHA256不匹配")
        value = config(directory / "native-release.json")
        if value["version"] != args.version or value["repository"] != args.repository:
            raise ReleaseError("发行描述与所选固定tag/repository不一致")
        assets = {}
        for module in MODULES:
            filename = asset_name(value, module)
            if filename not in sums:
                raise ReleaseError(f"SHA256SUMS缺少{filename}")
            gh_download(args.repository, tag, filename, directory)
            source = directory / filename
            if digest(source) != sums[filename]:
                raise ReleaseError(f"HAR SHA256不匹配：{filename}")
            validate_har(source, module, value)
            assets[module] = source
        destination.mkdir(parents=True, exist_ok=True)
        # 先核对全部既存文件，避免用户已有不同版本被部分覆盖。
        for source in assets.values():
            target = destination / source.name
            if target.is_symlink() or target.exists() and (not target.is_file() or digest(target) != sums[source.name]):
                raise ReleaseError(f"已存在不同文件，拒绝覆盖：{target.name}")
        for source in assets.values():
            publish_exclusive(source, destination / source.name, sums[source.name])
    paths = {}
    for module, source in assets.items():
        relative = Path(os.path.relpath(destination / source.name, config_root)).as_posix()
        paths[module] = "file:" + (relative if relative.startswith(".") else "./" + relative)
    return {
        "tag": tag, "destination": str(destination),
        "dependencies": {MODULES[module]: paths[module] for module in ("lynx_shell_kit", "lynx_capacitor_kit")},
        "overrides": {"@lynx/gfx": paths["lynx_gfx"]},
        "note": "路径相对config-root；只给出配置片段，未改oh-package.json5或运行ohpm/编译。",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    stage = subcommands.add_parser("prepare")
    stage.add_argument("--repo-root", default=str(Path(__file__).resolve().parents[1]))
    stage.add_argument("--output", required=True)
    stage.set_defaults(action=prepare)
    receipt = subcommands.add_parser("collect")
    receipt.add_argument("--stage", required=True)
    receipt.add_argument("--output", required=True)
    receipt.set_defaults(action=collect)
    consumer = subcommands.add_parser("install")
    consumer.add_argument("--version", required=True)
    consumer.add_argument("--destination", required=True)
    consumer.add_argument("--repository", default=DEFAULT_REPOSITORY)
    consumer.add_argument("--config-root", default=".")
    consumer.set_defaults(action=install)
    args = parser.parse_args()
    try:
        result = args.action(args)
        print(json.dumps(result, ensure_ascii=False, indent=2))
    except (ReleaseError, OSError, ValueError, zipfile.BadZipFile, tarfile.TarError) as error:
        print(f"native-harmony-release: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
