# Build ledger: `zig build test -Dtest-area=core`

Host: 15 GB RAM, swap in use, shared with other jobs. Load is the 1-minute
loadavg from /proc/loadavg at the start and end of each build. A row is
**contended** when either reading is above 12. Contended rows were rerun once
when load was under 12, and both rows are kept. CPU is user+sys seconds of
the build process tree, from the shell `time` builtin. Test count is
`8011 pass, 27 skip (8038 total)` for every clean full run.

## Final tree (commit b6bdde43 and its ancestors back to ccb99ac1)

### Measurement chain on the final tree (`/tmp/fx-ledger6.txt`)

| Row | Setting | Wall s | CPU s | Load start→end | State | Tests | run-test step | compile test / exe |
|---|---|---|---|---|---|---|---|---|
| C_nollvm | cold, `-Dtest-llvm=false` | 727.8 | 754.9 | 11.1→17.6 | contended | 8011/8038 | 11 min | 54 s / 42 s |
| C_nollvm_rerun | cold, `-Dtest-llvm=false`, fresh cache | 693.3 | 664.5 | 8.6→33.9 | contended (rerun) | 8011/8038 | 10 min | 52 s / 40 s |
| W_nollvm | warm no-op, no-LLVM | 0.8 | 0.3 | 10.9→10.9 | clean | 0 run | none | none |
| E_nollvm | one-file edit, no-LLVM | 800.7 | 617.8 | 10.9→12.2 | contended | **8010/8038, 1 failed** | — | 51 s / 38 s |
| E_nollvm_rerun | one-file edit, no-LLVM (rerun) | 572.9 | 470.9 | 10.7→9.2 | clean | 8011/8038 | 9 min | — |
| C_default | cold, zig's choice (no flag) | 660.2 | 585.8 | 8.2→6.1 | clean | 8011/8038 | 10 min | 41 s / 33 s |
| W_default | warm no-op, default | 0.8 | 0.4 | 6.1→6.1 | clean | 0 run | none | none |
| E_default | one-file edit, default | 593.6 | 576.4 | 6.1→11.6 | clean | 8011/8038 | 9 min | 45 s / 35 s |
| C_incr | cold, `-fincremental` | 875.3 | 735.4 | 10.3→17.1 | contended | 8011/8038 | 13 min | 46 s / 28 s |
| C_incr_rerun | cold, `-fincremental`, fresh cache (rerun) | 695.7 | 664.1 | 10.5→9.8 | clean | 8011/8038 | 10 min | 1 min / 48 s |
| W_incr | warm, `-fincremental`, no edit | 571.4 | 578.7 | 9.8→8.1 | clean | 8011/8038 | 8 min (re-ran) | 47 s / 34 s |
| E_incr | one-file edit, `-fincremental` | 638.0 | 608.5 | 8.1→8.0 | clean | 8011/8038 | 9 min | 52 s / 38 s |

Witness, filtered libc environment test (no-LLVM cache, after cold build):
`core.shared.io.test.libc environment lookups follow a host that grows the environment`
passes 1/1.

### Pass one on the same final tree (`/tmp/fx-ledger4.txt`, no CPU recorded)

These are the first-pass rows. Each contended row above has its rerun in the
chain table.

| Row | Wall s | Load start→end | State | Tests |
|---|---|---|---|---|
| N1 cold no-LLVM | 731 | 12.3→17.5 | contended (rerun = C_nollvm) | 8011/8038 |
| N2 warm no-LLVM | 1 | 17.5→17.5 | contended (rerun = W_nollvm) | no run |
| N3 edit no-LLVM | 924 | 33.3→23.9 | contended (rerun = E_nollvm) | 8011/8038 |
| D1 cold default | 516 | 22.5→4.0 | contended (rerun = C_default) | 8011/8038 |
| D3 edit default | 467 | 4.0→7.3 | clean | 8011/8038 |
| I1 cold incremental | 783 | 7.3→21.6 | contended (rerun = C_incr_rerun) | 8011/8038 |
| I2 edit incremental | 770 | 21.6→21.9 | contended (rerun = E_incr) | 8011/8038 |

### Earlier rows, before the final tree (no load recorded)

