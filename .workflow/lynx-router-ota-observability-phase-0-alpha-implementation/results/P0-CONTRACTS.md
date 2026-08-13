# P0-CONTRACTS 结果

## 已完成

- `schemas/telemetry/event-envelope.schema.json`：Wire Schema `3.0.0`。
- `schemas/telemetry/remote-config.schema.json`：Remote Config `1.0.0`。
- `schemas/telemetry/delivery-privacy.schema.json`：Batch ACK 与 deletion tombstone。
- `fixtures/telemetry/valid` / `invalid`：16 个 golden fixture。
- `schemas/telemetry/validate_fixtures.py`：无第三方依赖的本地子集校验器。
- `docs/telemetry/README.md`：字段、状态、隐私、恢复和阶段边界说明。

## 验证

```text
python3 schemas/telemetry/validate_fixtures.py  -> 16 passed, 0 failed
python3 -m py_compile schemas/telemetry/validate_fixtures.py -> PASS
git diff --check -> PASS
```

## 限制

校验器只覆盖仓库 fixture 所需的 JSON Schema 子集，不能替代服务端正式校验器；本阶段没有网络上传、磁盘队列或真实 ACK。
