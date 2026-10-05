#!/usr/bin/env python3
"""整合本次 CI 的固定资产，并显式发布 Draft、Specs 和最终 Release。"""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import urllib.parse
import zipfile

from native_release import ROOT, config, digest, write_json


def gh(*args):
    return subprocess.check_output(["gh", *args], cwd=ROOT, text=True).strip()


def command(*args, cwd=None, env=None):
    return subprocess.check_output(args, cwd=cwd or ROOT, env=env, text=True).strip()


def identity():
    data = config()
    sha = command("git", "rev-parse", "HEAD")
    if sha != os.environ["NATIVE_SOURCE_SHA"]:
        raise ValueError("发布 checkout 与已构建 sourceSHA 不一致")
    return data, sha, data["tagPrefix"] + data["version"]


def expected_assets(data):
    version = data["version"]
    return {"android": {f"lynx-android-maven-{version}.zip"},
            "ios": {f"lynx-ios-specs-{version}.zip"},
            "harmony": {f"lynx-shell-kit-{version}.har", f"lynx-capacitor-kit-{version}.har",
                        f"lynx-gfx-{data['harmony']['gfxVersion']}.har"}}


def assemble(inputs, output):
    data, sha, tag = identity()
    if output.exists() and any(output.iterdir()):
        raise ValueError("整合输出目录必须为空")
    output.mkdir(parents=True, exist_ok=True)
    receipts = []
    for platform, names in expected_assets(data).items():
        directory = inputs / platform
        receipt = json.loads((directory / "platform.json").read_text())
        if receipt["platform"] != platform or receipt["version"] != data["version"] or receipt["sourceSHA"] != sha:
            raise ValueError(f"{platform} 资产来源或版本不一致")
        if receipt["runId"] != os.environ["GITHUB_RUN_ID"] or receipt["runAttempt"] != os.environ["NATIVE_BUILD_ATTEMPT"]:
            raise ValueError(f"{platform} 资产不属于已批准的构建 run/attempt")
        if {entry["name"] for entry in receipt["files"]} != names:
            raise ValueError(f"{platform} 资产清单不一致")
        if {path.name for path in directory.iterdir()} != names | {"platform.json"}:
            raise ValueError(f"{platform} 含清单外文件")
        for entry in receipt["files"]:
            name = entry["name"]
            if Path(name).name != name or "\\" in name or ".." in name:
                raise ValueError("资产文件名不能包含路径")
            path = directory / name
            if path.is_symlink() or path.stat().st_size != entry["size"] or digest(path) != entry["sha256"]:
                raise ValueError(f"{name} 内容与构建回执不一致")
            shutil.copyfile(path, output / name)
        receipts.append(receipt)
    descriptor = dict(data, sourceSHA=sha, tag=tag, platformReceipts=receipts)
    write_json(output / "native-release.json", descriptor)
    shutil.copyfile(ROOT / "scripts/native_harmony_release.py", output / "native_harmony_release.py")
    lines = [f"{digest(path)}  {path.name}" for path in sorted(output.iterdir()) if path.is_file()]
    (output / "SHA256SUMS").write_text("\n".join(lines) + "\n")


def verify_release(output):
    data, sha, tag = identity()
    descriptor = json.loads((output / "native-release.json").read_text())
    if descriptor["sourceSHA"] != sha or descriptor["tag"] != tag or descriptor["version"] != data["version"]:
        raise ValueError("发布描述与 sourceSHA/版本/tag 不一致")
    expected = set().union(*expected_assets(data).values()) | {"native-release.json", "native_harmony_release.py"}
    actual = {}
    for line in (output / "SHA256SUMS").read_text().splitlines():
        checksum, name = line.split("  ", 1)
        if name in actual or name not in expected or len(checksum) != 64:
            raise ValueError("SHA256SUMS 含重复或清单外文件")
        actual[name] = checksum
    if set(actual) != expected or {path.name for path in output.iterdir()} != expected | {"SHA256SUMS"}:
        raise ValueError("发布资产缺失或超出清单")
    for name, checksum in actual.items():
        path = output / name
        if path.is_symlink() or digest(path) != checksum:
            raise ValueError(f"发布资产校验失败：{name}")
    return data, sha, tag


def release_info(data, tag):
    result = subprocess.run(["gh", "api", f"repos/{data['repository']}/releases/tags/{tag}"],
                            cwd=ROOT, text=True, capture_output=True)
    if result.returncode:
        if "HTTP 404" in result.stderr:
            return None
        raise ValueError("读取 GitHub Release 失败；请核对权限和网络")
    return json.loads(result.stdout)


