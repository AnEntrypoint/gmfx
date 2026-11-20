#!/usr/bin/env python3
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

KAGGLE_DIRECTORY = Path(__file__).resolve().parent
BENCHMARKS_DIRECTORY = KAGGLE_DIRECTORY.parent
REPOSITORY_ROOT = BENCHMARKS_DIRECTORY.parent
RESULTS_DIRECTORY = KAGGLE_DIRECTORY / "results"
ENTRY_FILE = "fx_bench_entry.py"
RESULTS_FILE = "results.jsonl"
PYTHON_PAYLOAD = (
    KAGGLE_DIRECTORY / "bench_kernel.py",
    BENCHMARKS_DIRECTORY / "first_frame.py",
    BENCHMARKS_DIRECTORY / "long_turn_memory.py",
    BENCHMARKS_DIRECTORY / "shell_command_overhead.py",
    BENCHMARKS_DIRECTORY / "session_list_fixture.py",
)
KERNEL_STATUS = re.compile(r'has status "([^"]+)"')
KERNEL_VERSION = re.compile(r"Kernel version (\d+) successfully pushed")
ENTRY_TEMPLATE = '''import json
import os
import shutil
import subprocess
import sys
import zipfile

INPUT_ROOT = "/kaggle/input"
WORKING = "/kaggle/working"
PAYLOAD = os.path.join(WORKING, "payload")
UNZIPPED = os.path.join(WORKING, "unzipped")
RESULTS = os.path.join(WORKING, "results.jsonl")
REPEATS = __REPEATS__
EXPECTED_RUN_ID = "__RUN_ID__"


def files_under(root):
    found = {}
    for directory, _, names in os.walk(root):
        for name in names:
            found.setdefault(name, os.path.join(directory, name))
    return found


def manifests():
    return [os.path.join(directory, "manifest.json") for directory, _, names in os.walk(INPUT_ROOT) if "manifest.json" in names]


def run_id(path):
    with open(path) as handle:
        return json.load(handle).get("run_id")


candidates = manifests()
matching = [path for path in candidates if run_id(path) == EXPECTED_RUN_ID]
if not matching:
    print(json.dumps({"config": "payload", "ok": False, "note": "no manifest.json with run_id " + EXPECTED_RUN_ID + " under " + INPUT_ROOT + "; found " + repr(candidates)}))
    sys.exit(2)
source = os.path.dirname(matching[0])
available = files_under(source)
for name, path in list(available.items()):
    if name.endswith(".zip"):
        with zipfile.ZipFile(path) as archive:
            archive.extractall(os.path.join(UNZIPPED, name))
available.update(files_under(UNZIPPED) if os.path.isdir(UNZIPPED) else {})
shutil.rmtree(PAYLOAD, ignore_errors=True)
os.makedirs(PAYLOAD)
shutil.copy(matching[0], os.path.join(PAYLOAD, "manifest.json"))
with open(matching[0]) as handle:
    entries = json.load(handle)["entries"]
for entry in entries:
    target = os.path.join(PAYLOAD, entry["path"])
    os.makedirs(os.path.dirname(target), exist_ok=True)
    structured = os.path.join(source, entry["path"])
    origin = structured if os.path.isfile(structured) else available.get(os.path.basename(entry["path"]))
    if origin:
        shutil.copy(origin, target)
        if entry["path"].startswith("bin/"):
            os.chmod(target, 0o755)
shutil.rmtree(UNZIPPED, ignore_errors=True)
completed = subprocess.run([sys.executable, os.path.join(PAYLOAD, "bench_kernel.py"), "--payload", PAYLOAD, "--out", RESULTS, "--repeats", str(REPEATS)], stdout=subprocess.DEVNULL)
if os.path.isfile(RESULTS):
    with open(RESULTS) as handle:
        for line in handle:
            print(line, end="")
shutil.rmtree(PAYLOAD, ignore_errors=True)
sys.exit(completed.returncode)
'''


