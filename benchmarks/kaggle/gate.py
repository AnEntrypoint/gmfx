#!/usr/bin/env python3
import argparse
import json
import math
from pathlib import Path
import statistics
import sys

SPREAD_MULTIPLIER = 3
BYTES_MARGIN = 0.02
UNGATED_CONFIGS = ("payload",)
STARTUP_PREFIX = "startup."
STARTUP_REFERENCE = "startup.true_baseline"
STARTUP_RATIO_SUFFIX = ".over_true_baseline"


def read_results(path):
    results = {}
    for number, line in enumerate(Path(path).read_text().splitlines(), 1):
        if not line.strip():
            continue
        try:
            entry = json.loads(line)
        except ValueError as error:
            raise SystemExit(f"error: {path} line {number} is not JSON: {error}")
        if entry.get("config") not in UNGATED_CONFIGS:
            results[entry["config"]] = entry
    return with_startup_ratios(results)


def with_startup_ratios(results):
    reference = results.get(STARTUP_REFERENCE)
    if reference is None or not reference.get("ok") or not reference.get("median"):
        return results
    derived = dict(results)
    for config, entry in results.items():
        if not config.startswith(STARTUP_PREFIX) or config == STARTUP_REFERENCE or not entry.get("ok") or entry.get("median") is None:
            continue
        derived[config + STARTUP_RATIO_SUFFIX] = {
            "config": config + STARTUP_RATIO_SUFFIX,
            "unit": "ratio",
            "samples": [round(sample / reference["median"], 3) for sample in entry.get("samples") or []],
            "median": round(entry["median"] / reference["median"], 3),
            "ok": True,
            "note": f"{config} over {STARTUP_REFERENCE} of the same run",
        }
    return derived


def nearest_rank(ordered, percent):
    return ordered[max(1, math.ceil(percent / 100 * len(ordered))) - 1]


def interquartile_range(samples):
    if not samples:
        return 0.0
    ordered = sorted(samples)
    return nearest_rank(ordered, 75) - nearest_rank(ordered, 25)


def build_baseline(runs):
    baseline = {}
    for config in sorted({config for run in runs for config in run}):
        seen = [run[config] for run in runs if config in run]
        usable = [entry for entry in seen if entry.get("ok") and entry.get("median") is not None]
        if not usable:
            baseline[config] = {"unit": seen[0].get("unit"), "median": None, "spread": None, "runs": 0, "direction": "lower_is_better", "runnable": False}
            continue
        medians = [entry["median"] for entry in usable]
        between_runs = max(medians) - min(medians)
        within_run = max(interquartile_range(entry.get("samples") or []) for entry in usable)
        baseline[config] = {
            "unit": usable[0].get("unit"),
            "median": round(statistics.median(medians), 3),
            "spread": round(max(between_runs, within_run), 3),
            "between_runs": round(between_runs, 3),
            "within_run": round(within_run, 3),
            "run_medians": medians,
            "runs": len(usable),
            "direction": "lower_is_better",
        }
    return baseline


def limit_for(reference, percent_floor):
    if reference.get("unit") == "bytes":
        return reference["median"] * (1 + BYTES_MARGIN)
    floor = percent_floor if reference.get("unit") == "percent_of_core" else 0
    return reference["median"] + max(SPREAD_MULTIPLIER * reference["spread"], floor)


def verdicts(baseline, results, percent_floor):
    lines = []
    for config in sorted(set(baseline) | set(results)):
        reference, result = baseline.get(config), results.get(config)
        if reference is None:
            lines.append((config, True, result.get("median"), None, "not in the baseline"))
            continue
        runnable = reference.get("runnable", True) and reference.get("median") is not None
        if result is None:
            lines.append((config, not runnable, None, None, "missing from the results"))
            continue
        if not result.get("ok") or result.get("median") is None:
            lines.append((config, not runnable, None, None, f"not runnable: {result.get('note')}"))
            continue
        if not runnable:
            lines.append((config, True, result["median"], None, "the baseline records it as not runnable"))
            continue
        limit = limit_for(reference, percent_floor)
        lines.append((config, result["median"] <= limit, result["median"], limit, ""))
    return lines


def show(value):
    return "none" if value is None else f"{value:.3f}"


def gate(baseline, results, percent_floor):
    failed = 0
    for config, passed, value, limit, reason in verdicts(baseline, results, percent_floor):
        failed += 0 if passed else 1
        suffix = f" ({reason})" if reason else ""
        print(f"GATE {config}: {'pass' if passed else 'FAIL'} value={show(value)} limit={show(limit)}{suffix}")
    return failed


def line(config, median, samples=(), unit="ms", ok=True):
    return {"config": config, "unit": unit, "median": median, "samples": list(samples), "ok": ok, "note": "self-test"}


