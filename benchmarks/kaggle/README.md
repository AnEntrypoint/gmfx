# fx benchmarks on Kaggle

One private Kaggle script kernel runs every benchmark that needs only a Linux
box, a pseudo-terminal and Python 3. The kernel has no network, bun, tmux or
hyperfine, so `bench_kernel.py` uses the Python standard library alone.

| File | Role |
|---|---|
| `bench_kernel.py` | Runs on Kaggle, and locally for dry runs. Writes one JSON line per configuration. |
| `push.py` | Local driver: builds the payload, publishes the dataset, pushes the kernel, waits, downloads and stores the results. |
| `gate.py` | Compares one results file with `baseline.json`; also writes the baseline. |
| `baseline.json` | Written by `gate.py --write-baseline` from the kernel runs in `results/`. |
| `results/` | One JSONL file per kernel run, as the kernel wrote it. |

## What runs on Kaggle

| Configurations | Method |
|---|---|
| `build_size.<name>` (bytes) | Size of each `"kind": "build"` manifest entry (`fx-release`, `ui-activity-progress-bench`, `approval-review-bench`, `file-index-bench`), after checking size and SHA-256 against the manifest. The remote/browser terminal wasm is disabled and not part of the normal payload. The note carries the SHA-256. |
| `startup.true_baseline`, `startup.bare_fx_bench`, `startup.version`, `startup.help`, `startup.help_command`, `startup.status_json`, `startup.sessions_json`, `startup.doctor_json` (ms) | Wall time of `posix_spawn` to exit, `--repeats` runs after `--warmup` unrecorded ones, with a temporary HOME. Same rows as `benchmarks/startup.sh` (`fx` with `FX_BENCH=1`, `fx help`, `status`, `doctor`, `sessions` against the `session_list_fixture.py` store) plus `fx --version` and `fx --help`. |
| `first_frame.p50`, `first_frame.p95`, `first_frame.cpu_ms` (ms), `first_frame.rss_mib` (mib) | The `benchmarks/first_frame.py` method: fx on a fresh pty, terminal queries answered with its `query_replies`, time to the `Run /help` frame, Ctrl+D after `--first-frame-window` seconds, CPU and peak RSS from `wait4`. `p50` and `p95` share samples; in the `p95` line the `median` field holds the p95. `KIMI_CODE_TRUST_WORKSPACE=1` skips the folder trust question that an empty HOME would otherwise show instead of the first frame. |
| `wait_cpu.idle_fresh_prompt`, `wait_cpu.idle_after_turn`, `wait_cpu.model_reply_held`, `wait_cpu.foreground_bash`, `wait_cpu.waitfor_background_task`, `wait_cpu.idle_after_printed_output` (percent_of_core) | Port of `scripts/wait-cpu-probe.ts`. Interactive fx on a pty against a Python fake gateway. CPU is utime+stime of every thread in `/proc/<pid>/task/*/stat` over `--sample-seconds` (10), as percent of one core. One sample per round, up to `--rounds` (3) rounds, each with a fresh fx. The note has the main thread's voluntary context switches per second. |
| `turn_loop.step_ms` (ms) | `fx ask` with `--turn-steps` (50) scripted `read_file` calls and a final text. A step is the next request's arrival minus the moment the previous response was written, so the gateway's own handling time is excluded. Each sample is one round's median step. |
| `long_turn.peak_rss_mib` (mib) | `benchmarks/long_turn_memory.py` with `--long-turn-steps` (200); each sample is one run's peak VmRSS. |
| `shell_command.per_call_ms` (ms) | `benchmarks/shell_command_overhead.py` with `--shell-calls` (30) Bash `ls` calls; each sample is one run's median call. The note has the startup-file load count (`rc_loads`). |
| `tui_bench.ui_activity` (ms), `tui_bench.ui_activity.comparison_ratio`, `tui_bench.ui_activity.growth_ratio` (ratio) | `bin/ui-activity-progress-bench` (`zig build bench-ui-activity`), once per round. The wall time of the process, and the two ratios it prints. The ratios compare two code paths inside one process, so they do not depend on the host's speed. |
| `tui_bench.approval_review.<scenario>.paint_ms` (ms), `tui_bench.approval_review.<scenario>.terminal_bytes` (bytes), for `transcript`, `diff`, `combined`, `payload`, `edge` | `bin/approval-review-bench <scenario> <runs> 1` (`zig build bench-approval-review`), `runs` = `--repeats`, at most 30. It renders the file-diff approval review into a memory buffer and prints one JSON line per phase. Each sample is one run's `paint_ns` summed over its seven phases, and the terminal bytes it wrote. |
| `tui_bench.file_index` (ms), `tui_bench.file_index.index_build_ms`, `tui_bench.file_index.search_p50_ms`, `tui_bench.file_index.search_p95_ms` (ms) | `bin/file-index-bench` (`zig build bench-file-index`), once per round: 100000 candidates, 4000 searches. The wall time of the process and the figures it prints. The binary exits non-zero when its p95 is 16 ms or more; Kaggle CPUs measure about 15 ms, so the kernel keeps the figures in that case and the gate decides. |