def assert_remote_tag(tag, sha, allow_missing=False):
    remote = command("git", "ls-remote", "origin", f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}")
    if not remote:
        if allow_missing:
            return
        raise ValueError("发布 tag 不存在，未公开 Release")
    lines = [line.split() for line in remote.splitlines()]
    resolved = next((oid for oid, ref in lines if ref.endswith("^{}")), lines[0][0])
    if resolved != sha:
        raise ValueError("远端 tag 已指向另一提交，禁止覆盖或重新打 tag")


def release_notes(data, sha, tag):
    version = data["version"]
    repository = data["repository"]
    source = f"https://github.com/{repository}/blob/{sha}"
    coordinate = lambda module: data["android"]["groupId"] + ":" + data["android"]["modules"][module] + ":" + version
    assets = "\n".join(f"- `{name}`" for name in sorted(set().union(*expected_assets(data).values())))
    return f'''# {tag} · 三端原生 SDK

自有 SDK **{version}**，固定源码 `{sha}`。Lynx/Gfx **{data['lynxVersion']}**、PrimJS **{data['primjsVersion']}**。

如果此页面仍标为 **Draft**，Maven/Specs/附件的分阶段发布尚未全部完成；公开后再使用以下远程安装命令。GitHub自动生成的Source code归档用于源码下载。

## Android：从GitHub Packages引入

Maven仓库：`https://maven.pkg.github.com/{repository}`。公开Maven包的读取也需要认证，凭据放本机或CI环境，完整配置见下方接入手册。

```kotlin
dependencies {{
    implementation("{coordinate('lynx-shell')}")
    implementation("{coordinate('lynx-capacitor')}")
    debugImplementation("{coordinate('lynx-debug-tool')}")
}}
```

Shell带入Map。保留Gradle `.module` 元数据以选择Debug/Release；DebugTool只在Debug使用。附件的Maven ZIP包含本次原AAR/POM/GMM/sources，正式接入优先使用Maven坐标。

## iOS：从Specs分支引入Pod

```bash
pod repo add lynx-native-specs https://github.com/{repository}.git {data['ios']['specsBranch']}
```

```ruby
source 'https://github.com/{repository}.git'
source 'https://github.com/lynx-family/Specs.git'
source 'https://cdn.cocoapods.org/'
platform :ios, '14.0'
use_modular_headers!
use_frameworks! :linkage => :static

target 'YourApp' do
  pod 'LynxShellKit', '{version}'
  pod 'LynxCapacitorKit', '{version}'
  pod 'LynxShellDebugKit', '{version}', :configurations => ['Debug']
end
```

本仓Specs分支与附件提供Podspec JSON；源码从相同native tag获取，由消费App正常编译。该附件不是预编译XCFramework。Shell默认依赖Map及其固定第三方依赖。

## Harmony：安装同一发行的三个HAR

在Harmony工程根目录执行：

```bash
gh release download {tag} --repo {repository} --pattern native_harmony_release.py
python3 native_harmony_release.py install --version {version} --destination vendor/native --config-root .
```

安装器使用已有gh认证，验证发行描述、SHA256与Gfx双ABI，不覆盖不同文件，只打印配置片段。根工程gfx override与Entry的依赖路径应分别以各自oh-package.json5所在目录计算；完整双目录示例见接入手册。GitHub不是OHPM registry，配置file依赖后再正常安装。

## 本次附件

{assets}
- `native-release.json`：版本、sourceSHA与构建回执
- `SHA256SUMS`：最终上传字节的校验和
- `native_harmony_release.py`：独立HAR安装工具

## 装好依赖后

正式App还需初始化Router/OTA、注册能力Module、配置Host/窗口和生命周期/系统回调。JS入口由独立的@cclx/lynx-native-bridge提供。

- [本版三端接入与发布手册]({source}/docs/native-github-release.md)
- [Shell宿主接入]({source}/MODULE_INTEGRATION.md)
- [Cap注册与能力模块装配]({source}/CAPACITOR_DEMO_INTEGRATION.md)

CI构建、产物与分发校验不替代真机、媒体权限、视觉、性能和OTA业务验收。
'''


