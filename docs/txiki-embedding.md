# txiki.js embedding in fx: Stage 0 inventory

Stage 0 was an inventory; sections 1, 3 and 5 are updated to the current tree. Sources: fx, gm at /workspace/gm, thebird at /workspace/thebird.

## 1. The current run_code path

- fx embeds txiki. native/txiki/CMakeLists.txt builds quickjs-ng, libuv and the txiki core into libfx_txiki.a, libfx_quickjs_ng.a and libuv.a, with the network modules stubbed in native/txiki/glue/txiki_stubs.c. build.zig drives it (cmake -S native/txiki, target fx_txiki) and links the three archives into the fx exe. The step is part of the default exe and pgso test graph, not an opt-in step.
- The runner is src/core/runcode/ (runcode.zig, host_verbs.zig, imports.zig, resolve.zig, cordis/) over native/txiki/glue/runcode_shim.c. src/tools/runcode/run_code.zig is the model-facing run_code tool; every verb a body calls is dispatched through tool_dispatch.dispatchToolCall, the same entry as a model tool call, so the Zig permission gate decides each call.
- The command is `fx run-code --file <path>`, with `fx js <file>` as its short form. Flags: --deadline-ms, --format <esm|cjs> (a .mjs file defaults to esm), --permission-mode <ask|auto|yolo|dontAsk>. It prints one JSON line {ok, value | error, console, console_dropped} and exits 1 when the body fails.
- The earlier tool_dispatch.zig run_code fixtures remain as gate tests.

## 2. Tool registration: native Zig versus txiki

- Every registered tool is Zig. The names found by a search of src/core/tooling and src/core/tools (all .zig) are: read_file, write_file, edit_file, glob_files, grep_files, bash, shell, run_command, exa_search, vision, install_skill, select_tools, set_budget, workflow, agent, coder, reviewer, boss, capability_search, dynamic_tool. The gate-routed names are gm_run_code and playwriter_execute. run_code is now also a registered tool (src/tools/runcode/run_code.zig).
- Stays native Zig: every file, shell, search, network, permission and gate tool. The permission gate must run in Zig, before any JavaScript body can reach a tool.
- Moves into txiki: nothing existing moves. The new txiki-hosted pieces are (a) the run_code body runner, and (b) the agent side of Cordis, which freddie hands to fx and which runs as JavaScript inside txiki. Cordis is not rebuilt in Zig.
- LeafVerbs: the native tools above are exposed to a body as gm.<verb>(args), each call passing through the same gate as a model tool call.

## 3. The shared vendor step

fx runs gm's shared vendor step unchanged. gm replaced tools/vendor-txiki.mjs (sha256 dd5ac6de...) with tools/txiki/ in eb36a28, "one pin file and one vendor script for gm, thebird and fx". fx carries byte-identical copies taken from gm 2db01da:

| fx file | gm file | sha256 |
| --- | --- | --- |
| scripts/txiki/vendor.mjs | tools/txiki/vendor.mjs | 00316a7a1d7b8d7c5f35b4bb62a8de269086c5aefa7b2b08dfcc6bae59c6775e |
| scripts/txiki/pins.json | tools/txiki/pins.json | 5c1eb77bcebdbd77f4a0313c7f3dfbf961283fed91d0c2ee9793ffa3ab9104eb |
| scripts/txiki/patches/*.patch | tools/txiki/patches/*.patch | each pinned in pins.json |

- The archive pins are unchanged from fx's old scripts/txiki/pin.json: txiki.js v26.11.0 763025ac..., libuv dd9f081c f5185440..., quickjs-ng 7b5f588e f27b2e93.... pins.json also pins zstd v1.5.7 and brotli v1.1.0, the four patches (txiki-gm, txiki-worker-data, quickjs-async-frame, txiki-dns-flags), the host extras and the thebird browser port.
- The script resolves its default target as its own directory/../../native/third_party/txiki, so the same file works at gm tools/txiki/ and fx scripts/txiki/. The browser port (--browser --glue) and the host extras (--extras) are opt-in. fx uses neither, so it does not carry browser-stubs.mjs or extras/.
- What fx gains with the switch: the four patches, the zstd and brotli sources under native/third_party/txiki, ASCII normalisation, and MANIFEST.sha256 with --verify. The patches change only vendored txiki and quickjs-ng files and need no new host symbols. The first build after the switch confirms that.
- The old fx scripts/vendor-txiki.mjs (324930c6...) and scripts/txiki/pin.json are deleted. CI runs `node scripts/txiki/vendor.mjs` in .github/actions/setup-pgso/action.yml and in release.yml (build-macos-x86_64).
- scripts/check_vendor_txiki.py (python3 -I) records the two shared sha256 values and gm's commit. It fails when vendor.mjs or pins.json differs from them, or when a patch differs from its pin. It also takes directories as arguments, so `python3 -I scripts/check_vendor_txiki.py /workspace/gm/tools/txiki` checks gm against the same record. Tests: scripts/tests/test_vendor_txiki.py.
- To take a new gm vendor step: copy tools/txiki/{vendor.mjs,pins.json,patches/} over scripts/txiki/, update SHARED and GM_COMMIT in the check script, and re-vendor.

Needs from gm:

- gm: keep tools/txiki/vendor.mjs and pins.json as the one source, and report each change to fx so fx can update its copy and the record in scripts/check_vendor_txiki.py.
- gm: VERSION.txt names the paths tools/txiki/vendor.mjs and tools/txiki/patches/ even when the script runs from another repo. It could derive them from the script's own location. This is wording only; fx takes the file as it is.

Needs from thebird:

- thebird: replace scripts/vendor-txiki.mjs (208 lines, sha256 b9ccd3e955bbdab26075412472968d11a2639246fd89b8b7a086e21d64d598db, with inline TXIKI_VERSION and the LIBUV and QUICKJS_NG constants) with a byte-identical copy of gm tools/txiki/{vendor.mjs,pins.json,patches/,browser-stubs.mjs}, and run it with --browser --glue <its glue C file>. The browser-port files are already pinned in pins.json from thebird b5ec730.
- thebird: keep the sqlite and wasm reactor build, and its tjsWasmSha256 pin in scripts/txiki/pin.json, outside the shared script. Check the copy with the same two sha256 values.

## 4. gm semantics to keep (gm native/components/quickjs/engine.cpp, runcode.cpp, run_entry.cpp, include/gm/runcode.hpp)

- Per-call deadline: BodyControls.js_budget bounds the body (run_entry uses 120000 ms; the run_body default is 3600000 ms). JS_SetInterruptHandler enforces it (engine.cpp:47-67). A host call has its own deadline through deadlineCall (engine.cpp:147-161). Errors read "the body passed its JavaScript deadline of N ms" or "the call passed its deadline of N ms" (engine.cpp:437-444).
- Module loader: a tjs: specifier loads a txiki builtin (gm_txiki_load_builtin, engine.cpp:70-72). A node: specifier is refused with a message that points at gm.read_file and the other verbs (engine.cpp:74-76). A disk module compiles as an ES module (engine.cpp:78-87).
- Console: console.log/info/debug/warn/error write to a ConsoleBuffer sink (runcode.cpp:116-140), never to stdout, so the protocol stream stays clean.
- Body wrapper: the body is async function body(gm, require, tjs) (runcode.cpp:375-388). tjs is a parameter, so it shadows txiki global tjs and a body cannot reach the global.
- Verbs: gm.<verb>(args) takes JSON and returns JSON. A failed verb returns {ok:false, error} and does not stop the body.

## 5. Build facts

- Present: native/txiki (cmake) driven from build.zig, the glue in native/txiki/glue, the vendored tree in native/third_party/txiki with VERSION.txt.
- Toolchain on this host: zig 0.17.0, cmake 4.2.3, gcc 15.2, node 24.22.
- Network: codeload.github.com streams the tarballs. A 20-second curl timeout cut a 3.8 MB transfer short, so vendoring needs a longer timeout and a sha256 check after download.

## 6. Stage 1 status

| Item | Present | Added now | Needs the gated build window |
| --- | --- | --- | --- |
| Shared pin file and vendor script | scripts/txiki/{vendor.mjs,pins.json,patches/}, byte-identical to gm 2db01da tools/txiki | scripts/check_vendor_txiki.py and its tests | re-vendoring with the shared script and building; thebird adopting it |
| txiki core as static libraries | native/txiki/CMakeLists.txt, build.zig step, glue | none | a build to confirm the archives link |
| C shim and Zig runner | runcode_shim.c, src/core/runcode, src/tools/runcode | none | running the runner tests |
| Deadline, node: refusal, console sink | in runcode_shim.c and runcode.zig | none | scripts/txiki-witness.sh deadline check |
| Permission gate on every verb | invokeVerb in src/tools/runcode/run_code.zig through dispatchToolCall | none | scripts/txiki-witness.sh gate check |
| fx run-code command | src/builtins/commands.zig row, main.zig branch | fx js <file> alias, positional file, .mjs defaults to esm, isCliToken, parse tests | one-line hook in main.zig, then a build |
| Witness script | none | scripts/txiki-witness.sh | running it against a built fx |
| Cordis agent side | src/core/runcode/cordis | none | an end-to-end run with freddie |

The fx js hook in src/main.zig (the run-code branch near line 3901) changes `std.mem.eql(u8, cli_args[0], "run-code")` to `run_code_tool.isCliToken(cli_args[0])`. scripts/cli_shape_registry.json may need a js entry if its checker lists top-level tokens.

Open: the Cordis agent interface is not in this repo, so its side is specified only as "freddie hands fx JavaScript that runs inside txiki".