def file_sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def short_git_sha():
    try:
        completed = subprocess.run(["git", "-C", str(REPOSITORY_ROOT), "rev-parse", "--short", "HEAD"], capture_output=True, text=True)
    except OSError:
        return "nogit"
    return completed.stdout.strip() if completed.returncode == 0 and completed.stdout.strip() else "nogit"


def payload_plan(args):
    plan = [("fx-release", "build", Path(args.fx), "bin/fx")]
    if args.wasm:
        plan.append(("fx-term.wasm", "build", Path(args.wasm), "bin/fx-term.wasm"))
    for binary in args.bench_bin:
        plan.append((Path(binary).name, "build", Path(binary), "bin/" + Path(binary).name))
    for script in PYTHON_PAYLOAD:
        plan.append((script.name, "harness", script, script.name))
    names = [Path(relative).name for _, _, _, relative in plan]
    duplicates = sorted({name for name in names if names.count(name) > 1})
    if duplicates:
        sys.exit(f"error: payload file names must be unique, repeated: {', '.join(duplicates)}")
    missing = [str(source) for _, _, source, _ in plan if not source.is_file()]
    if missing:
        sys.exit(f"error: not a file: {', '.join(missing)}")
    return plan


def build_directories(args, root, run_id):
    payload, dataset, kernel = root / "payload", root / "dataset", root / "kernel"
    for directory in (payload, dataset, kernel):
        directory.mkdir(parents=True)
    entries = []
    for name, kind, source, relative in payload_plan(args):
        target = payload / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        target.chmod(0o755 if relative.startswith("bin/") else 0o644)
        shutil.copyfile(target, dataset / Path(relative).name)
        entries.append({"name": name, "kind": kind, "path": relative, "bytes": target.stat().st_size, "sha256": file_sha256(target)})
    manifest = {
        "run_id": run_id,
        "git": args.source_commit,
        "created_utc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "repeats": args.repeats,
        "entries": entries,
    }
    manifest_text = json.dumps(manifest, indent=2) + "\n"
    (payload / "manifest.json").write_text(manifest_text)
    (dataset / "manifest.json").write_text(manifest_text)
    (dataset / "dataset-metadata.json").write_text(json.dumps({
        "title": args.dataset.split("/", 1)[1],
        "id": args.dataset,
        "licenses": [{"name": "other"}],
    }, indent=2) + "\n")
    (kernel / "kernel-metadata.json").write_text(json.dumps({
        "id": args.kernel,
        "title": args.kernel.split("/", 1)[1],
        "code_file": ENTRY_FILE,
        "language": "python",
        "kernel_type": "script",
        "is_private": True,
        "enable_gpu": False,
        "enable_internet": False,
        "dataset_sources": [args.dataset],
        "competition_sources": [],
        "kernel_sources": [],
    }, indent=2) + "\n")
    (kernel / ENTRY_FILE).write_text(ENTRY_TEMPLATE.replace("__REPEATS__", str(args.repeats)).replace("__RUN_ID__", run_id))
    return payload, dataset, kernel, manifest


def kaggle(args, arguments, check=True):
    command = [args.kaggle] + arguments
    print("+ " + " ".join(command), flush=True)
    completed = subprocess.run(command, capture_output=True, text=True)
    output = (completed.stdout + completed.stderr).strip()
    if output:
        print(output, flush=True)
    if check and completed.returncode != 0:
        sys.exit(f"error: kaggle exited with {completed.returncode}")
    return completed.returncode, output


def bounded_wait(label, probe, interval_seconds, limit_minutes):
    started = time.monotonic()
    while True:
        outcome = probe()
        elapsed = time.monotonic() - started
        if outcome is not None:
            print(f"{label}: {outcome} after {elapsed:.0f}s", flush=True)
            return outcome
        if elapsed + interval_seconds > limit_minutes * 60:
            sys.exit(f"error: {label} did not finish within {limit_minutes:g} minutes ({elapsed:.0f}s elapsed)")
        time.sleep(interval_seconds)