def draft(output):
    data, sha, tag = verify_release(output)
    assert_remote_tag(tag, sha, allow_missing=True)
    existing = release_info(data, tag)
    if existing is None:
        with tempfile.TemporaryDirectory(prefix="native-release-notes-") as folder:
            notes = Path(folder) / "release-notes.md"
            notes.write_text(release_notes(data, sha, tag))
            gh("release", "create", tag, "--repo", data["repository"], "--target", sha, "--draft",
               "--title", f"{tag} · Lynx 三端原生 SDK", "--notes-file", str(notes))
        existing = release_info(data, tag)
    assert_remote_tag(tag, sha)
    if not existing["draft"]:
        raise ValueError("该版本已经公开发布，禁止覆盖；请使用新版本")
    uploaded = {asset["name"] for asset in existing["assets"]}
    expected = {path.name for path in output.iterdir()}
    if uploaded - expected:
        raise ValueError("已有 Draft 含清单外资产，禁止自动修改")
    with tempfile.TemporaryDirectory(prefix="native-release-existing-") as folder:
        for name in sorted(uploaded):
            gh("release", "download", tag, "--repo", data["repository"], "--pattern", name, "--dir", folder)
            if digest(Path(folder) / name) != digest(output / name):
                raise ValueError(f"Draft 已有不同字节资产：{name}；请使用新版本")
    missing = sorted(expected - uploaded)
    if missing:
        gh("release", "upload", tag, *(str(output / name) for name in missing), "--repo", data["repository"])


def safe_extract(archive, target):
    with zipfile.ZipFile(archive) as bundle:
        for item in bundle.infolist():
            path = PurePosixPath(item.filename)
            if path.is_absolute() or ".." in path.parts or "\\" in item.filename or (item.external_attr >> 16) & 0o170000 == 0o120000:
                raise ValueError("发布 ZIP 含越界路径或软链接")
        bundle.extractall(target)


def specs(output):
    data, sha, tag = verify_release(output)
    branch = data["ios"]["specsBranch"]
    if branch != "native-specs":
        raise ValueError("只允许写 native-specs 分支")
    url = f"https://github.com/{data['repository']}.git"
    with tempfile.TemporaryDirectory(prefix="native-specs-") as folder:
        directory = Path(folder)
        command("git", "init", str(directory))
        command("git", "remote", "add", "origin", url, cwd=directory)
        remote = command("git", "ls-remote", "origin", f"refs/heads/{branch}", cwd=directory)
        if remote:
            command("git", "fetch", "--depth=1", "origin", f"refs/heads/{branch}", cwd=directory)
            command("git", "checkout", "-b", branch, "FETCH_HEAD", cwd=directory)
            tracked = command("git", "ls-files", cwd=directory).splitlines()
            if any(not name.startswith("Specs/") for name in tracked):
                raise ValueError("已有 native-specs 分支包含非 Specs 文件，拒绝自动修改")
        else:
            command("git", "checkout", "--orphan", branch, cwd=directory)
        with tempfile.TemporaryDirectory(prefix="native-specs-unpack-") as unpack:
            safe_extract(output / f"lynx-ios-specs-{data['version']}.zip", Path(unpack))
            for source in Path(unpack).rglob("*"):
                if not source.is_file():
                    continue
                relative = source.relative_to(unpack)
                if len(relative.parts) != 3 or not source.name.endswith(".podspec.json"):
                    raise ValueError("Specs ZIP 路径不符合 name/version/spec 结构")
                target = directory / "Specs" / relative
                if target.exists() and target.read_bytes() != source.read_bytes():
                    raise ValueError(f"已有不同版本描述：{relative}")
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, target)
        command("git", "add", "--", "Specs", cwd=directory)
        changed = command("git", "diff", "--cached", "--name-only", cwd=directory)
        if changed:
            if any(not line.startswith("Specs/") for line in changed.splitlines()):
                raise ValueError("Specs 提交含许可范围外文件")
            command("git", "-c", "user.name=Codex GitHub Actions", "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com",
                    "commit", "-m", f"chore(release): Codex提交，发布 iOS 原生 {data['version']} Specs",
                    "-m", f"同步四个自有模块与地图依赖描述。\n源码：{sha}\n发布tag：{tag}\n不修改main、运行时代码或已有不同版本。", cwd=directory)
            command("git", "-c", "credential.helper=!gh auth git-credential", "push", "origin", f"HEAD:refs/heads/{branch}", cwd=directory)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file, code, message, headers, new_url):
        return None


