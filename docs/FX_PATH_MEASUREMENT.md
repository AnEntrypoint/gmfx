# The fx path through the thebird page, measured (2026-11-12)

Question: is the fx path as efficient as possible? Path: the thebird page runs fx's wasm core in a worker and sends chat requests to the relay shim at `127.0.0.1:8793`.

Answer: on the fx and thebird side it is within 0.1 to 0.3 s per model turn of the shim's own floor. 95 to 99% of every ask is the wait for response headers from the shim, and the shim delivers each response in one burst, so the first token arrives with the last. Two things on our side cost visible time: the page prints nothing until the whole ask has ended, and a fresh page pays about 130 ms once.

Probe: `node benchmarks/thebird_ask_probe.mjs /workspace/thebird --runs 4 --out /tmp/fx-ask-probe-full.json`. It starts its own static server, logging proxy and Chromium and stops them by PID. Times are ms, median [min..max]. Page: 4 fresh-profile cold asks, 4 reloaded cold asks and 8 warm asks per prompt. Native: `fx ask --no-save` (ReleaseSafe), n=4, through the same proxy. Host load was 3 to 9 during the runs.

## Per ask

`fx ask reply with only the word ok`: 1 model turn, 0 tool calls.

| | page cold | page warm | native |
|---|---|---|---|
| HTTP requests | 3 (wasm, preflight, chat) | 1 (chat) | 1 (chat) |
| Enter to first token | 1891 [1578..2058] | 1633 [1450..2415] | 1718 [1532..1925] |
| Enter to final token | 1901 [1588..2074] | 1639 [1454..2417] | 1723 [1540..1936] |
| Request body | 649 B | 649 B | 39,795 B |

`fx ask run the command "echo probe-42" with the Bash tool and reply with its output`: 2 model turns, 1 tool call. The page's bash host tool is a stub that answers "bash is not available on the thebird page yet", so the page rows time the two-turn loop, not a command.

| | page cold | page warm | native |
|---|---|---|---|
| HTTP requests | 4 (wasm, preflight, chat 2) | 2 (chat 2) | 2 (chat 2) |
| Enter to first SSE byte | 2168 [1911..2748] | 1839 [1631..2069] | 2084 [2075..2853] |
| Enter to first visible character | 4459 [3817..4851] | 3702 [3352..4334] | 2084 [2076..2854] |
| Enter to final token | 4469 [3829..4863] | 3710 [3361..4335] | 4566 [3997..4766] |

No models-list, title or other request was made on either surface.

## Where each second goes

| Step | page cold | page warm | native |
|---|---|---|---|
| wasm fetch (2.89 MB), compile, instantiate | 10-13, 16-18, 3 | 0, 0, 0.4 | none |
| start to first chat request | 131-138 | 1.5-3.3 | 9 |
| request to response headers, turn 1 | 1724 to 1997 | 1626 [1442..2408] | 1708 to 2075 |
| headers to first content delta | 0.2-0.3 | 0.2 | 0.2-0.3 |
| streaming | 0.2-0.4 | 0.2-0.3 | 0.2-40 |
| tool result to next request (tool included) | 13-15 | 1.7 | 42 |
| request to response headers, turn 2 | 2001 | 1899 [1709..2296] | 2040 [1831..2578] |
| last byte to prompt | 13-18 | 5-10 | 4-7 |

Longest step: the wait for response headers from the shim, 1.6 s of a 1.64 s one-turn ask and 1.8 s plus 1.9 s of a 3.71 s two-turn ask. The shim's floor is 377 ms for `GET /v1/models` and 1351 ms for a minimal chat with no tools.

Prompt caching works upstream (a replay against 8792 read 9152 of 9274 input tokens from cache on the second call), but the shim reports `prompt_tokens: 0` on streamed responses and drops the cache fields.

## What is not as efficient as it could be

| # | Finding | Owner | Saving |
|---|---|---|---|
| 1 | The relay does not stream: each response arrives in one burst | hy4-relay | about 2 s to first token on a long reply, nothing on the total |
| 2 | The page shows nothing until the ask ends (`web/fx-in-page.js` `textOf` joins all deltas) | thebird | about 1.9 s to first visible text on a two-turn ask |
| 3 | First execution of fresh wasm costs 131 ms against 1.5-3 ms warm | thebird | about 130 ms per fresh page with a warm-up at idle |
| 4 | `fx-core.wasm` is fetched again on every page load: the static server sends no cache validators | thebird | 2.9 MB per visit on a real network |
| 5 | Native fx sends 39.8 KB per turn (system prompt 16 KB, 25 tool schemas 23.6 KB); cached upstream | fx | at most 0.1-0.2 s per turn |
| 6 | The shim hides usage and cache counts on streamed responses | hy4-relay | none in time; needed to see cost |

Not measured: time inside the relay tunnel against the model (both are behind 8792); real tool execution in the page (stub); the `fx-term.wasm` TUI path.

## The TUI wasm path

Probe: `node benchmarks/term_wasm_probe.mjs --runs 1 --skip native,browser --only-prompt tool --out /tmp/fx-measure-out/tui-tool.json` (node wasm, tool prompt, warm, n=1), and the full probe at `--runs 1` for the `hi` and `plain` prompts on the node and browser wasm surfaces. The full all-prompt run exceeded its 280 s bound before writing JSON, so only the rows named here were measured. Times are ms, single run, host load 8.2.

`run the command "echo probe-42" with your shell tool and reply with its output`: 2 model turns, 1 tool call (`shell`, exit 0), 0 retries, no errors.

| | node wasm, warm |
|---|---|
| HTTP requests | 2 (chat 2) |
| Enter to first request | 5.2 |
| Enter to first byte | 2022.6 |
| Enter to first visible character | 2076.5 |
| Enter to final token (last byte) | 3737.3 |
| Enter to ready frame | 3758.1 |
| Turn 1 time to first byte | 2016.9 |
| Last turn time to first byte | 1712 |
| Tool execution | 0 |
| Longest step | Turn 1 wait for response headers, 2016.9 |

Single-turn `hi` and `plain` on the same surfaces, n=1: node wasm first visible character 1933.9 to 2644.8 ms cold, 2222.9 to 8928.9 ms warm (one warm outlier); browser wasm 2014.6 to 3559.9 ms. The native `hi` cold run timed out in the probe, so it has no row. Like the page ask, nearly all of each turn is the wait for the shim's response headers. On the wasm side the Enter to request gap is about 5 ms and the content to visible gap is about 20 to 55 ms. The turn-1 request is 16,293 bytes, 14,948 of it system prompt.

Not measured: the all-prompt run, repeated runs for a stable median, and the `long` and `paced` prompts on the TUI wasm surface. Those need a run with a longer bound.
