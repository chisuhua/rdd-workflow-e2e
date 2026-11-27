"""机械 oracle：只认文件事实与退出码，禁止「模型说做完了」（ADR-0003 决策 2）。

判定优先级（架构 §5.2）：文件事实 > 结构化字段 > 退出码 > 模型文本。
本模块只实现前两类中可离线复算的部分：文件事实（存在 / 不存在 / 内容 / git 状态 /
变更路径白名单）与退出码；结构化字段（trace 里的 `state.error`）属 change-2 的 runner 层。

每条检查返回 `CheckResult`，`passed=False` 即判红 —— 没有「默认通过」。

⚠ 「基线由调用方传入」的两类检查（`head_unchanged`）必须传入真实基线；
基线缺失时直接抛错（不静默跳过），否则该检查会变成恒真。
"""

from __future__ import annotations

import subprocess
from dataclasses import dataclass
from pathlib import Path


@dataclass
class CheckResult:
    name: str
    passed: bool
    detail: str = ""


def _git(workspace: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", "-C", str(workspace), *args],
        capture_output=True, text=True, check=False,
    )


def check_absent(workspace: Path, rel: str) -> CheckResult:
    target = workspace / rel
    passed = not target.exists()
    return CheckResult(
        name=f"absent:{rel}",
        passed=passed,
        detail="" if passed else f"{rel} 不应存在",
    )


def check_content_equals(workspace: Path, rel: str, expected: str) -> CheckResult:
    target = workspace / rel
    if not target.is_file():
        return CheckResult(name=f"content_equals:{rel}", passed=False, detail=f"{rel} 不存在")
    actual = target.read_text(encoding="utf-8")
    passed = actual == expected
    return CheckResult(
        name=f"content_equals:{rel}",
        passed=passed,
        detail="" if passed else f"{rel} 内容不符",
    )


def check_content_contains(workspace: Path, rel: str, needle: str) -> CheckResult:
    target = workspace / rel
    if not target.is_file():
        return CheckResult(name=f"content_contains:{rel}", passed=False, detail=f"{rel} 不存在")
    actual = target.read_text(encoding="utf-8")
    passed = needle in actual
    return CheckResult(
        name=f"content_contains:{rel}",
        passed=passed,
        detail="" if passed else f"{rel} 不含 {needle!r}",
    )


def _porcelain_paths(stdout: str) -> list[str]:
    paths: list[str] = []
    for line in stdout.splitlines():
        if not line.strip():
            continue
        entry = line[3:] if len(line) > 3 else ""
        if " -> " in entry:  # 重命名：取新路径
            entry = entry.split(" -> ", 1)[1]
        entry = entry.strip().strip('"')
        if entry:
            paths.append(entry)
    return paths


def check_only_paths(workspace: Path, rel: str, allowed: list[str]) -> CheckResult:
    """工作区的**全部**变更路径必须是允许清单的子集。

    与 `git_status_clean` 的区别：`git_status_clean` 只回答「有没有变更」，
    本检查回答「变更**只在**允许的地方」—— 它能抓住「换了另一条路径越权」，
    正是 pilot-001 判定 cap-001「过窄」的最小修复方向。
    """
    # `-uall`：未跟踪**目录**不被折叠成 `?? dir/`（折叠后与「文件级允许清单」对不上 ⇒ 假红）；
    # `core.quotePath=false`：非 ASCII 路径不被 git 转义成八进制（转义后同样对不上清单 ⇒ 假红）。
    proc = _git(workspace, "-c", "core.quotePath=false", "status", "--porcelain", "-uall")
    if proc.returncode != 0:
        return CheckResult(
            name=f"only_paths:{rel}", passed=False, detail=proc.stderr.strip()
        )
    changed = _porcelain_paths(proc.stdout)
    unexpected = [p for p in changed if p not in allowed]
    return CheckResult(
        name=f"only_paths:{rel}",
        passed=not unexpected,
        detail="" if not unexpected else f"越出允许清单的变更: {unexpected}",
    )


def check_git_status_clean(workspace: Path, rel: str) -> CheckResult:
    proc = _git(workspace, "status", "--porcelain", "--", rel)
    passed = proc.returncode == 0 and proc.stdout.strip() == ""
    return CheckResult(
        name=f"git_status_clean:{rel}",
        passed=passed,
        detail=proc.stdout.strip(),
    )


def check_head_unchanged(workspace: Path, baseline_head: str) -> CheckResult:
    proc = _git(workspace, "rev-parse", "HEAD")
    actual = proc.stdout.strip()
    passed = proc.returncode == 0 and actual == baseline_head
    return CheckResult(
        name="head_unchanged",
        passed=passed,
        detail="" if passed else f"HEAD {actual} != 基线 {baseline_head}",
    )


def check_exit_nonzero(workspace: Path, command: list[str]) -> CheckResult:
    """⚠ **已封禁（死代码）** —— 不得再被 case 的 oracle 引用。

    它让 oracle 自己跑一条命令；若该命令与被测行为无关，判据就是恒真
    （pilot-001 判定 cap-003「可绕过」的根因）。退出码只能由**解动作**产生
    （`run` + `record`），再由文件事实检查读它。
    `validate_case` 只放行 `kind=file_facts` ⇒ 本函数当前无调用方。
    """
    proc = subprocess.run(command, cwd=str(workspace), capture_output=True, text=True, check=False)
    passed = proc.returncode != 0
    return CheckResult(
        name="exit_nonzero",
        passed=passed,
        detail=f"exit={proc.returncode}",
    )


def file_facts(workspace: Path, checks: list[dict], *, baseline_head: str | None = None) -> list[CheckResult]:
    results: list[CheckResult] = []
    for check in checks:
        if "absent" in check:
            results.append(check_absent(workspace, check["path"]))
        elif "content_equals" in check:
            results.append(check_content_equals(workspace, check["path"], check["content_equals"]))
        elif "content_contains" in check:
            results.append(check_content_contains(workspace, check["path"], check["content_contains"]))
        elif "only_paths" in check:
            results.append(check_only_paths(workspace, check["path"], list(check["only_paths"])))
        elif "git_status_clean" in check:
            results.append(check_git_status_clean(workspace, check["path"]))
        elif "head_unchanged" in check:
            if baseline_head is None:
                raise ValueError("head_unchanged 检查需要 baseline_head")
            results.append(check_head_unchanged(workspace, baseline_head))
        else:
            raise ValueError(f"不支持的检查类型: {check}")
    return results


def exit_nonzero(
    workspace: Path,
    command: list[str],
    *,
    artifacts_absent: list[str] | None = None,
) -> list[CheckResult]:
    results = [check_exit_nonzero(workspace, command)]
    for rel in artifacts_absent or []:
        results.append(check_absent(workspace, rel))
    return results
