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

## 3. The shared vendor step and where fx diverges from gm

- fx: scripts/vendor-txiki.mjs (99 lines, sha256 324930c619a8199305b5a496ff1450835234f4859ea48be2d9c367573b80bdac) reads scripts/txiki/pin.json (txiki v26.11.0, libuv dd9f081c, quickjs-ng 7b5f588e, each with url and sha256) and takes `--pin <file>`.
- gm: tools/vendor-txiki.mjs (149 lines, sha256 dd5ac6deb2f2017184e06d9ce9b4c5af0f632854cf971f5eb0b40684a575e432) hard-codes the same three pins and values.
- thebird: scripts/vendor-txiki.mjs (208 lines, sha256 b9ccd3e955bbdab26075412472968d11a2639246fd89b8b7a086e21d64d598db) exports the pins as constants, adds a sqlite and wasm build, and pins the wasm variant in scripts/txiki/pin.json.
- The three pinned archive sha256 values are identical in all three repos.

Differences between fx 324930c6 and gm dd5ac6de:

- Pins: fx loads JSON from --pin or scripts/txiki/pin.json; gm has an inline PINS array.
- ASCII normalisation: gm has TEXT_SOURCE, ASCII_FOR, withoutComments and asciiCopy, which rewrite non-ASCII characters in comments and licence text and refuse non-ASCII in code. fx copies verbatim.
- Browser port: gm has BROWSER_PORT (four thebird files with sha256 each), checks them in the target, and runs tools/browser-stubs.mjs to generate browser/stubs.c, whose sha256 it records. fx has no browser port and no generated stubs; its stubs are hand-written in native/txiki/glue/txiki_stubs.c.
- Layout constants: fx lists TXIKI_BUNDLES over several lines and moves LIBUV_BUILD_FILES; the lists carry the same entries.
- Run helper: timeout 900000 ms in fx against 600000 in gm; the error and the final log line are built by string concatenation in fx and by template literals in gm; gm also logs the count of normalised characters and prefixes the log with its TOOL name.
- VERSION.txt: the wording and the list of left-out modules differ.
- Neither pin file records a sha256 for the stubbed or patched files (gm: txiki_stubs.c, the overlay headers; fx: native/txiki/glue/*).

Needs from gm and thebird to adopt one script and one pin file:

- gm: replace the inline PINS array with the shared pin file; keep BROWSER_PORT and the stubs step as optional pin-file sections so fx can leave them out; move the ASCII normalisation behind a flag, or have fx adopt it.
- thebird: replace the exported constants with the same pin file; keep the sqlite and wasm build outside the shared script; pin its stubs.tsv by sha256 in the pin file.
- All three: add per-file sha256 entries for the stub and overlay files to the pin file, and agree on one stub list (gm: txiki_stubs.c, fx: native/txiki/glue/txiki_stubs.c, thebird: stubs.tsv).
- Decide which repo owns the script and the pin, and have the others copy it with a sha256 check.

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
| Shared pin file and vendor script | scripts/txiki/pin.json, scripts/vendor-txiki.mjs (--pin) | divergence from gm recorded in section 3 | gm and thebird adopting the pin and script |
| txiki core as static libraries | native/txiki/CMakeLists.txt, build.zig step, glue | none | a build to confirm the archives link |
| C shim and Zig runner | runcode_shim.c, src/core/runcode, src/tools/runcode | none | running the runner tests |
| Deadline, node: refusal, console sink | in runcode_shim.c and runcode.zig | none | scripts/txiki-witness.sh deadline check |
| Permission gate on every verb | invokeVerb in src/tools/runcode/run_code.zig through dispatchToolCall | none | scripts/txiki-witness.sh gate check |
| fx run-code command | src/builtins/commands.zig row, main.zig branch | fx js <file> alias, positional file, .mjs defaults to esm, isCliToken, parse tests | one-line hook in main.zig, then a build |
| Witness script | none | scripts/txiki-witness.sh | running it against a built fx |
| Cordis agent side | src/core/runcode/cordis | none | an end-to-end run with freddie |

The fx js hook in src/main.zig (the run-code branch near line 3901) changes `std.mem.eql(u8, cli_args[0], "run-code")` to `run_code_tool.isCliToken(cli_args[0])`. scripts/cli_shape_registry.json may need a js entry if its checker lists top-level tokens.

Open: the Cordis agent interface is not in this repo, so its side is specified only as "freddie hands fx JavaScript that runs inside txiki".
