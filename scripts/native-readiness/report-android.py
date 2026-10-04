#!/usr/bin/env python3
"""生成 Android 分阶段报告，只采用逐项实际证据，不从源码或 JVM 推断设备通过。"""

import argparse
import html
import json
import os
import re
import sys
from collections import Counter
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo


WORKFLOW = Path(".workflow/lynx-native-readiness-ios-android/results")
STATUSES = ("PASS", "FAIL", "BLOCKED", "NOT RUN")
SCOPES = (
    ("OTA-SEL", "启动恢复", "Shell 内置 OTA"),
    ("OTA-PAGE", "页面健康、Tab 与故障", "Shell + 模板业务信号"),
    ("CAP-OWN", "owner、取消与清理", "Cap + Shell View 销毁接线"),
    ("CAP-IO", "线程、并发与负载", "Cap"),
    ("CAP-STATUS", "能力状态与 Host", "Cap provider + Host 组合根 + Shell 中性 API"),
    ("HOST-BASE", "模块资源与系统基线", "自有 AAR + Host Manifest / Gradle"),
)


def esc(value):
    return html.escape(str(value if value is not None else ""), quote=True)


def badge(status):
    return '<span class="badge ' + status.lower().replace(" ", "-") + '">' + esc(status) + '</span>'


def read_json(path, fallback):
    return json.loads(path.read_text()) if path.exists() else fallback


def read_cases(path):
    cases = []
    for line in path.read_text().splitlines():
        if not re.match(r"\| (?:OTA|CAP|HOST)-", line):
            continue
        values = [value.strip() for value in line.strip().strip("|").split("|")]
        if len(values) != 4:
            raise ValueError("用例行格式无效")
        cases.append(dict(zip(("id", "steps", "expected", "requiredLayer"), values)))
    if len(cases) != 36 or len({case["id"] for case in cases}) != 36:
        raise ValueError("必须读取 36 个唯一用例")
    return cases


def link(path, label, root, output):
    if not path:
        return esc(label or "未提供")
    if str(path).startswith(("https://", "http://")):
        url = str(path)
    else:
        p = Path(path)
        url = os.path.relpath(p if p.is_absolute() else root / p, output.parent)
    return '<a href="' + esc(url) + '">' + esc(label or path) + '</a>'


def validate(summary, cases):
    results = summary.get("cases", {})
    unknown = set(results) - {case["id"] for case in cases}
    if unknown:
        raise ValueError("未知用例：" + ",".join(sorted(unknown)))
    for case in cases:
        result = results.get(case["id"], {})
        if result.get("status", "NOT RUN") not in STATUSES:
            raise ValueError(case["id"] + " 结果必须使用四种约定状态")
        if result.get("status") == "PASS" and not result.get("evidence"):
            raise ValueError(case["id"] + " 的 PASS 缺执行证据")
        case["result"] = {"status": "NOT RUN", "observed": "未收到本轮结果，不能推断通过。", "missing": [], "evidence": [], **result}
    ready = summary.get("conclusion", {}).get("androidGateReady", False)
    if ready and not summary.get("final"):
        raise ValueError("草稿不能声明 Android 门禁通过")
    for run in summary.get("runs", []):
        if run.get("status", "NOT RUN") not in STATUSES:
            raise ValueError("批次状态无效")
        if all(key in run for key in ("total", "passed", "failed", "skipped")) and run["total"] != run["passed"] + run["failed"] + run["skipped"]:
            raise ValueError("批次计数不一致：" + run.get("name", ""))
    if ready and any(run.get("failed", 0) or run.get("status") == "FAIL" for run in summary.get("runs", [])):
        raise ValueError("最新运行仍有失败，不能声明门禁通过")
    if ready and any(case["result"]["status"] == "FAIL" for case in cases):
        raise ValueError("验收项仍有 FAIL，不能声明门禁通过")
    if ready and summary.get("buildState", {}).get("status") != "PASS":
        raise ValueError("APK 构建没有实际 PASS，不能声明 Android 宿主门禁通过")