def maven_digest(opener, url, credential):
    current = url
    visited = set()
    for _ in range(6):
        parsed = urllib.parse.urlsplit(current)
        if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or current in visited:
            raise ValueError("Maven 下载出现不合法或循环重定向")
        visited.add(current)
        # 只向Maven认证端点发送凭据，资产存储站点使用自身的签名URL。
        headers = {"Authorization": "Basic " + credential} if parsed.hostname == "maven.pkg.github.com" else {}
        try:
            with opener.open(urllib.request.Request(current, headers=headers), timeout=60) as response:
                result = hashlib.sha256()
                while block := response.read(65536):
                    result.update(block)
                return result.hexdigest()
        except urllib.error.HTTPError as error:
            if error.code not in (301, 302, 303, 307, 308):
                raise
            location = error.headers.get("Location")
            if not location:
                raise ValueError("Maven 重定向缺少下载地址") from None
            current = urllib.parse.urljoin(current, location)
    raise ValueError("Maven 重定向次数超过上限")


def maven_status(output, status_file):
    data, sha, tag = verify_release(output)
    credential = base64.b64encode((os.environ["GITHUB_ACTOR"] + ":" + os.environ["GH_TOKEN"]).encode()).decode()
    opener = urllib.request.build_opener(NoRedirect())
    complete = []
    with tempfile.TemporaryDirectory(prefix="native-maven-") as folder:
        directory = Path(folder)
        safe_extract(output / f"lynx-android-maven-{data['version']}.zip", directory)
        for module, artifact in data["android"]["modules"].items():
            version_dir = directory / data["android"]["groupId"].replace(".", "/") / artifact / data["version"]
            files = [path for path in version_dir.iterdir() if path.is_file() and path.suffix in (".pom", ".module", ".aar", ".jar")]
            if not files:
                raise ValueError(f"缺少 Maven 版本文件：{artifact}")
            observed = []
            for path in files:
                url = f"https://maven.pkg.github.com/{data['repository']}/{path.relative_to(directory).as_posix()}"
                try:
                    if maven_digest(opener, url, credential) != digest(path):
                        raise ValueError(f"Maven 已有不同字节版本：{artifact}/{path.name}；禁止覆盖")
                    observed.append(True)
                except urllib.error.HTTPError as error:
                    if error.code != 404:
                        raise ValueError(f"Maven 读取失败（HTTP {error.code}），未上传") from None
                    observed.append(False)
            if any(observed) and not all(observed):
                raise ValueError(f"Maven {artifact} 已部分写入，须人工核对或使用新版本，禁止覆盖")
            if all(observed):
                complete.append(module)
    write_json(status_file, {"sourceSHA": sha, "tag": tag, "completeModules": complete})
    remaining = [name for name in data["android"]["modules"] if name not in complete]
    if remaining:
        input_dir = ROOT / "dist/native/maven-input"
        if input_dir.exists() and any(input_dir.iterdir()):
            raise ValueError("Maven 发布输入目录必须为空")
        input_dir.mkdir(parents=True, exist_ok=True)
        safe_extract(output / f"lynx-android-maven-{data['version']}.zip", input_dir)
    with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
        stream.write("tasks=" + " ".join(f":{name}:publishNativePublicationToGitHubPackagesRepository" for name in remaining) + "\n")


def finalize(output):
    data, sha, tag = verify_release(output)
    remote = release_info(data, tag)
    if remote is None or not remote["draft"]:
        raise ValueError("只允许完成当前 Draft Release")
    if {asset["name"] for asset in remote["assets"]} != {path.name for path in output.iterdir()}:
        raise ValueError("Draft Release 资产数量不完整")
    # Draft可能在后续registry写入期间被修改，公开前重新核对实际远端字节。
    with tempfile.TemporaryDirectory(prefix="native-release-final-") as folder:
        for path in sorted(output.iterdir()):
            gh("release", "download", tag, "--repo", data["repository"], "--pattern", path.name, "--dir", folder)
            if digest(Path(folder) / path.name) != digest(path):
                raise ValueError(f"Draft 远端字节发生变化：{path.name}，未公开")
    assert_remote_tag(tag, sha)
    gh("release", "edit", tag, "--repo", data["repository"], "--draft=false")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("assemble", "draft", "specs", "maven-status", "finalize"))
    parser.add_argument("--assets", type=Path, required=True)
    parser.add_argument("--inputs", type=Path)
    parser.add_argument("--status-file", type=Path)
    args = parser.parse_args()
    if args.command == "assemble":
        if args.inputs is None:
            parser.error("assemble 需要 --inputs")
        assemble(args.inputs, args.assets)
    elif args.command == "maven-status":
        if args.status_file is None:
            parser.error("maven-status 需要 --status-file")
        maven_status(args.assets, args.status_file)
    else:
        {"draft": draft, "specs": specs, "finalize": finalize}[args.command](args.assets)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError, urllib.error.URLError) as error:
        print(f"GitHub 原生发布失败：{error}", file=sys.stderr)
        sys.exit(1)
