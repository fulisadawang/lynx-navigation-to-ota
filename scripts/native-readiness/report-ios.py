#!/usr/bin/env python3
"""由实际结果生成 iOS HTML/Markdown 报告；缺少结果不会推断为通过。"""

import argparse
import html
import json
import os
import re
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path


WORKFLOW = Path(".workflow/lynx-native-readiness-ios-android/results")
STATUSES = ("PASS", "FAIL", "BLOCKED", "NOT RUN")
GROUPS = (
    ("OTA-SEL", "启动恢复", "Shell 内置 OTA", "在首次读取前恢复遗留 TRIAL，保留 PENDING，遵守身份与 Store 原子事务。"),
    ("OTA-PAGE", "页面健康与故障", "Shell + 模板业务入口", "真实首屏与显式业务健康信号共同确认；确认后的 Fatal 不自动回滚业务数据。"),
    ("CAP-OWN", "页面 owner 与取消", "Cap + Shell 销毁接线", "回包和事件归属真实 Module owner；宿主注册销毁钩子，资源释放按原 ctx 精确执行。"),
    ("CAP-IO", "线程、并发与负载", "Cap", "UI 留在主线程；IO/编码进入有界执行器，超出负载预算明确失败。"),
    ("CAP-STATUS", "真实能力与 Host", "Cap provider + Host 组合根 + Shell 中性 API", "目录状态、运行时可用性和权限分别表达；源 View 决定操作与恢复的归属。"),
    ("HOST-BASE", "模块资源与系统基线", "Shell/Cap Pod + Host 工程", "模块打入自己的隐私资源；用途文案属于宿主；声明的最低系统需要单独运行证据。"),
)
EXCLUDED = ("Harmony 补齐", "Bundle 签名", "Direct Bundle 入口限制", "监控供应商接入", "独立 Native 协议版本门槛", "正式业务 App 最终发布包验收")
EVIDENCE_LAYERS = (
    ("Core", "真实文件 Store、事务、校验与可控 API；不包含 UIKit/设备行为。"),
    ("Host", "真实生产类、Module/Runtime 与可控系统替身；不能代替真实权限与硬件。"),
    ("UI", "本地测试 App、真实模板字节、真实 Lynx 首屏/页面回调。"),
    ("Config / Build", "配置解析、源与实际产物比较、构建；不能证明生命周期或性能。"),
    ("Device", "真机权限、硬件、系统后台与最低系统行为，未运行必须明确标记。"),
)


def esc(value):
    return html.escape(str(value if value is not None else ""), quote=True)


def status_class(status):
    return status.lower().replace(" ", "-")


def badge(status):
    return '<span class="badge ' + status_class(status) + '">' + esc(status) + '</span>'


def parse_cases(path):
    cases = []
    for line in path.read_text().splitlines():
        if not re.match(r"\| (?:OTA|CAP|HOST)-", line):
            continue
        fields = [field.strip() for field in line.strip().strip("|").split("|")]
        if len(fields) != 4:
            raise ValueError("用例行格式不正确：" + fields[0])
        cases.append(dict(zip(("id", "steps", "expected", "requiredLayer"), fields)))
    if len(cases) != 36 or len({case["id"] for case in cases}) != 36:
        raise ValueError("必须从用例文档读取唯一的 36 项")
    return cases


def read_json(path, fallback):
    return json.loads(path.read_text()) if path.exists() else fallback


def item_list(values):
    if isinstance(values, str):
        return [values]
    return values or []


def validate_summary(summary, cases):
    if summary.get("conclusion", {}).get("iosGateReady") and not summary.get("final"):
        raise ValueError("草稿不能声明 iOS 门禁通过")
    results = summary.get("cases", {})
    unknown = set(results) - {case["id"] for case in cases}
    if unknown:
        raise ValueError("summary 含未知用例：" + ", ".join(sorted(unknown)))
    for case in cases:
        result = results.get(case["id"], {})
        status = result.get("status", "NOT RUN")
        if status not in STATUSES:
            raise ValueError(case["id"] + " 结果必须是四种约定状态之一")
        if status == "PASS" and not result.get("evidence"):
            raise ValueError(case["id"] + " 缺少 PASS 的执行证据")
        case["result"] = {"status": status, "observed": "未收到本轮执行结果；不能据其他测试通过推断本项。", **result}
    for run in summary.get("runs", []):
        if run.get("status", "NOT RUN") not in STATUSES:
            raise ValueError("测试批次状态无效：" + run.get("name", "未命名"))
        fields = ("total", "passed", "failed", "skipped")
        if all(field in run for field in fields) and sum(run[field] for field in fields[1:]) != run["total"]:
            raise ValueError("测试批次数量不一致：" + run.get("name", "未命名"))
    if summary.get("conclusion", {}).get("iosGateReady") and any(run.get("failed", 0) or run.get("status") == "FAIL" for run in summary.get("runs", [])):
        raise ValueError("最新批次含 FAIL，不能声明 iOS 门禁通过；历史失败应放 historicalFailures")