def evidence_html(values, root, output):
    return '<ul>' + "".join('<li><b>' + esc(value.get("layer", "未提供层级")) + '</b> · ' + link(value.get("artifact"), value.get("test", "未提供测试名"), root, output) + '</li>' for value in values) + '</ul>' if values else '<p class="muted">尚无本轮执行证据。</p>'


def list_html(values):
    return '<ul>' + "".join('<li>' + esc(value) + '</li>' for value in values) + '</ul>'


def render_html(summary, cases, template, root, output):
    counts = Counter(case["result"]["status"] for case in cases)
    conclusion = summary.get("conclusion", {})
    headline = conclusion.get("headline", "Android 验证尚未完成")
    metrics = "".join('<div class="metric"><strong>' + str(counts[status]) + '</strong>' + badge(status) + '</div>' for status in STATUSES)
    executed_metrics = '<div class="metrics">' + "".join('<div class="metric"><strong>' + str(run.get("passed", "—")) + '</strong><span class="small">' + esc(label) + '</span></div>' for label, run in zip(("Core/JVM PASS，另3外部服务SKIP", "API26 有效方法 PASS", "API36 有效方法 PASS", "Cold B 独立进程 PASS"), summary.get("runs", [])[:4])) + '</div>' if summary.get("final") else ""
    implementation = '<h3>这轮实现了什么</h3>' + list_html(summary.get("implementationNotes", [])) if summary.get("implementationNotes") else ""
    scopes = "".join('<article><span class="muted">' + esc(prefix) + '</span><h3>' + esc(name) + '</h3><p>' + esc(owner) + '</p></article>' for prefix, name, owner in SCOPES)
    rows = []
    for case in cases:
        result = case["result"]
        platform = '<dt>Android 平台契约</dt><dd>' + esc(result["platformContract"]) + '</dd>' if result.get("platformContract") else ""
        search = " ".join(str(value) for value in (case["id"], case["steps"], case["expected"], result["observed"]))
        rows.append('<tr class="case-row" data-status="' + esc(result["status"]) + '" data-search="' + esc(search.lower()) + '"><td><b>' + esc(case["id"]) + '</b><p class="small">' + esc(case["requiredLayer"]) + '</p></td><td>' + badge(result["status"]) + '</td><td><p>' + esc(result["observed"]) + '</p><details><summary>步骤、预期、证据和未覆盖层</summary><dl><dt>跨端原始操作</dt><dd>' + esc(case["steps"]) + '</dd><dt>原始预期</dt><dd>' + esc(case["expected"]) + '</dd>' + platform + '<dt>实际执行证据</dt><dd>' + evidence_html(result["evidence"], root, output) + '</dd><dt>未覆盖</dt><dd>' + (list_html(result["missing"]) if result["missing"] else '<p class="muted">未单列；仍仅限实际证据范围。</p>') + '</dd></dl></details></td></tr>')
    run_rows = []
    for run in summary.get("runs", []):
        stats = " · ".join(label + " " + str(run[key]) for key, label in (("total", "tests"), ("passed", "pass"), ("failed", "fail"), ("skipped", "skip")) if key in run)
        run_rows.append('<tr><td><b>' + esc(run.get("name", "未命名")) + '</b><p>' + esc(stats) + '</p></td><td>' + badge(run.get("status", "NOT RUN")) + '</td><td>' + link(run.get("artifact"), "原始日志 / 结果", root, output) + '<p>' + esc(run.get("notes", "")) + '</p>' + ('<code class="command">' + esc(run["command"]) + '</code>' if run.get("command") else "") + '</td></tr>')
    environment = '<dl class="environment">' + "".join('<div><dt>' + esc(key) + '</dt><dd>' + esc(value) + '</dd></div>' for key, value in summary.get("environment", {}).items()) + '</dl>'
    build = summary.get("buildState", {"status": "NOT RUN", "observed": "未收到 APK 构建证据。"})
    build_html = '<div class="callout"><b>APK / 宿主状态：' + badge(build["status"]) + '</b><p>' + esc(build.get("observed", "")) + '</p>' + ('<p>' + link(build.get("artifact"), "对应日志", root, output) + '</p>' if build.get("artifact") else "") + '</div>'
    config_rows = "".join('<tr><td>' + esc(item.get("name", "未命名")) + '</td><td>' + badge(item.get("status", "NOT RUN")) + '</td><td>' + esc(json.dumps(item["observed"], ensure_ascii=False) if isinstance(item.get("observed"), dict) else item.get("observed", "")) + '</td></tr>' for item in summary.get("configurationChecks", []))
    config_counts = Counter(item.get("status", "NOT RUN") for item in summary.get("configurationChecks", []))
    config_html = '<h3>实际 Library / Manifest 配置检查</h3><p>当前 ' + str(config_counts["PASS"]) + ' PASS / ' + str(config_counts["FAIL"]) + ' FAIL。配置/API 结论与设备行为分别记录；产物范围以对应批次证据为准。</p><table><thead><tr><th>检查</th><th>结果</th><th>实际观察</th></tr></thead><tbody>' + config_rows + '</tbody></table>' if config_rows else ""
    instrument_rows = "".join('<tr><td>' + esc(item["test"]) + '</td><td>' + badge(item.get("status", "NOT RUN")) + '</td><td>' + esc(item.get("observed", "")) + '</td></tr>' for item in summary.get("instrumentation", []))
    instrument_html = '<h3>新增 Android 宿主测试</h3><table><thead><tr><th>方法</th><th>结果</th><th>边界</th></tr></thead><tbody>' + instrument_rows + '</tbody></table>' if instrument_rows else ""
    template_rows = "".join('<tr><td>' + link(item.get("path"), Path(item["path"]).name, root, output) + '</td><td>' + str(item.get("size", "未提供")) + '</td><td><code class="hash">' + esc(item.get("sha256", "未提供")) + '</code></td></tr>' for item in template)
    artifacts = '<table><thead><tr><th>实际产物 / 证据</th><th>bytes</th><th>SHA-256 / 范围</th></tr></thead><tbody>' + "".join('<tr><td>' + link(item.get("path"), item.get("name", "产物"), root, output) + '</td><td>' + esc(item.get("size", "—")) + '</td><td>' + ('<code class="hash">' + esc(item["sha256"]) + '</code>' if item.get("sha256") else esc(item.get("notes", ""))) + '</td></tr>' for item in summary.get("artifacts", [])) + '</tbody></table>'
    history = "".join('<details class="history"><summary>' + esc(item.get("stage", "历史失败")) + '</summary><p><b>原始观察：</b>' + esc(item.get("observed", "")) + '</p><p><b>处理：</b>' + esc(item.get("fix", "")) + '</p><p>' + link(item.get("retestArtifact"), "复跑证据", root, output) + '</p></details>' for item in summary.get("historicalFailures", []))
    pictures = "".join('<figure><img loading="lazy" src="' + esc(os.path.relpath(Path(item["path"]) if Path(item["path"]).is_absolute() else root / item["path"], output.parent)) + '" alt="' + esc(item.get("caption", "本轮截图")) + '"><figcaption>' + esc(item.get("caption", "本轮截图")) + '</figcaption></figure>' for item in summary.get("screenshots", []))
    source = summary.get("source", {})
    fingerprints = '<details><summary>本轮生产源码指纹</summary><table><thead><tr><th>文件</th><th>SHA-256</th></tr></thead><tbody>' + "".join('<tr><td>' + link(item.get("path"), item.get("path"), root, output) + '</td><td><code class="hash">' + esc(item.get("sha256", "未提供")) + '</code></td></tr>' for item in source.get("fingerprints", [])) + '</tbody></table></details>' if source.get("fingerprints") else ""
    state = "最终报告" if summary.get("final") else "草稿 · 等待最终宿主执行证据"
    notes = summary.get("remaining", []) + ["JVM 测试不替代真实 LynxView、Activity/Window、系统权限、硬件或进程生命周期。", "目录 40 域 / 146 方法不等于全方法实测；本轮没有整体 FPS、峰值内存或长时间泄漏结论。"]
    return '''<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Android 原生基座 · 测试报告</title><style>
:root{--ink:#173549;--muted:#647987;--line:#dce7ec;--green:#087951;--red:#b22635;--amber:#93620c}*{box-sizing:border-box}body{margin:0;background:#f2f7f8;color:var(--ink);font:16px/1.7 -apple-system,BlinkMacSystemFont,"PingFang SC","Microsoft YaHei",sans-serif}header{background:#153a40;color:#fff;padding:46px max(24px,calc((100vw - 1160px)/2)) 36px}h1{font-size:clamp(30px,4vw,46px);line-height:1.35;margin:12px 0}header p{max-width:950px;color:#cadddf}.eyebrow{letter-spacing:1px;font-weight:800;font-size:12px;color:#86d4bf}nav{position:sticky;top:0;z-index:2;background:#fffffff0;border-bottom:1px solid var(--line);padding:14px;display:flex;justify-content:center;flex-wrap:wrap;gap:24px}a{color:#24628c;text-decoration:none;overflow-wrap:anywhere}a:hover{text-decoration:underline}main{max-width:1210px;margin:auto;padding:24px}section{scroll-margin-top:90px;background:#fff;border:1px solid var(--line);border-radius:15px;padding:27px;margin-bottom:24px}h2{font-size:25px;margin:0 0 18px}h3{font-size:19px;margin:9px 0}p{margin:7px 0 14px}.muted,.small{color:var(--muted)}.small{font-size:13px}.callout{background:#fff8e9;border-left:5px solid #d19b38;border-radius:9px;padding:16px 20px;margin:16px 0}.metrics{display:grid;grid-template-columns:repeat(4,1fr);gap:14px}.metric{border:1px solid var(--line);border-radius:10px;padding:17px;background:#f8fbfc}.metric strong{display:block;font-size:37px}.badge{display:inline-flex;border-radius:5px;font-size:12px;font-weight:800;padding:3px 8px;white-space:nowrap}.pass{background:#e5f5ed;color:var(--green)}.fail{background:#ffebee;color:var(--red)}.blocked{background:#fff0d1;color:var(--amber)}.not-run{background:#eaf0f4;color:#5b7080}.scopes{display:grid;grid-template-columns:repeat(3,1fr);gap:14px;margin-top:22px}.scopes article{padding:18px;background:#f6fafb;border:1px solid var(--line);border-radius:10px}.scopes p{font-size:14px}.environment{display:grid;grid-template-columns:repeat(3,1fr);gap:11px}.environment>div{background:#f4f8fa;padding:12px;border-radius:7px}.environment dd{margin:4px 0;font-size:14px;overflow-wrap:anywhere}table{border-collapse:collapse;width:100%;font-size:14px;margin:17px 0}th{text-align:left;background:#eff5f7;padding:12px;border-bottom:2px solid var(--line)}td{padding:13px 12px;vertical-align:top;border-bottom:1px solid var(--line)}td p{margin:3px 0 9px}.table-scroll{overflow-x:auto}.case-table td:first-child{width:21%}.case-table td:nth-child(2){width:10%}details{padding:10px 13px;border:1px solid #e3edf0;background:#f8fbfc;border-radius:7px;margin-top:10px}summary{cursor:pointer;color:#356374;font-weight:650}dt{font-size:13px;font-weight:800;color:#406d7b}dd{margin:3px 0 14px}li{margin:6px 0}code{font:12px/1.7 ui-monospace,SFMono-Regular,Menlo,monospace;color:#345a73;overflow-wrap:anywhere}.hash{font-size:11px;word-break:break-all}.command{display:block;white-space:pre-wrap;padding:8px;background:#edf5f8;border-radius:5px}.filters{display:flex;gap:8px;flex-wrap:wrap;align-items:center}.filters button{border:1px solid var(--line);background:#fff;border-radius:6px;padding:9px 12px;color:var(--ink);cursor:pointer}.filters button.active{background:#214e5a;color:#fff}.filters input{flex:1;min-width:200px;padding:9px 12px;font:inherit;font-size:14px;border:1px solid var(--line);border-radius:6px}.history{border-left:3px solid #b8d4dd;padding:1px 0 1px 18px;margin:20px 0}.screenshots{display:flex;flex-wrap:wrap;gap:22px}.screenshots figure{max-width:280px;margin:0}.screenshots img{max-width:100%;border:1px solid var(--line);border-radius:12px}.screenshots figcaption{font-size:13px;color:var(--muted)}footer{max-width:1160px;margin:0 auto;padding:0 24px 35px;color:var(--muted);font-size:13px}@media(max-width:800px){.scopes,.environment{grid-template-columns:1fr 1fr}header{padding:32px 24px}section{padding:20px}main{padding:16px}}@media(max-width:570px){.scopes,.environment{grid-template-columns:1fr}.metrics{grid-template-columns:1fr 1fr}.case-table{min-width:750px}}@media print{nav,.filters{display:none}body{background:#fff}header{background:#fff;color:var(--ink)}header p{color:var(--muted)}section{border-radius:0;break-inside:avoid}}
</style></head><body><header><span class="eyebrow">LYNX NATIVE READINESS · ANDROID</span><h1>''' + esc(headline) + '''</h1><p>''' + esc(state) + ' · ' + esc(summary.get("generatedAt", "未提供生成时间")) + '''</p><p>JVM、Library 构建、完整 APK、真实 Lynx 宿主和硬件分别记录。只有实际执行覆盖该行必要层时才 PASS；部分 JVM 检查通过而宿主未跑的行继续保留 NOT RUN。</p></header><nav><a href="#overview">结论与归属</a><a href="#cases">36 项用例</a><a href="#runs">执行证据</a><a href="#bundles">真实模板</a><a href="#history">历史失败</a><a href="#remaining">未覆盖项</a></nav><main><section id="overview"><h2>当前结论</h2><p>''' + esc(conclusion.get("detail", "未收到最终结果，不推断完成。")) + '</p>' + executed_metrics + build_html + '<div class="metrics">' + metrics + '''</div><p class="small">计数是验收行的结果，不是 JUnit 方法数量；每行展开可看已通过子层与仍缺的宿主/设备层。</p><div class="scopes">''' + scopes + '''</div>''' + implementation + '''<p class="small">本轮不补 Harmony，不增加签名、Direct 限制、监控供应商、独立协议版本门槛或正式业务 App 安装包验收。</p></section><section id="cases"><h2>36 项用例与逐层证据</h2><div class="filters"><button class="active" data-filter="ALL">全部</button>''' + "".join('<button data-filter="' + status + '">' + status + '</button>' for status in STATUSES) + '''<input id="query" type="search" aria-label="搜索用例" placeholder="搜索编号、步骤或实际观察"><span id="visible-count" class="small">36 项</span></div><div class="table-scroll"><table class="case-table"><thead><tr><th>编号 / 必要层</th><th>结果</th><th>实际观察与范围</th></tr></thead><tbody>''' + "".join(rows) + '''</tbody></table></div></section><section id="runs"><h2>当前实际执行</h2>''' + environment + '<table><thead><tr><th>批次</th><th>结果</th><th>证据与边界</th></tr></thead><tbody>' + "".join(run_rows) + '''</tbody></table>''' + config_html + instrument_html + '''<p>Core/JVM：真实 Store 文件、HTTP fixture、纯 JVM owner/执行器/预算协议。Host：真实 Android View/Activity、Module 与系统接线。UI/Device：实际 App、Lynx 回调、系统窗口与设备行为。构建或源码审查不作为后两层 PASS。</p>''' + artifacts + '<p>Git HEAD：<code>' + esc(source.get("nativeHead", "未提供")) + '</code></p><p>' + esc(source.get("notes", "")) + '</p>' + fingerprints + '''</section><section id="bundles"><h2>用户模板与本地服务</h2><p>地址 http://127.0.0.1:60543。HomePage / OtaEcommercePage 与 Async 3 都是当前真实产物字节；JVM 的最小故障 fixture 另行说明，不将其冒充真实模板设备测试。</p><p>''' + esc(summary.get("templateVerification", "Android 真实 View、主/Async 下载尚未设备验证。")) + '''</p><table><thead><tr><th>真实产物</th><th>bytes</th><th>SHA-256</th></tr></thead><tbody>''' + template_rows + '</tbody></table><div class="screenshots">' + pictures + '''</div></section><section id="history"><h2>历史失败与处理</h2><p>原始失败日志保留；当前结果只采用最新完整执行，不把历史失败写成当前仍失败，也不删除原问题。</p>''' + (history or '<p class="muted">尚未填入最终修复记录。</p>') + '''</section><section id="remaining"><h2>未覆盖与下一阶段条件</h2>''' + list_html(notes) + '''<p>本报告只记录已执行的构建与测试，当前未 commit/push。</p></section></main><footer>生成源 scripts/native-readiness/report-android.py · 实际输入 results/android-final-summary.json · 用例 docs/native-readiness-v1/test-cases.md</footer><script>
(()=>{let filter='ALL';const rows=[...document.querySelectorAll('.case-row')],buttons=[...document.querySelectorAll('[data-filter]')],query=document.querySelector('#query');function update(){let count=0;for(const row of rows){const show=(filter==='ALL'||row.dataset.status===filter)&&(!query.value.trim()||row.dataset.search.includes(query.value.trim().toLowerCase()));row.hidden=!show;if(show)count++}document.querySelector('#visible-count').textContent=count+' / '+rows.length+' 项'}for(const button of buttons)button.addEventListener('click',()=>{filter=button.dataset.filter;for(const other of buttons)other.classList.toggle('active',other===button);update()});query.addEventListener('input',update)})();
</script></body></html>'''


