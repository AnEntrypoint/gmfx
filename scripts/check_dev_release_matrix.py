from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

ARM_RUNNER = "ubuntu-24.04-arm"
X86_RUNNERS = {"ubuntu-latest", "ubuntu-24.04", "ubuntu-22.04"}
MATRIX_RUNNER = "${{ matrix.runner }}"
TARGET_PATTERN = re.compile(r"-Dtarget=(\S+)")


def runner_arch(runner: str) -> str | None:
    if runner == ARM_RUNNER:
        return "aarch64"
    if runner in X86_RUNNERS:
        return "x86_64"
    return None


def entry_problems(job: str, entry: dict) -> list[str]:
    name = entry.get("name", "")
    if not name.startswith("linux-"):
        return []
    expected = name.removeprefix("linux-")
    runner = entry.get("runner", "")
    arch = runner_arch(runner)
    if arch is None:
        return [f"{job}: {name} runs on {runner!r}, which is not a known Linux runner"]
    problems = []
    if arch != expected:
        problems.append(f"{job}: {name} runs on {runner} ({arch}), expected {expected}")
    target = TARGET_PATTERN.search(entry.get("zig_args", ""))
    if target and not target.group(1).startswith(f"{arch}-linux"):
        problems.append(f"{job}: {name} builds {target.group(1)} on {runner}, which is a cross build")
    return problems


def check(path: Path) -> list[str]:
    workflow = yaml.safe_load(path.read_text())
    problems = []
    linux_entries = 0
    for job, body in workflow.get("jobs", {}).items():
        include = body.get("strategy", {}).get("matrix", {}).get("include")
        if not include:
            continue
        if any(str(entry.get("name", "")).startswith("linux-") for entry in include) and body.get("runs-on") != MATRIX_RUNNER:
            problems.append(f"{job}: runs-on is {body.get('runs-on')!r}, expected {MATRIX_RUNNER!r}")
        for entry in include:
            if str(entry.get("name", "")).startswith("linux-"):
                linux_entries += 1
            problems.extend(entry_problems(job, entry))
    if linux_entries == 0:
        problems.append(f"{path}: no linux-* matrix entries found")
    return problems


def main(argv: list[str]) -> int:
    path = Path(argv[1]) if len(argv) > 1 else Path(".github/workflows/dev-release.yml")
    problems = check(path)
    for problem in problems:
        print(f"MISMATCH {problem}")
    if not problems:
        print(f"MATRIX_OK {path}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
