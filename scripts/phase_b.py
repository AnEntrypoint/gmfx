#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import time

REPO = pathlib.Path(__file__).resolve().parents[1]
ZIG = os.environ.get("FX_ZIG", "zig")
PASSES = REPO / ".git" / "phase-b-passes.jsonl"
LOGS = pathlib.Path(os.environ.get("FX_PHASE_B_LOGS", "/tmp/fx-phase-b"))
UNIT_AREAS = ("core", "ui", "tools", "mcp", "acp", "gateway", "usage")
BOUNDARY_CHECKS = (
    "check-agents-boundary.sh",
    "check-compactor-boundary.sh",
    "check-indexer-boundary.sh",
    "check-recovery-boundary.sh",
    "check-superagent-boundary.sh",
)
SOURCE_PATHS = ("src", "build.zig", "build.zig.zon")
E2E_TIMEOUT_SECONDS = 1500
COUNT_LINE = re.compile(r"^\s*(\d+) (pass|fail|skip)\b", re.M)


def sha256_of_files(paths):
    digest = hashlib.sha256()
    for path in sorted(paths):
        digest.update(str(path.relative_to(REPO)).encode())
        digest.update(b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def tracked_files(*roots):
    listed = subprocess.run(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", *roots],
        cwd=REPO, check=True, capture_output=True,
    ).stdout.split(b"\0")
    return [REPO / name.decode() for name in listed if name and (REPO / name.decode()).is_file()]


def source_key():
    return sha256_of_files(tracked_files(*SOURCE_PATHS))


IMPORT_LINE = re.compile(r"""(?:from|import)\s+["'](\.{1,2}/[^"']+)["']""")


def import_closure(entry):
    seen = set()
    pending = [entry]
    while pending:
        current = pending.pop()
        if current in seen or not current.is_file():
            continue
        seen.add(current)
        for target in IMPORT_LINE.findall(current.read_text(errors="replace")):
            base = (current.parent / target).resolve()
            for candidate in (base, base.with_suffix(".ts"), base.parent / (base.name + ".ts"), base / "index.ts"):
                if candidate.is_file():
                    pending.append(candidate)
                    break
    return seen


def binary_key():
    binary = REPO / "zig-out" / "bin" / "fx"
    return hashlib.sha256(binary.read_bytes()).hexdigest() if binary.exists() else "absent"


def excluded_e2e_files():
    manifest = json.loads((REPO / "scripts" / "pgso" / "corpus.json").read_text())
    exclusions = manifest.get("intentional_exclusions", {})
    names = exclusions.keys() if isinstance(exclusions, dict) else [entry.get("test_file") or entry.get("file") for entry in exclusions]
    return set(names) - {"ci-shards.test.ts", "tui-command-permissions.test.ts"}


def e2e_files():
    excluded = excluded_e2e_files()
    return sorted(path.name for path in (REPO / "tests" / "e2e").glob("*.test.ts") if path.name not in excluded)


def groups():
    source = source_key()
    listed = [
        ("build-native", source, [ZIG, "build"]),
        ("build-wasm", source, [ZIG, "build", "fx-term-wasm", "-Dwasm-surface=term"]),
    ]
    for area in UNIT_AREAS:
        listed.append((f"unit-{area}", source, [ZIG, "build", "test", f"-Dtest-area={area}", "--summary", "all"]))
    for check in BOUNDARY_CHECKS:
        listed.append((f"check-{check}", source, [f"./scripts/{check}"]))
    listed.append(("sdk-term", "sdk", ["npm", "--prefix", "sdk/node", "run", "test:term"]))
    listed.append(("pgso-corpus", "per-run", [sys.executable, "-B", "-m", "unittest", "scripts.pgso.tests.test_corpus"]))
    for name in e2e_files():
        listed.append((f"e2e-{name[:-len('.test.ts')]}", None, ["bun", "test", f"tests/e2e/{name}"]))
    return listed


def e2e_key(name, binary):
    test_file = REPO / "tests" / "e2e" / f"{name}.test.ts"
    return hashlib.sha256(f"{binary}:{sha256_of_files(import_closure(test_file))}".encode()).hexdigest()


def recorded_passes():
    if not PASSES.exists():
        return {}
    passed = {}
    for line in PASSES.read_text().splitlines():
        entry = json.loads(line)
        passed[(entry["group"], entry["key"])] = entry.get("detail", "")
    return passed


def record_pass(group, key, seconds, detail):
    with PASSES.open("a") as out:
        out.write(json.dumps({"group": group, "key": key, "seconds": seconds, "detail": detail, "at": int(time.time())}) + "\n")


def counts(text):
    found = {kind: int(number) for number, kind in COUNT_LINE.findall(text)}
    if found:
        return " ".join(f"{found[kind]} {kind}" for kind in ("pass", "skip", "fail") if kind in found)
    unit = re.findall(r"run test [0-9a-z, ]*\(\d+ total\)", text)
    return unit[-1] if unit else ""


def run_group(group, command):
    LOGS.mkdir(parents=True, exist_ok=True)
    log_path = LOGS / f"{group}.log"
    started = time.time()
    timeout = E2E_TIMEOUT_SECONDS if group.startswith("e2e-") else None
    with log_path.open("w") as log:
        try:
            exit_code = subprocess.run(command, cwd=REPO, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, timeout=timeout).returncode
        except subprocess.TimeoutExpired:
            exit_code = 124
    return exit_code, round(time.time() - started), counts(log_path.read_text(errors="replace")), log_path


def main():
    parser = argparse.ArgumentParser(description="Run every Phase B group once per tree; a cut run resumes at the first group not yet passed on the same inputs.")
    parser.add_argument("--only", action="append", default=[], help="run only groups whose name contains this text (repeatable)")
    parser.add_argument("--list", action="store_true", help="print each group with pass or due and exit")
    parser.add_argument("--keep-going", action="store_true", help="run later groups after a failure")
    args = parser.parse_args()

    passed = recorded_passes()
    failed = []
    binary = None
    for group, key, command in groups():
        if args.only and not any(text in group for text in args.only):
            continue
        if group.startswith("e2e-"):
            if binary is None:
                binary = binary_key()
            key = e2e_key(group[len("e2e-"):], binary)
        elif key == "sdk":
            key = source_key() + ":" + sha256_of_files(tracked_files("sdk"))
        elif key == "per-run":
            key = sha256_of_files(tracked_files("scripts/pgso", "tests/e2e/ci-shard-weights.json")) + ":" + ",".join(e2e_files())
        built_binary_replaced = group == "build-native" and passed.get((group, key)) != binary_key()
        if (group, key) in passed and not built_binary_replaced:
            print(f"PHASE-B {group}: pass (recorded for these inputs)", flush=True)
            continue
        if args.list:
            print(f"PHASE-B {group}: due", flush=True)
            continue
        exit_code, seconds, detail, log_path = run_group(group, command)
        if exit_code == 0:
            if group == "build-native":
                detail = binary_key()
            record_pass(group, key, seconds, detail)
            print(f"PHASE-B {group}: pass {seconds}s {detail}", flush=True)
            if group == "build-native":
                binary = None
            continue
        print(f"PHASE-B {group}: FAIL exit={exit_code} {seconds}s {detail} log={log_path}", flush=True)
        failed.append(group)
        if not args.keep_going or group.startswith("build-"):
            break
    if failed:
        print(f"PHASE-B result: {len(failed)} failed: {', '.join(failed)}", flush=True)
        return 1
    if not args.list:
        print("PHASE-B result: every group passed", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
