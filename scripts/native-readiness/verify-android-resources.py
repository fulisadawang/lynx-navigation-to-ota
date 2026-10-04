#!/usr/bin/env python3
"""检查本轮实际 AAR/合并 Manifest；不以此代替 APK 或设备执行。"""
from pathlib import Path
import io
import json
import re
import sys
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[2]
ANDROID = "{http://schemas.android.com/apk/res/android}"
results = []


def record(name, condition, observed):
    results.append({"name": name, "status": "PASS" if condition else "FAIL", "observed": observed})


def minimum(module):
    text = (ROOT / "android" / module / "build.gradle.kts").read_text()
    return int(re.search(r"minSdk\s*=\s*(\d+)", text).group(1))


aar = ROOT / "android/lynx-capacitor/build/outputs/aar/lynx-capacitor-debug.aar"
merged = ROOT / "android/app/build/intermediates/merged_manifest/debug/processDebugMainManifest/AndroidManifest.xml"
if not aar.is_file() or not merged.is_file():
    raise SystemExit("先执行 :lynx-capacitor:bundleDebugAar :app:processDebugMainManifest")

with zipfile.ZipFile(aar) as archive:
    manifest = ET.fromstring(archive.read("AndroidManifest.xml"))
    record("Cap AAR minimum SDK", manifest.find("uses-sdk").get(ANDROID + "minSdkVersion") == "26", "26")
    provider = manifest.find("application/provider")
    record("Cap FileProvider not exported", provider is not None and provider.get(ANDROID + "exported") == "false", "exported=false")
    record("Cap FileProvider authority scoped to App", provider.get(ANDROID + "authorities") == "${applicationId}.lynxcapacitormodule.fileprovider", "applicationId scoped")
    paths = ET.fromstring(archive.read("res/xml/lynx_file_paths.xml"))
    record("Own FileProvider resource packaged", {node.tag for node in paths} == {"cache-path", "files-path", "external-cache-path", "external-files-path"}, "four app-scoped path entries")
    activities = manifest.findall("application/activity")
    record("Cap activities private", len(activities) == 4 and all(node.get(ANDROID + "exported") == "false" for node in activities), f"{len(activities)} activities")
    permissions = {node.get(ANDROID + "name") for node in manifest.findall("uses-permission")}
    expected = {"INTERNET", "CAMERA", "RECORD_AUDIO", "READ_CONTACTS", "WRITE_CONTACTS", "READ_CALENDAR", "WRITE_CALENDAR", "ACCESS_COARSE_LOCATION", "ACCESS_FINE_LOCATION", "VIBRATE"}
    record("Cap required permissions packaged", {"android.permission." + name for name in expected} <= permissions, "required permission names present")
    with zipfile.ZipFile(io.BytesIO(archive.read("classes.jar"))) as classes:
        name = "com/example/lynxcapacitormodule/LynxCapacitorModule.class"
        major = int.from_bytes(classes.read(name)[6:8], "big")
        record("Cap actual classfile JVM 17", major == 61, f"classfile major={major}")
        record("Cap does not duplicate Lynx Runtime", not any(name.startswith("com/lynx/") and name.endswith(".class") for name in classes.namelist()), "Lynx classes are compileOnly")

app = ET.parse(merged).getroot()
package = app.get("package")
record("Isolated test App manifest", package == "com.hugboga.custom.otae2e", package)
record("Merged App minimum SDK", app.find("uses-sdk").get(ANDROID + "minSdkVersion") == "26", "26")
providers = [node for node in app.findall("application/provider") if node.get(ANDROID + "authorities", "").endswith(".lynxcapacitormodule.fileprovider")]
record("Merged provider unique and correctly scoped", len(providers) == 1 and providers[0].get(ANDROID + "authorities") == package + ".lynxcapacitormodule.fileprovider" and providers[0].get(ANDROID + "exported") == "false", f"{len(providers)} matching provider")
activities = [node for node in app.findall("application/activity") if "lynxcapacitormodule" in node.get(ANDROID + "name", "")]
record("Merged Cap activities private", len(activities) == 4 and all(node.get(ANDROID + "exported") == "false" for node in activities), f"{len(activities)} activities")

gradle_text = "\n".join(path.read_text() for path in (ROOT / "android").glob("*/build.gradle.kts"))
instant_sources = [path.relative_to(ROOT).as_posix() for path in (ROOT / "android/lynx-shell/src/main").rglob("*.kt") if "import java.time.Instant" in path.read_text()]
desugared = "isCoreLibraryDesugaringEnabled = true" in gradle_text and "desugar_jdk_libs" in gradle_text
record("Shell standalone declared API baseline", minimum("lynx-shell") >= 26 or desugared or not instant_sources, {"declaredMinSdk": minimum("lynx-shell"), "instantSources": instant_sources, "coreLibraryDesugaringConfigured": desugared, "scope": "configuration/API compatibility; no API24 device crash observation"})

output = {"scope": "actual Debug Cap AAR and isolated App merged Manifest; APK is not built", "checks": results, "totals": {status: sum(item["status"] == status for item in results) for status in ("PASS", "FAIL")}}
destination = ROOT / ".workflow/lynx-native-readiness-ios-android/results/android-config-check.json"
destination.write_text(json.dumps(output, ensure_ascii=False, indent=2) + "\n")
print(json.dumps(output["totals"], ensure_ascii=False))
for item in results:
    if item["status"] != "PASS":
        print(json.dumps(item, ensure_ascii=False))
sys.exit(1 if output["totals"]["FAIL"] else 0)