def kernel_outcome(args):
    code, output = kaggle(args, ["kernels", "status", args.kernel], check=False)
    reported = KERNEL_STATUS.search(output)
    if code != 0 or reported is None:
        return None
    state = reported.group(1).lower()
    for finished in ("complete", "error", "cancel"):
        if finished in state:
            return finished
    return None


def dataset_status(args):
    code, output = kaggle(args, ["datasets", "status", args.dataset], check=False)
    return output.splitlines()[-1].strip().lower() if code == 0 and output else None


def published_run_id(args, scratch):
    shutil.rmtree(scratch, ignore_errors=True)
    scratch.mkdir(parents=True)
    code, _ = kaggle(args, ["datasets", "download", args.dataset, "-f", "manifest.json", "-p", str(scratch), "--unzip", "-o", "-q"], check=False)
    manifest = scratch / "manifest.json"
    if code != 0 or not manifest.is_file():
        return None
    try:
        return json.loads(manifest.read_text()).get("run_id")
    except ValueError:
        return None


def dataset_serves_run(args, run_id, scratch):
    if dataset_status(args) != "ready":
        return None
    return "ready" if published_run_id(args, scratch) == run_id else None


def publish_dataset(args, dataset, run_id, scratch):
    if dataset_status(args) is None:
        kaggle(args, ["datasets", "create", "-p", str(dataset), "--dir-mode", "skip"])
    else:
        kaggle(args, ["datasets", "version", "-p", str(dataset), "-m", f"fx bench payload {run_id}", "--dir-mode", "skip"])
    bounded_wait("dataset", lambda: dataset_serves_run(args, run_id, scratch), 15, args.dataset_wait_minutes)


def downloaded_metadata(args, arguments, scratch, name):
    shutil.rmtree(scratch, ignore_errors=True)
    scratch.mkdir(parents=True)
    kaggle(args, arguments + ["-p", str(scratch)])
    try:
        return json.loads((scratch / name).read_text())
    except (OSError, ValueError) as error:
        sys.exit(f"error: could not read {name} back from Kaggle: {error}")


def require_private_dataset(args, scratch):
    metadata = downloaded_metadata(args, ["datasets", "metadata", args.dataset], scratch, "dataset-metadata.json")
    if metadata.get("info", metadata).get("isPrivate") is not True:
        sys.exit(f"error: {args.dataset} is not private on Kaggle; make it private before running again")


def require_private_kernel(args, scratch):
    metadata = downloaded_metadata(args, ["kernels", "pull", args.kernel, "-m"], scratch, "kernel-metadata.json")
    if metadata.get("is_private") is not True or metadata.get("enable_internet") is not False:
        sys.exit(f"error: {args.kernel} is not a private kernel without internet on Kaggle")


def push_kernel(args, kernel):
    _, output = kaggle(args, ["kernels", "push", "-p", str(kernel), "--timeout", str(int(args.wait_minutes * 60))])
    pushed = KERNEL_VERSION.search(output)
    if pushed is None:
        sys.exit("error: kaggle kernels push did not report a new kernel version")
    return int(pushed.group(1))


def next_results_path(source_commit):
    RESULTS_DIRECTORY.mkdir(parents=True, exist_ok=True)
    prefix = f"{datetime.datetime.now(datetime.timezone.utc):%Y-%m-%d}-{source_commit}-"
    index = 1
    while (RESULTS_DIRECTORY / f"{prefix}{index}.jsonl").exists():
        index += 1
    return RESULTS_DIRECTORY / f"{prefix}{index}.jsonl"