The three bench binaries read no terminal: they write to stdout and run with
stdin closed. A payload without one of them reports its rows as `ok: false`,
`not in payload`.

How the wait-CPU states are reached, without fixed sleeps where a condition
exists:

- fresh prompt: the `Run /help` frame is on the pty and output has been quiet for one second.
- after a turn: the gateway saw the request, the answer text is on the pty, output is quiet.
- model reply held: the gateway saw the request and keeps the response open, sending an SSE comment every 50 ms as the e2e fixture does, until the sample is taken.
- foreground Bash: the gateway answered with the `Bash` call and a `sleep` process is a descendant of fx.
- WaitFor: the gateway answered the background `Bash` call and then the `WaitFor` call (two requests for the prompt).
- after printed output: the gateway answered with a `Bash` call that prints 40 lines (`for i in $(seq 1 40); do echo printed-line-$i; done`) and then the final text; the answer is on the pty, output is quiet for one second, and `--settle-seconds` more pass. Before commit `aa796930` fx repainted the idle transcript forever in this state and used about 40% of a core.

Each of the three busy states then waits `--settle-seconds` (2) before the
sample, which the local probe does not do for the held reply. The sleep command
runs for sample + settle + 13 seconds, which is `sleep 25` at the defaults.

Before any configuration runs, every file in `manifest.json` is checked by size
and SHA-256. A mismatch prints one `{"config": "payload", "ok": false, ...}`
line and exits 2. A match prints one `{"config": "payload", "ok": true, ...}`
line with the manifest's `run_id` and `git`, the file count and bytes, and the
host (`cpu_models`, `cpus`, `usable_cpus`, `kernel`, `libc`, `python`). The
gate ignores the `payload` line. Exit code is 0 when at least one configuration
ran, else 1.

## Result line format

One JSON object per line, in `--out` and on stdout:

```json
{"config": "startup.version", "unit": "ms", "samples": [1.4, 1.5], "median": 1.45, "min": 1.4, "max": 1.5, "spread": 0.1, "runs": 2, "ok": true, "note": ""}
```

`unit` is `ms`, `percent_of_core`, `bytes`, `mib` or `ratio`. `spread` is max minus min.
A configuration that could not run has `ok: false`, the reason in `note`, and
null statistics. Lower is better for every configuration.

## Running it

Local dry run, short:

```sh
python3 benchmarks/kaggle/push.py --fx /tmp/fx-release/bin/fx --repeats 3 --work-dir /tmp/fx-bench-dry/push --dry-run
python3 benchmarks/kaggle/bench_kernel.py --fx /tmp/fx-release/bin/fx --payload /tmp/fx-bench-dry/push/payload \
  --out /tmp/fx-bench-dry/results.jsonl --repeats 3 --sample-seconds 4
```

`--only NAME` (repeatable) limits a run to a configuration or a group, such as
`--only wait_cpu --only startup.version`.

Kaggle run. Build into a scratch prefix for glibc 2.31, because Kaggle's glibc
is older than a current host's, then push:

```sh
zig build install bench-ui-activity bench-approval-review bench-file-index \
  -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-gnu.2.31 -p /tmp/fx-kaggle-build
python3 benchmarks/kaggle/push.py --fx /tmp/fx-kaggle-build/bin/fx \
  --bench-bin /tmp/fx-kaggle-build/bin/ui-activity-progress-bench \
  --bench-bin /tmp/fx-kaggle-build/bin/approval-review-bench \
  --bench-bin /tmp/fx-kaggle-build/bin/file-index-bench \
  --repeats 30 --dataset heclgang/fx-bench-payload --kernel heclgang/fx-bench --kaggle /data/cache/bin/kaggle
```

`--source-commit` names the commit the binaries were built from when that is
not `HEAD`. `--results-out PATH` stores the results somewhere other than
`results/`.

`push.py` writes three directories under a temp dir (or `--work-dir`):

- `payload/`: `bin/fx` and bench binaries, the Python files, `manifest.json`. This is the layout `bench_kernel.py --payload` reads.
- `dataset/`: the same files flat, by base name, plus `manifest.json` and `dataset-metadata.json`. Flat because the dataset is uploaded with `--dir-mode skip`. The manifest keeps each file's payload path.
- `kernel/`: `kernel-metadata.json` (`is_private: true`, `enable_gpu: false`, `enable_internet: false`, the dataset in `dataset_sources`) and `fx_bench_entry.py`.