def md(value):
    return str(value if value is not None else "").replace("|", "\\|").replace("\n", " ")


def render_markdown(summary, cases, template):
    counts = Counter(case["result"]["status"] for case in cases)
    lines = ["# Android 原生基座测试报告", "", "状态：" + ("最终报告" if summary.get("final") else "草稿，等待最终宿主执行证据"), "", summary.get("conclusion", {}).get("headline", "验证尚未完成"), "", summary.get("conclusion", {}).get("detail", ""), "", "APK状态：" + summary.get("buildState", {}).get("status", "NOT RUN") + "；" + summary.get("buildState", {}).get("observed", "未提供"), "", "36项：" + "；".join(status + "=" + str(counts[status]) for status in STATUSES), "", "JVM 子层通过但必要 Host/UI 未跑时，整行继续保留 NOT RUN；不能从源码审查或构建推断设备行为。", "", "## 逐项结果", "", "| 编号 | 结果 | 实际观察 | 执行证据 | 未覆盖 |", "|---|---|---|---|---|"]
    for case in cases:
        result = case["result"]
        evidence = "；".join(item.get("layer", "未提供") + ":" + item.get("test", "未提供") + "（" + item.get("artifact", "未提供") + "）" for item in result["evidence"])
        lines.append("| " + " | ".join(md(value) for value in (case["id"], result["status"], result["observed"], evidence, "；".join(result["missing"]))) + " |")
    lines += ["", "## 环境与最新批次", ""]
    lines += ["- " + md(key) + "：" + md(value) for key, value in summary.get("environment", {}).items()]
    for run in summary.get("runs", []):
        lines += ["", "- " + run.get("name", "未命名") + "：" + run.get("status", "NOT RUN") + "；" + "，".join(key + "=" + str(run[key]) for key in ("total", "passed", "failed", "skipped") if key in run) + "。证据：" + run.get("artifact", "未提供") + "。" + run.get("notes", "")]
    lines += ["", "## 实际配置检查", "", "| 检查 | 结果 | 观察 |", "|---|---|---|"]
    lines += ["| " + md(item.get("name", "")) + " | " + md(item.get("status", "NOT RUN")) + " | " + md(json.dumps(item["observed"], ensure_ascii=False) if isinstance(item.get("observed"), dict) else item.get("observed", "")) + " |" for item in summary.get("configurationChecks", [])]
    lines += ["", "## 新增宿主测试", "", "| 方法 | 状态 | 观察 |", "|---|---|---|"]
    lines += ["| " + md(item["test"]) + " | " + md(item.get("status", "NOT RUN")) + " | " + md(item.get("observed", "")) + " |" for item in summary.get("instrumentation", [])]
    lines += ["", "## 真实模板", "", "本地服务 http://127.0.0.1:60543，真实主包2 + Async3。", "", summary.get("templateVerification", "Android真实View/下载尚未设备验证。"), "", "| 文件 | bytes | SHA-256 |", "|---|---|---|"]
    lines += ["| " + md(item["path"]) + " | " + str(item.get("size", "未提供")) + " | " + md(item.get("sha256", "未提供")) + " |" for item in template]
    lines += ["", "## 历史失败与处理", ""]
    for item in summary.get("historicalFailures", []):
        lines += ["- " + item.get("stage", "历史失败") + "：" + item.get("observed", "") + " 处理：" + item.get("fix", "") + " 复跑：" + item.get("retestArtifact", "未提供"), ""]
    lines += ["## 截图", ""]
    for item in summary.get("screenshots", []):
        lines += ["![" + item.get("caption", "本轮截图") + "](" + item["path"] + ")", ""]
    lines += ["## 未覆盖", ""]
    lines += ["- " + item for item in summary.get("remaining", [])]
    lines += ["- 未经实际运行，不声明完整146方法、FPS、峰值内存或无泄漏。", "", "本轮不补Harmony，不增加签名、Direct限制、监控供应商、协议版本门槛或正式业务App安装包验收。没有commit/push。", ""]
    source = summary.get("source", {})
    lines += ["## 当前生产源码快照", "", "Git HEAD：" + source.get("nativeHead", "未提供"), "", source.get("notes", ""), "", "完整指纹：[" + str(len(source.get("fingerprints", []))) + " 个生产文件](" + source.get("fingerprintsArtifact", "android-production-fingerprints.json") + ")。HTML 中可折叠查看。", ""]
    lines += ["测试指纹：[" + str(len(source.get("testFingerprints", []))) + " 个测试文件](" + source.get("testFingerprintsArtifact", "android-test-source-fingerprints.json") + ")。", "", "## 本轮实现要点", ""]
    lines += ["- " + item for item in summary.get("implementationNotes", [])]
    lines += ["", "## 最终实际产物", "", "| 文件 | bytes | SHA-256 |", "|---|---|---|"]
    lines += ["| " + md(item.get("name")) + " | " + str(item.get("size", "—")) + " | " + md(item.get("sha256", "未提供")) + " |" for item in summary.get("artifacts", []) if item.get("sha256")]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--summary", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    summary_path = args.summary or root / WORKFLOW / "android-final-summary.json"
    summary = read_json(summary_path, {"final": False, "generatedAt": datetime.now(ZoneInfo("Asia/Shanghai")).isoformat()})
    cases = read_cases(root / "docs/native-readiness-v1/test-cases.md")
    validate(summary, cases)
    template = read_json(root / WORKFLOW / "template-artifacts-final.json", [])
    output = root / "docs/native-readiness-v1/android-test-report.html"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(render_html(summary, cases, template, root, output))
    (output.parent / "android-test-report.md").write_text(render_markdown(summary, cases, template))
    print(json.dumps({"final": summary.get("final", False), "cases": len(cases), "statuses": dict(Counter(case["result"]["status"] for case in cases)), "html": str(output)}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError) as error:
        print("Android报告生成失败：" + str(error), file=sys.stderr)
        sys.exit(1)