def checked_result_lines(path, manifest, run_id):
    if not path.is_file():
        sys.exit(f"error: the kernel produced no {RESULTS_FILE} (looked at {path})")
    lines = [line for line in path.read_text().splitlines() if line.strip()]
    if not lines:
        sys.exit(f"error: {path} is empty")
    parsed = []
    for number, line in enumerate(lines, 1):
        try:
            parsed.append(json.loads(line))
        except ValueError as error:
            sys.exit(f"error: {path} line {number} is not JSON: {error}")
    expected = next(entry["sha256"] for entry in manifest["entries"] if entry["name"] == "fx-release")
    measured = next((line for line in parsed if line.get("config") == "build_size.fx-release"), None)
    if measured is None or expected not in str(measured.get("note")):
        sys.exit(f"error: the kernel did not measure the fx binary this run uploaded (sha256 {expected})")
    payload = next((line for line in parsed if line.get("config") == "payload"), None)
    if payload is None or payload.get("run_id") != run_id:
        sys.exit(f"error: the downloaded results are not from run {run_id}: {payload}")
    return lines


def main():
    parser = argparse.ArgumentParser(description="Build the fx benchmark payload and run it in one private Kaggle kernel.")
    parser.add_argument("--fx", required=True, help="ReleaseSafe fx binary to measure")
    parser.add_argument("--wasm", help="fx-term.wasm, measured for size")
    parser.add_argument("--bench-bin", action="append", default=[], help="headless benchmark executable (repeatable)")
    parser.add_argument("--repeats", type=int, default=30)
    parser.add_argument("--source-commit", default=short_git_sha(), help="short commit the binaries were built from (default: HEAD)")
    parser.add_argument("--dataset", default="heclgang/fx-bench-payload")
    parser.add_argument("--kernel", default="heclgang/fx-bench")
    parser.add_argument("--kaggle", default="/data/cache/bin/kaggle")
    parser.add_argument("--wait-minutes", type=float, default=40)
    parser.add_argument("--dataset-wait-minutes", type=float, default=10)
    parser.add_argument("--results-out", help="where to store the results (default: the next free name under benchmarks/kaggle/results)")
    parser.add_argument("--work-dir", help="where to write the payload, dataset and kernel directories (default: a new temp dir)")
    parser.add_argument("--dry-run", action="store_true", help="write the directories and stop")
    args = parser.parse_args()

    root = Path(args.work_dir).resolve() if args.work_dir else Path(tempfile.mkdtemp(prefix="fx-bench-push-"))
    if args.work_dir:
        root.mkdir(parents=True, exist_ok=True)
        if any(root.iterdir()):
            sys.exit(f"error: --work-dir must be empty: {root}")
    run_id = f"{datetime.datetime.now(datetime.timezone.utc):%Y%m%dT%H%M%SZ}-{os.urandom(4).hex()}"
    payload, dataset, kernel, manifest = build_directories(args, root, run_id)
    print(f"payload: {payload}")
    print(f"dataset: {dataset}")
    print(f"kernel:  {kernel}")
    print(f"run id:  {run_id}")
    if args.dry_run:
        return 0

    publish_dataset(args, dataset, run_id, root / "dataset-check")
    require_private_dataset(args, root / "dataset-metadata-check")
    kernel_version = push_kernel(args, kernel)
    require_private_kernel(args, root / "kernel-metadata-check")
    outcome = bounded_wait("kernel", lambda: kernel_outcome(args), 30, args.wait_minutes)
    output = root / "output"
    output.mkdir()
    kaggle(args, ["kernels", "output", args.kernel, "-p", str(output)])
    lines = checked_result_lines(output / RESULTS_FILE, manifest, run_id)
    saved = Path(args.results_out).resolve() if args.results_out else next_results_path(args.source_commit)
    saved.parent.mkdir(parents=True, exist_ok=True)
    saved.write_text("\n".join(lines) + "\n")
    for line in lines:
        print(line)
    print(f"results: {saved} (run {run_id}, kernel version {kernel_version})")
    if outcome != "complete":
        sys.exit(f"error: the kernel ended as {outcome}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
