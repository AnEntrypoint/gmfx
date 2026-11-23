# `fx run-code --engine edge`

Status: experimental, opt-in, off by default. The decision (2026-11-23, specs/edgejs-swap.md) is go behind a flag for fx only. txiki stays the default engine and the run_code runtime on the model path. Nothing here makes edgejs a default or a sandbox.

## What it is

`--engine edge` runs a script in edgejs (Node's library code over N-API, here the native QuickJS build) linked into the fx binary. It exists only in a binary built with `-Dedgejs=<dir>` (the directory holds edgejs's static libraries, `libstdc++.so` and the compiled shim). A default build refuses the flag with a usage error and contains no edge code.

```
zig build -Dedgejs=<dir> ...
fx run-code --engine edge --file <script> --permission-mode ask|yolo
```

Files: native/edgejs/fx_edge.cc (the embedding, compiled with g++ because edgejs's libraries use the libstdc++ ABI), src/core/runcode/edge.zig, src/core/runcode/edge_prelude.js, scripts/edgejs-witness.sh.

## The gate is a policy gate, not a sandbox

- Native verbs reach the script as `fxHost.call(name, argsJson)`. They go through the same Zig permission path as `run_code` verbs, so a verb the mode does not admit is refused with EFX_PERMISSION_DENIED.
- Node's own permission binding cannot be the gate: `--permission` is ignored by edge, `process.permission.has` always returns false and `internalBinding('permission')` is not registered.
- Outside yolo, a prelude refuses the Node I/O modules (child_process, cluster, dgram, dns, fs, fs/promises, http, http2, https, inspector, net, tls, worker_threads) at resolve time, and through `process.getBuiltinModule` and `process.binding`. Work goes through `fxHost.call` verbs instead.
- It is bypassable by anything the prelude does not hook. Open holes: `fetch` and `process.dlopen` stay available outside yolo. Do not describe this engine as a sandbox.
- Safe mode under Wasmer is untested: gm's native QuickJS build has EDGE_QUICKJS_WEBASSEMBLY off.

## Limits

- Size: the edge binary is 79,882,752 bytes against 20,480,016 for the default (+59.4 MB, about 3.9 times).
- One run call per environment: each edgejs `Run*` call re-bootstraps Node, so a second call in one environment fails. The prelude therefore runs through `--require` and the script is the single run.
- node:sqlite is missing: edgejs registers no sqlite binding.
- Not built on this route: the run_code deadline, the console sink and the JSON return. It is a CLI route only; the model path stays on txiki.
- QuickJS is slower than V8.

## Cost when the flag is off

None measured. In a default build `edge.zig` is behind `comptime build_options.edgejs` and is not analysed or compiled, and nothing from edgejs is linked: the default binary has no DT_NEEDED entries, no fx_edge symbols, and 60 runs of `fx --version` take about 3 ms each, the same as the build before the edge route. Build time is unchanged because no edgejs code is compiled. The only default-build residue is parsing `--engine` in run_code.zig.

## Witness

scripts/edgejs-witness.sh builds the edge binary and prints SIZE before and after and six checks (a verb refused in ask and admitted in yolo; node:child_process and node:fs refused in ask and loadable in yolo), last line `EDGE_DONE <fails>`. Last result: EDGE_DONE 0 on 24f72280, /workspace/tmp/fx/win_edge5.out.