def self_test():
    size = "build_size.fx"
    missing = line("absent", None, ok=False)
    assert interquartile_range([]) == 0.0
    assert interquartile_range([5.0]) == 0.0
    assert interquartile_range([1.0, 2.0, 9.0]) == 8.0
    assert interquartile_range([1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 100.0]) == 4.0
    baseline = build_baseline([
        {"a": line("a", 10.0, [9.5, 10.0, 10.5]), size: line(size, 1000, [1000], unit="bytes"), "absent": missing},
        {"a": line("a", 12.0, [12.0, 12.0, 12.0, 12.0, 40.0]), size: line(size, 1000, [1000], unit="bytes"), "absent": missing},
        {"a": line("a", 11.0, [10.0, 11.0, 13.0])},
    ])
    assert baseline["a"] == {"unit": "ms", "median": 11.0, "spread": 3.0, "between_runs": 2.0, "within_run": 3.0, "run_medians": [10.0, 12.0, 11.0], "runs": 3, "direction": "lower_is_better"}, baseline["a"]
    assert baseline["absent"]["runnable"] is False

    def outcome(results):
        return {config: passed for config, passed, _, _, _ in verdicts(baseline, results, 0.5)}

    steady = {"a": line("a", 20.0), size: line(size, 1020, unit="bytes"), "absent": missing}
    assert outcome(steady) == {"a": True, size: True, "absent": True}
    assert outcome(dict(steady, a=line("a", 20.001)))["a"] is False
    assert outcome(dict(steady, **{size: line(size, 1021, unit="bytes")}))[size] is False
    assert outcome(dict(steady, a=line("a", None, ok=False)))["a"] is False
    assert outcome({size: steady[size], "absent": steady["absent"]})["a"] is False
    assert outcome(dict(steady, absent=line("absent", 5.0)))["absent"] is True
    assert outcome(dict(steady, fresh=line("fresh", 99.0)))["fresh"] is True
    steady_rows = build_baseline([{"b": line("b", 100.0, [100.0])}, {"b": line("b", 101.0, [101.0])}])
    assert [passed for _, passed, _, _, _ in verdicts(steady_rows, {"b": line("b", 103.5)}, 0.5)] == [True]
    assert [passed for _, passed, _, _, _ in verdicts(steady_rows, {"b": line("b", 103.6)}, 0.5)] == [False]
    idle = {"c": {"unit": "percent_of_core", "median": 0.0, "spread": 0.0, "runs": 2, "direction": "lower_is_better"}}
    assert [passed for _, passed, _, _, _ in verdicts(idle, {"c": line("c", 0.5, unit="percent_of_core")}, 0.5)] == [True]
    assert [passed for _, passed, _, _, _ in verdicts(idle, {"c": line("c", 0.6, unit="percent_of_core")}, 0.5)] == [False]
    assert [passed for _, passed, _, _, _ in verdicts(idle, {"c": line("c", 0.1, unit="percent_of_core")}, 0.0)] == [False]
    slow_host = with_startup_ratios({STARTUP_REFERENCE: line(STARTUP_REFERENCE, 2.0, [2.0]), "startup.help": line("startup.help", 3.0, [2.9, 3.0, 3.2])})
    assert slow_host["startup.help" + STARTUP_RATIO_SUFFIX]["median"] == 1.5
    assert slow_host["startup.help" + STARTUP_RATIO_SUFFIX]["samples"] == [1.45, 1.5, 1.6]
    assert STARTUP_REFERENCE + STARTUP_RATIO_SUFFIX not in slow_host
    assert with_startup_ratios({"startup.help": line("startup.help", 3.0)}) == {"startup.help": line("startup.help", 3.0)}
    assert gate(baseline, steady, 0.5) == 0
    assert gate(baseline, dict(steady, a=line("a", 21.0)), 0.5) == 1
    print("gate self-test passed")


def main():
    parser = argparse.ArgumentParser(description="Gate one Kaggle benchmark results file against the baseline.")
    parser.add_argument("--baseline", default=str(Path(__file__).resolve().parent / "baseline.json"))
    parser.add_argument("--results", help="results.jsonl of the run to gate")
    parser.add_argument("--write-baseline", nargs="+", metavar="RESULTS", help="two or more results files from separate kernel runs; writes --baseline")
    parser.add_argument("--percent-floor", type=float, default=0.5, help="smallest allowed margin for percent_of_core configs, in percent of a core")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if args.write_baseline:
        if len(args.write_baseline) < 2:
            parser.error("--write-baseline needs two or more results files from separate kernel runs")
        baseline = build_baseline([read_results(path) for path in args.write_baseline])
        Path(args.baseline).write_text(json.dumps(baseline, indent=2, sort_keys=True) + "\n")
        print(f"wrote {args.baseline} from {len(args.write_baseline)} runs, {len(baseline)} configs")
        if not args.results:
            return 0
    if not args.results:
        parser.error("--results is required")
    baseline = json.loads(Path(args.baseline).read_text())
    failed = gate(baseline, read_results(args.results), args.percent_floor)
    if failed:
        print(f"GATE {failed} configs failed", file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
