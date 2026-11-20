#!/usr/bin/env python3

import importlib.util
import json
import os
import pathlib
import platform
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
MODULE_PATH = pathlib.Path(__file__).with_name("check_budgets.py")
SPEC = importlib.util.spec_from_file_location("check_budgets", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
check_budgets = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check_budgets)


def hyperfine_result(command, seconds):
    return {"command": command, "mean": seconds, "median": seconds, "min": seconds, "max": seconds, "stddev": 0.0}


class BudgetContractTests(unittest.TestCase):
    def run_checker(self, results):
        with tempfile.TemporaryDirectory() as tmp:
            result_dir = pathlib.Path(tmp)
            for index, result in enumerate(results):
                (result_dir / f"{index}.json").write_text(json.dumps({"results": [result]}))
            env = os.environ.copy()
            env["FX_BENCH_RESULTS_GLOB"] = str(result_dir / "*.json")
            return subprocess.run(
                [sys.executable, str(MODULE_PATH)],
                cwd=REPO_ROOT,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )

    def test_linux_budgets_are_ratios_to_the_process_baseline(self) -> None:
        self.assertEqual(
            check_budgets.command_budget("Linux", "fx sessions --json"),
            check_budgets.LINUX_BASELINE_RATIO_BUDGETS["fx sessions --json"],
        )
        self.assertEqual(
            check_budgets.command_budget("Linux", "fx unlisted"),
            check_budgets.DEFAULT_LINUX_BASELINE_RATIO_BUDGET,
        )

    def test_darwin_has_no_local_product_budget(self) -> None:
        self.assertIsNone(
            check_budgets.command_budget("Darwin", "fx sessions --json"),
        )

    def test_budget_check_uses_the_median_ratio(self) -> None:
        self.assertEqual(check_budgets.baseline_ratio(0.003, 0.001), 3.0)
        self.assertFalse(check_budgets.within_budget(2.51, 2.5))
        self.assertTrue(check_budgets.within_budget(2.5, 2.5))

    def test_missing_results_fail(self):
        result = self.run_checker([])
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertIn("No benchmark result files found after excluding summary.json", result.stdout)

    def test_missing_process_baseline_fails(self):
        result = self.run_checker([hyperfine_result("fx help", 0.001)])
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertIn("No usable 'process baseline' result", result.stdout)

    @unittest.skipUnless(platform.system() == "Linux", "ratio budgets are enforced on Linux only")
    def test_a_uniformly_slower_host_passes_and_a_slower_command_fails(self):
        budget = check_budgets.LINUX_BASELINE_RATIO_BUDGETS["fx help"]
        for host_slowdown in (1, 10):
            baseline = 0.0005 * host_slowdown
            steady = self.run_checker([
                hyperfine_result("process baseline", baseline),
                hyperfine_result("fx help", baseline * budget),
            ])
            self.assertEqual(0, steady.returncode, steady.stdout + steady.stderr)
            regressed = self.run_checker([
                hyperfine_result("process baseline", baseline),
                hyperfine_result("fx help", baseline * budget * 1.01),
            ])
            self.assertEqual(1, regressed.returncode, regressed.stdout + regressed.stderr)
            self.assertIn("FAIL  fx help", regressed.stdout)


if __name__ == "__main__":
    unittest.main()