def link(path, label, root, output_parent):
    if not path:
        return esc(label or "未提供")
    if str(path).startswith(("https://", "http://")):
        url = str(path)
    else:
        file_path = Path(path)
        if not file_path.is_absolute():
            file_path = root / file_path
        url = os.path.relpath(file_path, output_parent)
    return '<a href="' + esc(url) + '">' + esc(label or path) + '</a>'


def evidence_html(evidence, root, output_parent):
    entries = []
    for item in evidence or []:
        if isinstance(item, str):
            entries.append("<li>" + esc(item) + "</li>")
            continue
        label = item.get("test") or item.get("name") or item.get("artifact") or "未提供测试名"
        command = '<code class="command">' + esc(item["command"]) + '</code>' if item.get("command") else ""
        entries.append("<li><b>" + esc(item.get("layer", "未提供层级")) + "</b> · " + link(item.get("artifact"), label, root, output_parent) + command + "</li>")
    return '<ul class="evidence">' + "".join(entries) + "</ul>" if entries else '<p class="muted">尚无本轮执行证据。</p>'


def list_html(values):
    return "<ul>" + "".join("<li>" + esc(value) + "</li>" for value in item_list(values)) + "</ul>"


def render_html(summary, cases, config, template, root, output_parent):
    final = summary.get("final", False)
    counts = Counter(case["result"]["status"] for case in cases)
    conclusion = summary.get("conclusion", {})
    headline = conclusion.get("headline", "iOS 验证尚未完成")
    detail = conclusion.get("detail", "尚未收到 ios-final-summary.json。当前仅记录已读取的配置证据，36 项运行状态保持未执行。")
    cards = "".join('<div class="metric ' + status_class(status) + '"><strong>' + str(counts[status]) + '</strong><span>' + status + ' · 用例</span></div>' for status in STATUSES)
    rows = []
    for case in cases:
        result = case["result"]
        missing = list_html(result.get("missing")) if result.get("missing") else '<p class="muted">未单列缺口；结论仍限定为下列执行证据。</p>'
        search = " ".join(str(value) for value in (case["id"], case["steps"], case["expected"], result["observed"]))
        rows.append('<tr class="case-row" data-status="' + esc(result["status"]) + '" data-search="' + esc(search.lower()) + '"><td><b>' + esc(case["id"]) + '</b><p class="layer">' + esc(case["requiredLayer"]) + '</p></td><td>' + badge(result["status"]) + '</td><td><p class="observed">' + esc(result["observed"]) + '</p><details><summary>步骤、预期与执行证据</summary><dl><dt>前置与操作</dt><dd>' + esc(case["steps"]) + '</dd><dt>必须观察到</dt><dd>' + esc(case["expected"]) + '</dd><dt>本轮证据</dt><dd>' + evidence_html(result.get("evidence"), root, output_parent) + '</dd><dt>尚未覆盖</dt><dd>' + missing + '</dd></dl></details></td></tr>')
    group_cards = []
    for prefix, title, owner, contract in GROUPS:
        group_count = Counter(case["result"]["status"] for case in cases if case["id"].startswith(prefix))
        group_cards.append('<article class="scope-card"><span class="eyebrow">' + esc(prefix) + '</span><h3>' + esc(title) + '</h3><p class="owner">' + esc(owner) + '</p><p>' + esc(contract) + '</p><p class="small">' + ' / '.join(esc(status) + ' ' + str(group_count[status]) for status in STATUSES if group_count[status]) + '</p></article>')
    runs = []
    for run in summary.get("runs", []):
        stats = " · ".join(str(run[key]) + " " + label for key, label in (("total", "tests"), ("passed", "passed"), ("failed", "failed"), ("skipped", "skipped"), ("suites", "suites")) if key in run)
        runs.append('<tr><td><b>' + esc(run.get("name", "未命名")) + '</b><p>' + esc(stats) + '</p></td><td>' + badge(run.get("status", "NOT RUN")) + '</td><td>' + link(run.get("artifact"), "日志 / xcresult", root, output_parent) + '<p>' + esc(run.get("notes", "")) + '</p>' + ('<code class="command">' + esc(run["command"]) + '</code>' if run.get("command") else "") + '</td></tr>')
    run_table = '<table><thead><tr><th>最新执行批次</th><th>结果</th><th>证据与边界</th></tr></thead><tbody>' + "".join(runs) + '</tbody></table>' if runs else '<p class="empty">最新执行批次尚未填入，不能把历史结果移作最终结果。</p>'
    config_rows = "".join('<tr><td>' + esc(check["id"]) + '</td><td>' + badge(check["status"]) + '</td><td>' + esc(check["observed"]) + '</td></tr>' for check in config.get("checks", []))
    config_table = '<p>' + badge(config.get("status", "NOT RUN")) + ' · ' + link(str(WORKFLOW / "ios-config-check.json"), "配置检查 JSON", root, output_parent) + '</p><table><thead><tr><th>检查项</th><th>结果</th><th>实测事实</th></tr></thead><tbody>' + config_rows + '</tbody></table>' if config else '<p class="empty">未找到配置检查 JSON。</p>'
    environment_rows = "".join('<div><dt>' + esc(key) + '</dt><dd>' + esc(value) + '</dd></div>' for key, value in summary.get("environment", {}).items())
    environment = '<dl class="environment">' + environment_rows + '</dl>' if environment_rows else '<p class="muted">最终环境与命令尚未提供。</p>'
    history = []
    for failure in summary.get("historicalFailures", []):
        history.append('<article class="history-item"><h3>' + esc(failure.get("stage", "历史失败")) + '</h3><p><b>原始结果：</b>' + esc(failure.get("observed", "")) + '</p><p><b>处理：</b>' + esc(failure.get("fix", "")) + '</p><p>' + link(failure.get("retestArtifact"), "对应复跑证据", root, output_parent) + '</p></article>')
    history_html = "".join(history) if history else '<p class="muted">最终 summary 尚未填写历史修复记录；此处不覆盖或删除原始日志。</p>'
    artifacts = list(summary.get("artifacts", []))
    artifacts += [{"name": "模板 " + Path(item["path"]).name, "path": item["path"] if Path(item["path"]).is_absolute() else None, "sha256": item.get("sha256"), "size": item.get("size"), "notes": "真实模板下载字节"} for item in template.get("files", [])]
    artifact_rows = "".join('<tr><td>' + link(item.get("path"), item.get("name", "产物"), root, output_parent) + '<p>' + esc(item.get("notes", "")) + '</p></td><td>' + esc(item.get("size", "未提供")) + '</td><td><code class="hash">' + esc(item.get("sha256", "未提供")) + '</code></td></tr>' for item in artifacts)
    artifact_table = '<table><thead><tr><th>文件 / 产物</th><th>字节数</th><th>SHA-256</th></tr></thead><tbody>' + artifact_rows + '</tbody></table>' if artifacts else '<p class="muted">尚未提供产物指纹。</p>'
    source = summary.get("source", {})
    source_html = '<p>原生 Git HEAD：<code>' + esc(source.get("nativeHead", "未提供")) + '</code><br>模板 Git HEAD：<code>' + esc(source.get("templateHead", template.get("source_head", "未提供"))) + '</code></p>'
    fingerprints = source.get("fingerprints", [])
    if fingerprints:
        source_html += '<details><summary>本轮源码指纹（含未提交修改）</summary><table><thead><tr><th>文件</th><th>SHA-256</th></tr></thead><tbody>' + "".join('<tr><td>' + link(item.get("path"), item.get("path"), root, output_parent) + '</td><td><code class="hash">' + esc(item.get("sha256")) + '</code></td></tr>' for item in fingerprints) + '</tbody></table></details>'
    screenshot_html = "".join('<figure><a href="' + esc(os.path.relpath(Path(item["path"]) if Path(item["path"]).is_absolute() else root / item["path"], output_parent)) + '"><img loading="lazy" alt="' + esc(item.get("caption", "本轮截图")) + '" src="' + esc(os.path.relpath(Path(item["path"]) if Path(item["path"]).is_absolute() else root / item["path"], output_parent)) + '"></a><figcaption>' + esc(item.get("caption", "本轮截图")) + '</figcaption></figure>' for item in summary.get("screenshots", []))
    remaining = item_list(summary.get("remaining")) or ["等待最终测试批次与逐用例执行映射。"]
    remaining += ["iOS 14 实机/runtime 未运行；iOS 18.1 的模拟器证据不能替代。", "相机、通知、定位、生物识别等真实硬件/权限、系统后台、低磁盘未因单测通过而被证明。", "本轮没有整体 FPS、峰值内存、长时间泄漏或所有 146 个能力方法的完整实测结论。"]
    layer_html = "".join('<tr><td><b>' + esc(layer) + '</b></td><td>' + esc(description) + '</td></tr>' for layer, description in EVIDENCE_LAYERS)
    notice = '<div class="callout ' + ('ready' if final else 'pending') + '"><b>' + ('已生成本阶段报告' if final else '报告草稿 · 验证尚未完成') + '</b><p>' + esc(detail) + '</p><p>' + ('允许继续 Android 实施：是。未覆盖项仍按下文保留。' if conclusion.get("iosGateReady") else 'Android 门禁尚未声明通过；不能据这份草稿开始 Android 生产修改。') + '</p></div>'
    timestamp = summary.get("generatedAt", datetime.now(timezone.utc).isoformat())
    implementation_html = '<h3>本轮实施要点</h3>' + list_html(summary.get("implementationNotes")) if summary.get("implementationNotes") else ""
    cross_stage_html = "".join('<div class="callout pending"><b>' + esc(item.get("name", "跨阶段检查")) + '</b><p>原始结果：' + esc(item.get("counts", "")) + '。' + esc(item.get("observed", "")) + '</p><p>' + link(item.get("artifact"), "完整检查日志", root, output_parent) + '</p></div>' for item in summary.get("crossStageChecks", []))
    return '''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>iOS 原生基座 · 测试报告</title><style>
:root{color-scheme:light;--ink:#163045;--muted:#5d7181;--line:#dce5eb;--paper:#fff;--bg:#f3f7fa;--green:#087a52;--red:#b82735;--amber:#9c6505;--blue:#315b8b}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.7 -apple-system,BlinkMacSystemFont,"PingFang SC","Microsoft YaHei",sans-serif}a{color:#235c9a;text-decoration:none;overflow-wrap:anywhere}a:hover{text-decoration:underline}header{background:#112b40;color:#f9fcff;padding:52px max(24px,calc((100vw - 1180px)/2)) 38px}header h1{font-size:clamp(30px,4vw,48px);letter-spacing:-1px;line-height:1.3;margin:10px 0 18px}.eyebrow{font-size:12px;letter-spacing:1.2px;font-weight:800;color:#3c7a8c}header .eyebrow{color:#80cfbf}.lead{max-width:890px;color:#cfdee8;font-size:18px}.meta{font-size:13px;color:#a5bdcf}nav{position:sticky;top:0;z-index:3;background:#ffffffef;border-bottom:1px solid var(--line);backdrop-filter:blur(12px);padding:13px 24px;display:flex;gap:24px;justify-content:center;flex-wrap:wrap}nav a{font-size:14px;font-weight:700}main{max-width:1228px;margin:auto;padding:24px}section{scroll-margin-top:95px;margin:0 0 28px;background:var(--paper);border:1px solid var(--line);border-radius:18px;padding:28px;box-shadow:0 5px 25px #17324704}h2{font-size:25px;line-height:1.4;margin:0 0 18px}h3{font-size:19px;margin:8px 0}p{margin:8px 0 14px}.muted,.small,.layer{color:var(--muted)}.small,.layer{font-size:13px}.layer{margin:8px 0 0;max-width:240px}.callout{border-left:5px solid #d49b35;border-radius:10px;background:#fff8e9;padding:16px 20px;margin:14px 0 24px}.callout.ready{border-color:#12956b;background:#edf9f3}.callout p{margin-bottom:2px}.metrics{display:grid;grid-template-columns:repeat(4,1fr);gap:16px}.metric{border:1px solid var(--line);border-radius:12px;padding:18px 22px;background:#f9fbfd}.metric strong{font-size:40px;line-height:1.2;display:block}.metric span{font-size:13px;color:var(--muted)}.metric.pass strong{color:var(--green)}.metric.fail strong{color:var(--red)}.metric.blocked strong{color:var(--amber)}.scope-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:16px}.scope-card{background:#f7fafc;border:1px solid var(--line);border-radius:12px;padding:20px}.scope-card .owner{color:#246178;font-size:14px;font-weight:700}.scope-card p{font-size:14px}.badge{display:inline-flex;border-radius:6px;padding:3px 9px;font-weight:800;font-size:12px;white-space:nowrap}.badge.pass{background:#e6f6ed;color:var(--green)}.badge.fail{background:#ffebee;color:var(--red)}.badge.blocked{background:#fff1d4;color:var(--amber)}.badge.not-run{background:#eaf0f5;color:#5a6d7c}.table-scroll{overflow-x:auto}table{border-collapse:collapse;width:100%;font-size:14px;margin:16px 0}th{text-align:left;background:#f0f5f8;border-bottom:2px solid var(--line);padding:12px}td{vertical-align:top;border-bottom:1px solid var(--line);padding:14px 12px}td p{margin:3px 0 9px}.case-table td:first-child{width:21%}.case-table td:nth-child(2){width:10%}.observed{font-size:15px}details{background:#f8fbfd;border:1px solid #e4edf3;border-radius:8px;padding:10px 13px;margin-top:12px}summary{cursor:pointer;color:#315b75;font-weight:600}dl{margin:14px 0 0}dt{font-weight:800;font-size:13px;color:#3c677d}dd{margin:3px 0 14px}dd p{margin:3px 0}.evidence{margin:5px 0;padding-left:20px}li{margin:6px 0}code{font:12px/1.65 ui-monospace,SFMono-Regular,Menlo,monospace;color:#385b76;overflow-wrap:anywhere}.command{display:block;white-space:pre-wrap;background:#edf4f8;padding:8px 10px;margin-top:8px;border-radius:5px}.hash{font-size:11px;word-break:break-all}.filters{display:flex;gap:8px;flex-wrap:wrap;margin:15px 0;align-items:center}.filters button{border:1px solid var(--line);border-radius:7px;background:#fff;padding:8px 13px;color:var(--ink);cursor:pointer}.filters button.active{background:#163a55;color:#fff}.filters input{min-width:220px;flex:1;border:1px solid var(--line);border-radius:7px;padding:10px 12px;font:inherit;font-size:14px}.environment{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}.environment>div{padding:12px 15px;border-radius:8px;background:#f5f8fb;overflow-wrap:anywhere}.environment dd{margin:4px 0;font-size:14px}.history-item{border-left:3px solid #b9cfdb;padding:2px 0 2px 20px;margin:20px 0}.empty{padding:18px;background:#f7f9fc;color:var(--muted);border-radius:8px}.screenshots{display:flex;gap:22px;flex-wrap:wrap}.screenshots figure{margin:0;max-width:280px}.screenshots img{max-width:100%;height:auto;border:1px solid var(--line);border-radius:15px}.screenshots figcaption{font-size:13px;color:var(--muted);margin-top:8px}.exclusions{display:flex;gap:8px;flex-wrap:wrap}.exclusions span{font-size:13px;background:#eef3f6;border-radius:20px;padding:5px 13px}footer{max-width:1180px;margin:0 auto;padding:0 24px 38px;color:var(--muted);font-size:13px}@media(max-width:850px){.scope-grid{grid-template-columns:1fr 1fr}.environment{grid-template-columns:1fr 1fr}header{padding:32px 24px}.metrics{gap:8px}.metric{padding:14px}.metric strong{font-size:32px}section{padding:20px}main{padding:16px}nav{gap:16px}}@media(max-width:580px){.scope-grid,.environment{grid-template-columns:1fr}.metrics{grid-template-columns:1fr 1fr}.case-table{min-width:760px}nav{justify-content:flex-start;font-size:13px}.scope-card{padding:16px}}@media print{nav,.filters{display:none}body{background:#fff}header{background:#fff;color:var(--ink);padding:12px}header .lead,header .meta{color:var(--muted)}main{padding:0}section{box-shadow:none;border-radius:0;break-inside:avoid}details{display:block}details>*{display:block}a{color:inherit}.table-scroll{overflow:visible}.case-table{min-width:0}}
</style></head><body><header><span class="eyebrow">LYNX NATIVE READINESS · iOS · ''' + esc(timestamp[:10]) + '''</span><h1>''' + esc(headline) + '''</h1><p class="lead">先列用例，再实施，再执行验证。36 项验收契约与实际测试方法分开计数，让通过范围、历史失败和未覆盖环境都可核对。</p><p class="meta">生成时间：''' + esc(timestamp) + ''' · 本地测试阶段 · 自绘导航 · Android 排在本报告之后</p></header><nav><a href="#overview">结论与范围</a><a href="#cases">36 项用例</a><a href="#evidence">运行证据</a><a href="#config">配置产物</a><a href="#history">失败修复</a><a href="#remaining">未覆盖项</a></nav><main><section id="overview"><h2>当前结论</h2>''' + notice + '<div class="metrics">' + cards + '''</div><p class="small">上面按 36 项契约归类，不是测试函数数量。PASS 的范围由每行“实际观察与依据”限定；缺少的真机、系统后台及系统版本子项保留在“尚未覆盖”，不能从软件通过推断设备行为。</p><div class="scope-grid">''' + "".join(group_cards) + '''</div>''' + implementation_html + '''<p>SDK 接线约束：Lynx 4.1 的 <code>LynxModuleDarwin::Destroy</code> 为空，不能仅凭 <code>clearForDestroy()</code> 假定 Swift Module 资源已释放。宿主需要注册 <code>onViewDestroy</code>，将原始 ctx 精确交给 Cap teardown；Shell Core 保持不依赖 Cap。</p><h3>本轮明确排除</h3><div class="exclusions">''' + "".join('<span>' + esc(item) + '</span>' for item in EXCLUDED) + '''</div></section><section id="cases"><h2>36 项验收用例</h2><p>展开每行可查看原始步骤、预期、实际测试名和缺口。PASS 限定为每行明确列出的 Core、Host 或 UI 软件契约；真机/硬件等扩展子项单列于“尚未覆盖”。BLOCKED 表示该项关键环境不可执行，NOT RUN 表示尚未执行。</p><div class="filters"><button type="button" class="active" data-filter="ALL">全部</button>''' + "".join('<button type="button" data-filter="' + status + '">' + status + '</button>' for status in STATUSES) + '''<input id="query" type="search" aria-label="搜索用例" placeholder="搜索编号、行为或结果"><span id="visible-count" class="small">36 项</span></div><div class="table-scroll"><table class="case-table"><thead><tr><th>编号 / 要求层级</th><th>结果</th><th>实际观察与依据</th></tr></thead><tbody>''' + "".join(rows) + '''</tbody></table></div></section><section id="evidence"><h2>实际运行与证据层级</h2>''' + environment + run_table + cross_stage_html + '<table><thead><tr><th>证据层</th><th>能证明什么</th></tr></thead><tbody>' + layer_html + '''</tbody></table><h3>真实模板与本地下载</h3><p>使用模板 HomePage、OtaEcommercePage 及 3 个 Async 产物，通过 ''' + esc(template.get("origin", "本地 loopback 地址待填")) + ''' 提供真实字节。测试中的 v1/v2 是发布元数据变化，文件字节相同；该场景不能证明两版业务代码内容变化。</p>''' + source_html + artifact_table + '<div class="screenshots">' + screenshot_html + '''</div></section><section id="config"><h2>隐私资源与宿主配置</h2><p>这里只判断资源、配置和构建产物，不从配置正确推断系统权限、审核或最低系统运行通过。</p>''' + config_table + '<div class="callout pending"><b>最低系统运行：' + esc(config.get("minimumRuntime", {}).get("status", "NOT RUN")) + '</b><p>' + esc(config.get("minimumRuntime", {}).get("reason", "未提供最低系统运行环境与结果。")) + '''</p></div></section><section id="history"><h2>失败与修复记录</h2><p>保留原始失败。修复后的结论对应新的日志或 xcresult，历史结果不计入最新通过率。</p>''' + history_html + '''</section><section id="remaining"><h2>仍未证明的范围</h2>''' + list_html(remaining) + '''<p>当前没有 commit、push 或正式发布。本阶段报告完成且核心回归修复后，才进入 Android；Android 结果会独立记录。</p></section></main><footer>生成源：scripts/native-readiness/report-ios.py · 逐用例：docs/native-readiness-v1/test-cases.md · 实际结果：.workflow/lynx-native-readiness-ios-android/results/ios-final-summary.json</footer><script>
(()=>{let filter='ALL';const query=document.querySelector('#query'),rows=[...document.querySelectorAll('.case-row')],buttons=[...document.querySelectorAll('[data-filter]')];function update(){const q=query.value.trim().toLowerCase();let count=0;for(const row of rows){const shown=(filter==='ALL'||row.dataset.status===filter)&&(!q||row.dataset.search.includes(q));row.hidden=!shown;if(shown)count++}document.querySelector('#visible-count').textContent=count+' / '+rows.length+' 项'}for(const button of buttons){button.addEventListener('click',()=>{filter=button.dataset.filter;for(const other of buttons)other.classList.toggle('active',other===button);update()})}query.addEventListener('input',update)})();
</script></body></html>'''