`fx_bench_entry.py` finds the `manifest.json` under `/kaggle/input` whose
`run_id` matches this push, rebuilds `payload/` in `/kaggle/working` from the
manifest paths, sets the binaries executable, runs `bench_kernel.py` with
`--out /kaggle/working/results.jsonl`, prints each line and removes the payload
copy so the kernel output holds the results only. A kernel that mounted an
older dataset version fails with exit 2 instead of measuring the wrong binary.

Unless `--dry-run` is given, `push.py` then runs, printing each command:

1. `kaggle datasets status <dataset>`. When that fails the dataset does not exist yet (the CLI answers 403) and it runs `datasets create -p dataset/ --dir-mode skip`, which is private unless `--public` is passed. Otherwise `datasets version -p dataset/ -m MSG --dir-mode skip` adds a version.
2. Waits, every 15 s for up to `--dataset-wait-minutes` (10), until the status is `ready` and `datasets download -f manifest.json` returns this push's `run_id`. The status alone also reads `ready` while Kaggle still serves the previous version.
3. `kaggle datasets metadata`: stops unless `isPrivate` is true.
4. `kaggle kernels push -p kernel/ --timeout SECONDS` (`--wait-minutes` in seconds) and reads the kernel version from its output. Every push of the same kernel is a new version; nothing in the metadata needs a bump.
5. `kaggle kernels pull -m`: stops unless the kernel is private and has no internet.
6. One bounded wait: `kaggle kernels status <kernel>` every 30 s for up to `--wait-minutes` (40), reporting the elapsed time. A full run takes about 10 minutes.
7. `kaggle kernels output <kernel> -p output/`, checks that `results.jsonl` exists, that every line parses, that `build_size.fx-release` names the SHA-256 of the binary just uploaded and that the `payload` line carries this push's `run_id`.
8. Copies the lines to `benchmarks/kaggle/results/<UTC date>-<source commit>-<run index>.jsonl` and prints them, with the run id and the kernel version.

The CLI reads its credentials itself. `push.py` never reads, prints or stores
them.

## Baseline and margin

```sh
python3 benchmarks/kaggle/gate.py --write-baseline benchmarks/kaggle/results/*.jsonl
python3 benchmarks/kaggle/gate.py --results RUN.jsonl
python3 benchmarks/kaggle/gate.py --self-test
```

`--baseline` defaults to `benchmarks/kaggle/baseline.json`. The baseline needs
two or more results files from separate kernel runs. Per configuration it
stores:

- `run_medians`: each run's median, in the order the files were given.
- `median`: the median of `run_medians`.
- `between_runs`: the largest run median minus the smallest. This is the run-to-run spread.
- `within_run`: the largest interquartile range of any one run's samples (nearest-rank 75th percentile minus 25th). With three samples that is their full range.
- `spread`: the larger of `between_runs` and `within_run`.
- `runs`: how many runs measured it. A configuration no run could measure is stored with `"runnable": false`.

A configuration fails when

```
result.median > baseline.median + 3 * baseline.spread
```

The margin is three times the measured spread and has no fixed percentage in
it. Kaggle gives each run whatever host is free: the recorded runs differ by up
to 30% on the startup rows and 15% on the shell row with the same binary. A
handful of runs sees only part of that variation, which is why the margin is
three spreads and not one. `within_run` keeps a row from getting a margin
near zero when the run medians happen to agree. The interquartile range is used
because one slow sample out of 30 moves a run's full range but not its
quartiles.

Exceptions:

- `bytes` rows (`build_size.*`, `*.terminal_bytes`) are the same in every run, so their spread is zero. They fail above `baseline.median * 1.02`. That is a size allowance, not a noise margin.
- `percent_of_core` rows get a margin of at least `--percent-floor` (0.5) percent of a core. One clock tick over a ten second sample is 0.1, the idle states measure 0.1 to 0.4, and three spreads of a row that measured the same in every run would be zero. The regression the printed-output row guards against measured about 40.
- `ok: false` in the results fails, unless the baseline records the configuration as not runnable.
- A configuration missing from the results fails; one missing from the baseline passes and is reported as such.

The gate also derives one row per startup command, `startup.<name>.over_true_baseline`
(ratio): the command's median over `startup.true_baseline` of the same run. A
slower host moves both, so these rows vary less between runs than the
millisecond rows and get a tighter limit. `startup.bare_fx_bench` measured
0.99 to 1.36 ms across the recorded runs and 1.21 to 1.35 as a ratio. The
kernel does not write these rows; `gate.py` computes them when it reads a
results file, for the baseline and for the run under test alike.