| Row | Wall s | Result |
|---|---|---|
| M1 cold default | 508 | 8011/8038 |
| M2 warm default | 1 | no run |
| M3 edit default | 476 | 8011/8038 |
| M4–M6 no-LLVM via `zig build -fno-llvm` | 0 | rejected: `unrecognized argument` (zig build has no such flag) |
| M7 `-fincremental` first run | 554 | 8010/8038, libc environment test failed (environ null under incremental link; fixed by ccb99ac1) |
| M8 `-fincremental` edit | 710 | 8010/8038, same libc failure |
| N1-loaded no-LLVM cold, before fixes | 2297 | 8009/8038, 2 failed, load ~46 (see below) |

## Findings

### Longest step

The longest step in every cold build is **`run test`**, which executes all
8038 tests: 10–13 min. Compiling the test binary takes 41–60 s and the `fx`
executable 28–42 s. An edit rebuild pays the same test run, so a one-file edit
costs nearly a full cold build (9–10 min). Speeding up the compile does not
move these numbers much.

### Selected setting

Default (zig's choice; no `-Dtest-llvm`) for debug test builds.

- Fastest clean cold build: C_default 660.2 s. Its alternatives were 693.3 s
  for no-LLVM (contended, rerun) and 695.7 s for incremental (clean rerun).
- No-LLVM is 5.0% slower cold (693.3 / 660.2) and had one failed run (E_nollvm).
- Incremental is 5.4% slower cold (695.7 / 660.2), is only settable from the
  CLI (`-fincremental`, not a `build.zig` option), and its warm no-op was a full
  rebuild (W_incr, 571.4 s), so it cannot serve as a warm default.
- Warm no-op: default 0.8 s, no-LLVM 0.8 s. No difference.
- Edit: no-LLVM 572.9 s (clean rerun) vs default 593.6 s. The gain is 3.5%,
  below the threshold, and no-LLVM has the failing run.

Stopping rule: no candidate changes a cold or warm build by 5% or more in the
direction of a gain. The last candidate (incremental cold) is 5.4% slower.

### Failures recorded in this ledger

1. **Linear-time markdown test** (`core.agent.assistant_presentation.test`,
   "long lines of unmatched or unbalanced delimiters render in linear time").
   Failed in E_nollvm (`failed without output`) at load 10.9→12.2. It passed
   in the clean rerun E_nollvm_rerun and in all other final-tree runs.
   Measured on the default cache: per-shape CPU is at most 182 ms against the
   500 ms budget, and the unmodified test passes 1/1 through the build
   (`/tmp/fx-unprobed.log`). Cause not established. Recorded as an open flake
   with 1 failure in the 17 full final-tree runs recorded here.

2. **command_runner cancellation test** (`core.execution.command_runner.test`,
   "runtime cancellation requested once the child is ready stays graceful
   before the timeout"). Failed once in the loaded pre-fix no-LLVM run
   (`/tmp/fx-speed2-N1_cold_nollvm.log`): expected `TERM`, found an empty file.
   The empty file means the force-kill from the 800 ms grace landed between
   the trap's open and write of the marker. This is a load-dependent race. It
   has not recurred in any of the 17 full final-tree runs.

3. **Earlier two-failure run** (N1 loaded, 2297 s, 8009/8038): both failures
   above. An earlier loaded no-LLVM run before the fixes (`/tmp/fx-pass-N1_cold_nollvm.log`,
   killed, 1 failure) failed the `mcp_host` runtime test "a call held while a
   retired host's servers stop ends when cancelled" (`failed without output`).
   That test passed 1/1 alone and in all 17 final-tree full runs.

### Incremental warm no-op

`W_incr` re-ran the full test step (571 s) instead of a no-op. Cause not
established. The no-LLVM and default warm rows were 0.8 s. Recorded as measured.

## Cache prune

The `prune_zig_cache` step (build.zig) removes entries older than two days from
`o/` and `h/` in `ZIG_LOCAL_CACHE_DIR` (default `.zig-cache`) before the test run.
Verified: a dry run of the same `find` selection on a mock layout listed the
aged output directory and the aged manifest and kept the fresh ones. Open: an
output directory older than two days whose manifest is recent would be pruned
under it, and the next build would fail with FileNotFound. Not seen in any
row here. Full aged-copy rebuild check not yet run.
