#!/usr/bin/env python3
"""使用 Python 标准库校验 Telemetry Schema 与 fixtures。

项目不依赖 jsonschema 等第三方包。这个校验器覆盖本目录 Schema 实际使用的
JSON Schema 子集：$ref、oneOf、type、const、enum、required、properties、
additionalProperties、items、pattern、长度/数值边界。它不是通用 JSON
Schema 实现，但足以在 CI 中阻止本目录契约和共享 fixtures 漂移。
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


class ValidationError(Exception):
    """带路径的单条校验错误。"""


def _type_matches(value: Any, expected: str) -> bool:
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "string":
        return isinstance(value, str)
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if expected == "null":
        return value is None
    raise ValidationError(f"不支持的 JSON Schema type: {expected}")


def _resolve_ref(root: dict[str, Any], ref: str) -> dict[str, Any]:
    if not ref.startswith("#/"):
        raise ValidationError(f"只允许解析本地 $ref: {ref}")
    value: Any = root
    for part in ref[2:].split("/"):
        value = value[part.replace("~1", "/").replace("~0", "~")]
    if not isinstance(value, dict):
        raise ValidationError(f"$ref 目标不是对象: {ref}")
    return value


def validate(value: Any, schema: dict[str, Any], root: dict[str, Any], path: str = "$", seen: set[tuple[int, str]] | None = None) -> None:
    """校验项目所需的 JSON Schema 子集。"""
    if seen is None:
        seen = set()
    if "$ref" in schema:
        marker = (id(value), schema["$ref"])
        if marker in seen:
            return
        seen.add(marker)
        validate(value, _resolve_ref(root, schema["$ref"]), root, path, seen)
        return
    if "oneOf" in schema:
        errors: list[str] = []
        matches = 0
        for candidate in schema["oneOf"]:
            try:
                validate(value, candidate, root, path, set(seen))
            except ValidationError as error:
                errors.append(str(error))
            else:
                matches += 1
        if matches != 1:
            detail = "; ".join(errors[:2])
            raise ValidationError(f"{path}: oneOf 命中 {matches} 个分支（{detail}）")
        return
    if "anyOf" in schema:
        for candidate in schema["anyOf"]:
            try:
                validate(value, candidate, root, path, set(seen))
            except ValidationError:
                continue
            return
        raise ValidationError(f"{path}: anyOf 没有命中分支")

    if "const" in schema and value != schema["const"]:
        raise ValidationError(f"{path}: 应为常量 {schema['const']!r}，实际为 {value!r}")
    if "enum" in schema and value not in schema["enum"]:
        raise ValidationError(f"{path}: 不在枚举 {schema['enum']!r} 中")

    expected = schema.get("type")
    if expected is not None:
        expected_types = expected if isinstance(expected, list) else [expected]
        if not any(_type_matches(value, item) for item in expected_types):
            raise ValidationError(f"{path}: 类型不匹配，期望 {expected_types}，实际 {type(value).__name__}")

    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            raise ValidationError(f"{path}: 字符串长度过短")
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            raise ValidationError(f"{path}: 字符串长度过长")
        if "pattern" in schema and re.search(schema["pattern"], value) is None:
            raise ValidationError(f"{path}: 不匹配 pattern {schema['pattern']!r}")
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            raise ValidationError(f"{path}: 小于 minimum")
        if "maximum" in schema and value > schema["maximum"]:
            raise ValidationError(f"{path}: 大于 maximum")
    if isinstance(value, (dict, list)):
        if "minItems" in schema and len(value) < schema["minItems"]:
            raise ValidationError(f"{path}: 数组元素过少")
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            raise ValidationError(f"{path}: 数组元素过多")
    if isinstance(value, dict):
        if "minProperties" in schema and len(value) < schema["minProperties"]:
            raise ValidationError(f"{path}: 属性过少")
        if "maxProperties" in schema and len(value) > schema["maxProperties"]:
            raise ValidationError(f"{path}: 属性过多")
        for key in schema.get("required", []):
            if key not in value:
                raise ValidationError(f"{path}: 缺少必填属性 {key!r}")
        properties = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            unknown = set(value) - set(properties)
            if unknown:
                raise ValidationError(f"{path}: 存在未声明属性 {sorted(unknown)!r}")
        for key, child in properties.items():
            if key in value:
                validate(value[key], child, root, f"{path}.{key}", seen)
    if isinstance(value, list) and "items" in schema:
        for index, item in enumerate(value):
            validate(item, schema["items"], root, f"{path}[{index}]", seen)


def schema_for_fixture(path: Path, schemas_dir: Path) -> dict[str, Any]:
    if path.name == "remote-config.json" or path.name == "remote-config-fail-closed.json":
        filename = "remote-config.schema.json"
    elif "tombstone" in path.name or "batch-ack" in path.name:
        filename = "delivery-privacy.schema.json"
    else:
        filename = "event-envelope.schema.json"
    with (schemas_dir / filename).open(encoding="utf-8") as stream:
        return json.load(stream)


def validate_group(directory: Path, schemas_dir: Path, should_pass: bool) -> tuple[int, int]:
    passed = failed = 0
    for fixture in sorted(directory.glob("*.json")):
        try:
            with fixture.open(encoding="utf-8") as stream:
                value = json.load(stream)
            schema = schema_for_fixture(fixture, schemas_dir)
            validate(value, schema, schema)
        except (OSError, json.JSONDecodeError, ValidationError) as error:
            actual_pass = False
            message = str(error)
        else:
            actual_pass = True
            message = ""
        if actual_pass == should_pass:
            passed += 1
            verdict = "PASS"
        else:
            failed += 1
            verdict = "FAIL"
        suffix = f" ({message})" if message and verdict == "FAIL" else ""
        print(f"{verdict} {fixture.relative_to(directory.parent.parent)} expected={'valid' if should_pass else 'invalid'}{suffix}")
    return passed, failed


def main() -> int:
    parser = argparse.ArgumentParser(description="校验 Telemetry Schema fixtures")
    parser.add_argument("--fixtures-dir", type=Path, default=Path(__file__).parents[2] / "fixtures" / "telemetry")
    parser.add_argument("--schemas-dir", type=Path, default=Path(__file__).parent)
    args = parser.parse_args()
    valid = args.fixtures_dir / "valid"
    invalid = args.fixtures_dir / "invalid"
    if not valid.is_dir() or not invalid.is_dir():
        print("缺少 fixtures/valid 或 fixtures/invalid", file=sys.stderr)
        return 2
    ok, bad = validate_group(valid, args.schemas_dir, True)
    valid_ok, valid_bad = validate_group(invalid, args.schemas_dir, False)
    ok += valid_ok
    bad += valid_bad
    print(f"summary: {ok} passed, {bad} failed")
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
