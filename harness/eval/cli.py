"""E 层就绪资产的命令行入口：`python3 -m harness.eval.cli <command>`。

命令清单（对应 improvement 的 Capabilities）：
- `path-config` —— 归属声明 lint（阶段集合对账 + 五列非空 + 证据集可解析）+ 迁空 tripwire
- `masking` —— 遮蔽探针（从 JSON 描述读环境状态，按臂条件化断言）
- `arms-index` —— 臂索引追加（五字段）
- `eval-manifest` —— 产出 `kind=eval` manifest（14 字段）
- `audit` —— 判据审计汇总（三个率 + 冻结判定）

约定：**判红 ⇒ 退出码 1**；用法错 ⇒ 退出码 2。
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from . import arms_index as arms_index_mod
from . import audit as audit_mod
from . import masking as masking_mod
from . import path_config as path_config_mod
from . import taskset as taskset_mod

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_DECL = REPO_ROOT / "harness" / "path-config.yaml"
DEFAULT_CASES = REPO_ROOT / "harness" / "criteria" / "cases"


def _cmd_path_config(args: argparse.Namespace) -> int:
    decl = Path(args.declaration)
    result = path_config_mod.check(decl, cases_dir=DEFAULT_CASES)
    verdict = path_config_mod.tripwire(result.rows)
    print(f"声明: {decl}")
    print(f"path_config_version: {path_config_mod.version(decl)}")
    print(f"阶段: {result.stages}")
    for error in result.errors:
        print(f"✗ {error}")
    print(f"迁空 tripwire: {'触发' if verdict.triggered else '未触发'} —— {verdict.reason}")
    if not result.ok:
        return 1
    if verdict.triggered:
        return 1
    print("✓ 归属声明校验通过")
    return 0


def _cmd_masking(args: argparse.Namespace) -> int:
    payload = json.loads(Path(args.env).read_text(encoding="utf-8"))
    env = masking_mod.Environment(
        skill_names=tuple(payload.get("skill_names", ())),
        rdd_call_success_count=int(payload.get("rdd_call_success_count", 0)),
        unknown_skill_probe_result=str(payload.get("unknown_skill_probe_result", "")),
        rddf_on_path=bool(payload.get("rddf_on_path", False)),
    )
    report = masking_mod.probe(env, arm=args.arm)
    print(f"臂: {args.arm}")
    for violation in report.violations:
        print(f"✗ {violation}")
    if report.ok:
        print("✓ 遮蔽状态符合该臂的断言方向")
        return 0
    return 1


def _cmd_arms_index(args: argparse.Namespace) -> int:
    index = arms_index_mod.Index(Path(args.path))
    row = index.append(
        session_id=args.session_id,
        run_id=args.run_id,
        arm=args.arm,
        path_switches=list(args.path_switch or []),
        prompt_hash=args.prompt_hash,
    )
    print(json.dumps(row, ensure_ascii=False))
    return 0


def _cmd_eval_manifest(args: argparse.Namespace) -> int:
    from harness import manifest as manifest_mod

    decl = Path(args.path_config)
    arms = Path(args.arms_index) if args.arms_index else None
    manifest = manifest_mod.build_eval(
        opencode_sha=args.opencode_sha,
        product_sha=args.product_sha,
        model_id=args.model_id,
        prompt_version=args.prompt_version,
        criteria_version=args.criteria_version,
        taskset_version=args.taskset_version,
        snapshot_sha=args.snapshot_sha,
        path_config_version=path_config_mod.version(decl),
        arms_index_sha256=(
            path_config_mod.sha256_file(arms) if arms and arms.is_file() else ""
        ),
        budget_usd=float(args.budget_usd),
        cost_usd_actual=float(args.cost_usd_actual),
    )
    out = Path(args.out)
    manifest_mod.write(out, manifest)
    print(f"✓ manifest 写入 {out}（{len(manifest)} 字段）")
    return 0


def _cmd_audit(args: argparse.Namespace) -> int:
    payload = json.loads(Path(args.findings).read_text(encoding="utf-8"))
    # 两种形态都接受：纯 finding 列表，或审计记录对象（{"findings": [...]}）。
    findings = payload["findings"] if isinstance(payload, dict) else payload
    report = audit_mod.summarize(
        findings,
        audited_total=int(args.audited_total),
        sampling_method=args.sampling_method,
        legit_attempts=int(args.legit_attempts),
        legit_failures=int(args.legit_failures),
    )
    print(f"judge_defect_rate: {report.judge_defect_rate}")
    print(f"audit_coverage: {report.audit_coverage}")
    print(f"false_negative_rate: {report.false_negative_rate}")
    print(f"sampling_method: {report.sampling_method}")
    print(f"freeze_expansion: {report.freeze_expansion}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="harness.eval.cli")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("path-config", help="归属声明 lint + 迁空 tripwire")
    p.add_argument("--declaration", default=str(DEFAULT_DECL))
    p.set_defaults(func=_cmd_path_config)

    p = sub.add_parser("masking", help="遮蔽探针")
    p.add_argument("--env", required=True, help="环境状态 JSON 文件")
    p.add_argument("--arm", required=True, choices=["W0", "W1", "W2"])
    p.set_defaults(func=_cmd_masking)

    p = sub.add_parser("arms-index", help="臂索引追加")
    p.add_argument("--path", required=True)
    p.add_argument("--session-id", required=True)
    p.add_argument("--run-id", required=True)
    p.add_argument("--arm", required=True, choices=["W0", "W1", "W2"])
    p.add_argument("--prompt-hash", required=True)
    p.add_argument("--path-switch", action="append")
    p.set_defaults(func=_cmd_arms_index)

    p = sub.add_parser("eval-manifest", help="产出 kind=eval manifest")
    p.add_argument("--out", required=True)
    p.add_argument("--path-config", default=str(DEFAULT_DECL))
    p.add_argument("--arms-index", default="")
    p.add_argument("--opencode-sha", required=True)
    p.add_argument("--product-sha", required=True)
    p.add_argument("--model-id", required=True)
    p.add_argument("--prompt-version", required=True)
    p.add_argument("--criteria-version", required=True)
    p.add_argument("--taskset-version", required=True)
    p.add_argument("--snapshot-sha", required=True)
    p.add_argument("--budget-usd", default="0.0")
    p.add_argument("--cost-usd-actual", default="0.0")
    p.set_defaults(func=_cmd_eval_manifest)

    p = sub.add_parser("audit", help="判据审计汇总")
    p.add_argument("--findings", required=True)
    p.add_argument("--audited-total", required=True)
    p.add_argument("--sampling-method", required=True)
    p.add_argument("--legit-attempts", default="0")
    p.add_argument("--legit-failures", default="0")
    p.set_defaults(func=_cmd_audit)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"✗ {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
