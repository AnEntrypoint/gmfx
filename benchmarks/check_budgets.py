#!/usr/bin/env python3

import json
import glob
import os
import platform
import sys

PROCESS_BASELINE = "process baseline"
LINUX_BASELINE_RATIO_BUDGETS = {
    "fx (startup)": 2.5,
    "fx help": 2.5,
    "fx status --json": 4.0,
    "fx doctor --json": 5.0,
    "fx sessions --json": 7.0,
}
DEFAULT_LINUX_BASELINE_RATIO_BUDGET = 2.5


def command_budget(system_name, command):
    if system_name != "Linux":
        return None
    return LINUX_BASELINE_RATIO_BUDGETS.get(command, DEFAULT_LINUX_BASELINE_RATIO_BUDGET)


def baseline_ratio(command_median, baseline_median):
    return command_median / baseline_median


def within_budget(ratio, budget):
    return ratio <= budget


def hyperfine_results(result_files):
    results = []
    for result_file in result_files:
        if os.path.basename(result_file) == "summary.json":
            continue
        with open(result_file) as file:
            results.append(json.load(file)["results"][0])
    return results


def check_results(result_files, system_name):
    results = hyperfine_results(result_files)
    if not results:
        print("No benchmark result files found after excluding summary.json")
        return False
    baseline = next((result for result in results if result["command"] == PROCESS_BASELINE), None)
    if baseline is None or baseline["median"] <= 0:
        print(f"No usable '{PROCESS_BASELINE}' result in this run, so no ratio can be checked")
        return False
    print(
        f"  BASE  {PROCESS_BASELINE:<25} median={baseline['median'] * 1000:>5.2f}ms  "
        f"min={baseline['min'] * 1000:>5.2f}ms  mean={baseline['mean'] * 1000:>5.2f}ms"
    )

    failed = False
    for result in results:
        name = result["command"]
        if name == PROCESS_BASELINE:
            continue
        ratio = baseline_ratio(result["median"], baseline["median"])
        measured = f"{name:<25} ratio={ratio:>5.2f}x  median={result['median'] * 1000:>5.2f}ms  mean={result['mean'] * 1000:>5.2f}ms"
        budget = command_budget(system_name, name)
        if budget is None:
            print(f"  INFO  {measured}  (no ratio budget on {system_name})")
            continue
        ok = within_budget(ratio, budget)
        print(f"  {'PASS' if ok else 'FAIL'}  {measured}  (limit: {budget:.1f}x the same-run process baseline)")
        if not ok:
            failed = True
    return not failed


def main():
    system_name = platform.system()
    result_files = sorted(
        glob.glob(
            os.environ.get(
                "FX_BENCH_RESULTS_GLOB",
                "benchmarks/results/*.json",
            )
        )
    )
    if check_results(result_files, system_name):
        if system_name != "Linux":
            print(f"\nBaseline-ratio budgets are not evaluated on {system_name}; the ratios are informational")
            return 0
        print("\nAll commands within their baseline-ratio budget")
        return 0
    print("\nBaseline-ratio budget exceeded or not measurable")
    return 1


if __name__ == "__main__":
    sys.exit(main())
