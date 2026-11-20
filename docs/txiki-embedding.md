# txiki.js embedding in fx: Stage 0 inventory

Read-only. Nothing is built or changed by this stage. Sources: fx at b03a9ffc, gm at /workspace/gm, thebird at /workspace/thebird.

## 1. The current run_code path

- fx has no JavaScript engine. A search of fx/src for quickjs, QuickJS, JS_NewRuntime and JS_Eval finds nothing. build.zig has no C sources (no addCSourceFiles, no third_party tree).
- run_code in src/core/tooling/tool_dispatch.zig (lines 1742-1850) is a permission-gate fixture. countRunCodeRouteCall increments a counter and returns the text "executed". The same mock is reused as gm_run_code and playwriter_execute. These tests check that the gate refuses denied calls and passes permitted ones. No body runs.
- The production body runner is gm. fx references it through its MCP route (gm_run_code) and in docs/gm-native-parity-matrix.md, docs/kimi-parity-matrix.md and docs/native-browser-orchestration.md.
- So "route run_code through txiki" means building the runner in fx. It is not a swap of an engine. The fixture tests keep passing unchanged, and the old route stays until the new runner passes its witnesses.

## 2. Tool registration: native Zig versus txiki

- Every registered tool is Zig. The names found by a search of src/core/tooling and src/core/tools (all .zig) are: read_file, write_file, edit_file, glob_files, grep_files, bash, shell, run_command, exa_search, vision, install_skill, select_tools, set_budget, workflow, agent, coder, reviewer, boss, capability_search, dynamic_tool. The gate-routed names are gm_run_code and playwriter_execute. run_code appears only as a fixture.
- Stays native Zig: every file, shell, search, network, permission and gate tool. The permission gate must run in Zig, before any JavaScript body can reach a tool.
- Moves into txiki: nothing existing moves. The new txiki-hosted pieces are (a) the run_code body runner, and (b) the agent side of Cordis, which freddie hands to fx and which runs as JavaScript inside txiki. Cordis is not rebuilt in Zig.
- LeafVerbs: the native tools above are exposed to a body as gm.<verb>(args), each call passing through the same gate as a model tool call.

## 3. Duplicated logic that the shared vendor step removes

- Vendor script: gm tools/vendor-txiki.mjs (149 lines) and thebird scripts/vendor-txiki.mjs (208 lines). 315 lines differ between them. Both fetch the same three tarballs and check each sha256. thebird also builds a wasm variant, pinned by tjsWasmSha256 in scripts/txiki/pin.json.
- Pins: the same three values appear in gm tools/vendor-txiki.mjs, in thebird scripts/vendor-txiki.mjs and in gm DESIGN.md. A grep confirms all three in thebird: txiki 763025ac98e4d6629f9ebe8396c027ff22966a6322b0dc43e442d45c6d7f8059, libuv dd9f081cc55a4d83e2a976848d074f28ee5f34eb (f5185440ee939936d6375755498b7f07915f747bd9bbfe6ea058a9ee173f88d0), quickjs-ng 7b5f588e0f9b643e2996f291bfc861abeaceddc2 (f27b2e93647e73f91201e12c4f2ee0c0d07e2f6dc06b539422bf03269d601366).
- Glue: gm native/components/quickjs/txiki has txiki_shim.c, txiki_shim.h, txiki_stubs.c, run_entry.cpp and overlay/. thebird scripts/txiki has browser/, include/ and stubs.tsv, the browser port. The two stub sets differ.
- fx has no copy yet. The shared step gives all three repos one pin file and one script, so fx does not copy the 315 divergent lines.

## 4. gm semantics to keep (gm native/components/quickjs/engine.cpp, runcode.cpp, run_entry.cpp, include/gm/runcode.hpp)

- Per-call deadline: BodyControls.js_budget bounds the body (run_entry uses 120000 ms; the run_body default is 3600000 ms). JS_SetInterruptHandler enforces it (engine.cpp:47-67). A host call has its own deadline through deadlineCall (engine.cpp:147-161). Errors read "the body passed its JavaScript deadline of N ms" or "the call passed its deadline of N ms" (engine.cpp:437-444).
- Module loader: a tjs: specifier loads a txiki builtin (gm_txiki_load_builtin, engine.cpp:70-72). A node: specifier is refused with a message that points at gm.read_file and the other verbs (engine.cpp:74-76). A disk module compiles as an ES module (engine.cpp:78-87).
- Console: console.log/info/debug/warn/error write to a ConsoleBuffer sink (runcode.cpp:116-140), never to stdout, so the protocol stream stays clean.
- Body wrapper: the body is async function body(gm, require, tjs) (runcode.cpp:375-388). tjs is a parameter, so it shadows txiki global tjs and a body cannot reach the global.
- Verbs: gm.<verb>(args) takes JSON and returns JSON. A failed verb returns {ok:false, error} and does not stop the body.

## 5. Build facts

- gm txiki core (native/components/quickjs/CMakeLists.txt): quickjs-ng as a static library from dtoa.c, libregexp.c, libunicode.c and quickjs.c; libuv through add_subdirectory (uv_a); gm_txiki from 25 txiki sources, deps/ada/ada.cpp and the glue; network, TLS, websocket, hashing, wasm, ffi, sqlite and miniz modules stubbed in txiki_stubs.c.
- fx: build.zig has no C yet. Available here: zig 0.17.0, cmake 4.2.3, gcc 15.2, node 24.22.
- Network: codeload.github.com streams the tarballs. A 20-second curl timeout cut a 3.8 MB transfer short, so vendoring needs a longer timeout and a sha256 check after download.

## 6. Plan

Phase A: (1) the shared vendor step: one pin file and one script, copied from gm and verified; (2) the txiki core built as a static library by cmake from build.zig, with the network modules stubbed; (3) a C shim and a Zig runner with the gm semantics in section 4; (4) run_code routed through the runner, with the old route and its fixtures kept; (5) witnesses in Phase B.

Open at Stage 0: the Cordis agent interface is not in this repo, so its side is specified only as "freddie hands fx JavaScript that runs inside txiki".