Output is one `GATE <config>: pass|FAIL value=… limit=…` line per configuration;
the exit code is 1 on any failure.

Rebuild the baseline from fresh runs when a change moves a row on purpose. Add
the new results files and pass the files that describe the new state to
`--write-baseline`.

## What CI does

The `Kaggle benchmark gate` job in `.github/workflows/bench.yml`:

1. Always runs `gate.py --self-test`.
2. Always gates every file in `results/` against `baseline.json`. This checks that the recorded figures and the baseline agree. It does not measure the commit under test.
3. When the `KAGGLE_USERNAME` and `KAGGLE_KEY` secrets are set, builds the payload, runs `push.py` under that account and gates the new results against `baseline.json`. Without the secrets these steps are skipped and the job says so in a notice. Pull requests from forks never receive secrets.

The job has its own concurrency group, because every run pushes a version of
the same kernel.

On 2026-11-12 `gh secret list` showed no secrets for the repository, so step 3
has not run in CI.
The recorded runs were pushed from a development host with the `heclgang`
account. CI installs the CLI with `pipx install kaggle==2.2.4`, the version
those runs used.

## What runs where

| Rows | Runs on | Why | Budget |
|---|---|---|---|
| Startup (`startup.*`), first frame, the six wait-CPU states, turn-loop step, long-turn peak RSS, shell command overhead, build sizes, UI activity, approval review, file index | Kaggle | Need Linux, a pty and Python only | `baseline.json`, three spreads |
| `benchmarks/startup.sh` and `benchmarks/check_budgets.py` | CI runner, `Startup Latency` job | hyperfine is not in the kernel and the job downloads it | Each command's median over the same run's `process baseline` median (`/usr/bin/true`). No milliseconds. |
| `zig build run-bench-ui-activity` | CI runner, also Kaggle | Needs nothing else | The binary's own ratios between two code paths in one process |
| `tests/e2e/tui-performance.test.ts` | CI runner | bun and tmux | Sample counts, thread and descriptor counts and RSS bytes are load-independent. Its p50/p90/p95 budgets are milliseconds on the CI runner and are unchanged. |
| `scripts/wait-cpu-probe.ts --check` | CI runner | bun and tmux | CPU time over wall time, 1.5% of a core idle and 6% waiting. A loaded host slows the clock for both, so the ratio holds. The Kaggle `wait_cpu.*` rows gate the same six states against the baseline. |
| `benchmarks/shell_command_overhead.py`, `benchmarks/long_turn_memory.py` jobs | CI runner, also Kaggle | Need nothing else | `rc_loads == 1` (a count) and peak RSS under 512 MiB (bytes) are load-independent. The 60 ms per call budget is milliseconds on the CI runner and is unchanged. |
| `benchmarks/approval_review_tty.ts` | A developer's machine | bun, tmux and a real terminal's timing | None enforced; `approval-review-bench` is the headless form and runs on Kaggle |
| libfx runtime (`benchmarks/libfx/*.mjs`) | CI runner, on request | node, bun and an `npm install` from the network | `check-results.mjs` contracts |
| Signed macOS comparison (`benchmarks/signed_macos_memory.test.ts`, `signed_macos_resources.c`) | `macos-15` runner, on request | A signed macOS build | Candidate against control in the same run |
| PGSO artifact comparison (`benchmarks/pgso_artifacts.test.ts`) | `macos-15` runner, on request | bun, release artifacts fetched from GitHub | Candidate against control in the same run |
| Live-provider smoke rows | A developer's machine | Network and provider credentials; the kernel has neither | None |

### The startup ratio budgets

`check_budgets.py` divides each hyperfine median by the `process baseline`
median of the same run and fails above the command's ratio. A host that is
uniformly slower moves both medians and keeps the ratio; fx doing more work at
startup moves only the numerator. A run without a `process baseline` result
fails.

The budgets are one and a half times the largest ratio the recorded Kaggle
runs measured for the matching `startup.*` row over `startup.true_baseline`,
rounded up to the next half:

| hyperfine command | Kaggle row | Largest recorded ratio | Budget |
|---|---|---|---|
| `fx (startup)` | `startup.bare_fx_bench` | 1.35 | 2.5 |
| `fx help` | `startup.help_command` | 1.59 | 2.5 |
| `fx status --json` | `startup.status_json` | 2.65 | 4.0 |
| `fx doctor --json` | `startup.doctor_json` | 3.07 | 5.0 |
| `fx sessions --json` | `startup.sessions_json` | 4.41 | 7.0 |
| any other command | | | 2.5 |

They are not enforced on macOS, where the ratios are printed only. They have
not yet run on the GitHub runner, whose hyperfine ratios may differ from the
`posix_spawn` ratios measured on Kaggle.