def md_text(value):
    return str(value if value is not None else "").replace("|", "\\|").replace("\n", " ")


def render_markdown(summary, cases, config, template):
    conclusion = summary.get("conclusion", {})
    counts = Counter(case["result"]["status"] for case in cases)
    lines = ["# iOS 原生基座测试报告", "", "状态：" + ("本阶段报告" if summary.get("final") else "草稿，验证尚未完成"), "", conclusion.get("headline", "iOS 验证尚未完成"), "", conclusion.get("detail", "未收到最终结果 JSON，不推断通过。"), "", "Android 门禁：" + ("可继续；未覆盖项保留" if conclusion.get("iosGateReady") else "尚未声明通过"), "", "## 六项归属", "", "| 范围 | 负责层 | 契约 |", "|---|---|---|"]
    lines += ["| " + " | ".join(md_text(item) for item in (title, owner, contract)) + " |" for _, title, owner, contract in GROUPS]
    lines += ["", "SDK 接线约束：Lynx 4.1 LynxModuleDarwin::Destroy 为空；clearForDestroy 不自动等于 Swift Module teardown。宿主注册 onViewDestroy，按原 ctx 释放 Cap，Shell Core 不依赖 Cap。", "", "本轮排除：" + "、".join(EXCLUDED) + "。", "", "## 验收用例状态", "", "36 项：" + "；".join(status + "=" + str(counts[status]) for status in STATUSES) + "。测试函数数量与验收项分开计数。", "", "| 编号 | 结果 | 实际观察 | 测试名 / 证据层 | 未覆盖 |", "|---|---|---|---|---|"]
    for case in cases:
        result = case["result"]
        evidence = "；".join(item if isinstance(item, str) else (item.get("layer", "未提供层级") + ": " + item.get("test", "未提供测试名") + "（" + item.get("artifact", "未提供证据文件") + "）") for item in result.get("evidence", []))
        lines.append("| " + " | ".join(md_text(value) for value in (case["id"], result["status"], result["observed"], evidence, "；".join(item_list(result.get("missing"))))) + " |")
    lines += ["", "## 最新执行批次", ""]
    lines += ["PASS 限定为逐项列明的 Core/Host/UI 软件契约；missing 栏保留真实系统、硬件与更广业务子项，不推断 Device 通过。", ""]
    lines += ["| 环境 | 实际值 |", "|---|---|"]
    lines += ["| " + md_text(key) + " | " + md_text(value) + " |" for key, value in summary.get("environment", {}).items()]
    lines += [""]
    for run in summary.get("runs", []):
        stats = "，".join(key + "=" + str(run[key]) for key in ("total", "passed", "failed", "skipped", "suites") if key in run)
        lines += ["- " + md_text(run.get("name")) + "：" + run.get("status", "NOT RUN") + "；" + stats + "。证据：" + md_text(run.get("artifact", "未提供")), ""]
        if run.get("command"):
            lines += ["```text", run["command"], "```", ""]
    if not summary.get("runs"):
        lines += ["尚未填入最新执行批次。", ""]
    lines += ["## 配置与产物", "", "配置检查：" + config.get("status", "NOT RUN") + "。详情见 results/ios-config-check.json。", "", "最低系统运行：" + config.get("minimumRuntime", {}).get("status", "NOT RUN") + "；" + config.get("minimumRuntime", {}).get("reason", "未提供") + "。", "", "模板使用 HomePage / OtaEcommercePage + Async 3；地址 " + template.get("origin", "待填") + "。v1/v2 仅发布元数据变化，字节相同，不能当成业务代码升级内容证明。", "", "## 历史失败与复跑", ""]
    for failure in summary.get("historicalFailures", []):
        lines += ["- " + failure.get("stage", "历史失败") + "：" + failure.get("observed", "") + " 处理：" + failure.get("fix", "") + " 复跑：" + failure.get("retestArtifact", "未提供"), ""]
    lines += ["## 本轮实施要点", ""]
    lines += ["- " + item for item in summary.get("implementationNotes", [])]
    lines += ["", "## 跨阶段门禁", ""]
    for item in summary.get("crossStageChecks", []):
        lines += ["- " + item.get("name", "跨阶段检查") + "：原始结果 " + item.get("counts", "") + "。" + item.get("observed", "") + " 日志：" + item.get("artifact", "未提供"), ""]
    lines += ["## 源码与产物指纹", "", "原生 HEAD：" + summary.get("source", {}).get("nativeHead", "未提供") + "。模板 HEAD：" + summary.get("source", {}).get("templateHead", "未提供") + "。", "", summary.get("source", {}).get("notes", ""), "", "| 模板产物 | size | SHA-256 |", "|---|---|---|"]
    lines += ["| " + md_text(item["path"]) + " | " + str(item.get("size", "未提供")) + " | " + md_text(item.get("sha256", "未提供")) + " |" for item in template.get("files", [])]
    lines += ["", "| 原生生产文件 | SHA-256 |", "|---|---|"]
    lines += ["| " + md_text(item["path"]) + " | " + md_text(item.get("sha256", "未提供")) + " |" for item in summary.get("source", {}).get("fingerprints", [])]
    lines += ["", "## 本轮截图", ""]
    for item in summary.get("screenshots", []):
        lines += ["![" + item.get("caption", "截图") + "](" + item["path"] + ")", "", item.get("caption", "截图"), ""]
    lines += ["## 未覆盖范围", ""]
    remaining = item_list(summary.get("remaining")) + ["iOS 14 实际运行；真机硬件/权限、系统后台、低磁盘。", "完整 146 方法、整体 FPS、峰值内存与长期泄漏不由本轮单测推断。"]
    lines += ["- " + item for item in remaining]
    lines += ["", "当前没有 commit、push 或正式发布。", ""]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--summary", type=Path)
    parser.add_argument("--html", type=Path)
    parser.add_argument("--markdown", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    summary_path = args.summary or root / WORKFLOW / "ios-final-summary.json"
    html_path = args.html or root / "docs/native-readiness-v1/ios-test-report.html"
    markdown_path = args.markdown or root / "docs/native-readiness-v1/ios-test-report.md"
    summary = read_json(summary_path, {"schemaVersion": 1, "final": False})
    cases = parse_cases(root / "docs/native-readiness-v1/test-cases.md")
    validate_summary(summary, cases)
    config = read_json(root / WORKFLOW / "ios-config-check.json", {})
    template = read_json(root / WORKFLOW / "template-artifacts.json", {})
    final_template_path = root / WORKFLOW / "template-artifacts-final.json"
    if final_template_path.exists():
        template["files"] = read_json(final_template_path, [])
    html_path.parent.mkdir(parents=True, exist_ok=True)
    markdown_path.parent.mkdir(parents=True, exist_ok=True)
    html_path.write_text(render_html(summary, cases, config, template, root, html_path.parent))
    markdown_path.write_text(render_markdown(summary, cases, config, template))
    print(json.dumps({"final": summary.get("final", False), "cases": len(cases), "statuses": dict(Counter(case["result"]["status"] for case in cases)), "html": str(html_path), "markdown": str(markdown_path)}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError) as error:
        print("报告生成失败：" + str(error), file=sys.stderr)
        sys.exit(1)
