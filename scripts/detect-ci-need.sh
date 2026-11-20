#!/usr/bin/env bash




































set -euo pipefail

if [ "$#" -ne 2 ]; then
  printf 'usage: %s <base-revision> <head-revision>\n' "$0" >&2
  exit 2
fi

base="$1"
head="$2"

libfx=false
mcp=false
transcript_window=false
libfx_reasons=()
mcp_reasons=()
transcript_window_reasons=()

require_libfx() {
  libfx=true
  libfx_reasons+=("$1")
}

require_mcp() {
  mcp=true
  mcp_reasons+=("$1")
}

require_transcript_window() {
  transcript_window=true
  transcript_window_reasons+=("$1")
}

require_all() {
  require_libfx "$1"
  require_mcp "$1"
  require_transcript_window "$1"
}

for revision in "$base" "$head"; do
  if ! git rev-parse --verify --quiet "$revision^{commit}" >/dev/null; then
    printf 'error: cannot read revision %s; CI cannot decide which checks to run\n' "$revision" >&2
    exit 1
  fi
done

if ! changed_files="$(git diff --name-only --no-renames "$base" "$head")"; then
  printf 'error: git diff %s %s failed; CI cannot decide which checks to run\n' "$base" "$head" >&2
  exit 1
fi

if [ -n "${CI_NEED_REQUESTED:-}" ]; then
  require_all "$CI_NEED_REQUESTED"
fi

while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in
    .github/workflows/ci.yml | scripts/detect-ci-need.sh)
      require_all "$path: the checks changed" ;;
    build.zig | build.zig.zon)
      require_all "$path: build configuration changed" ;;
    sdk/*)
      require_libfx "$path: libfx SDK changed" ;;
    tests/tla/sdk/*)
      require_libfx "$path: libfx model changed" ;;


    tests/tla/drivers/mcp/* | tests/tla/drivers/mcp_host/*)
      require_mcp "$path: MCP driver changed" ;;
    tests/tla/drivers/lib/*)
      require_mcp "$path: shared driver code changed"
      require_transcript_window "$path: shared driver code changed" ;;
    tests/tla/drivers/transcript_window/*)
      require_transcript_window "$path: transcript window driver changed" ;;
    tests/tla/drivers/graph.mjs)
      require_libfx "$path: shared driver code changed"
      require_transcript_window "$path: shared driver code changed" ;;
    tests/tla/drivers/*.mjs)

      if [[ "${path#tests/tla/drivers/}" != */* ]]; then
        require_libfx "$path: libfx driver changed"
      fi ;;
    src/napi_*.zig | src/wasm_core_main.zig)
      require_libfx "$path: libfx entry point changed" ;;
    src/acp/* | src/core/hosts/* | src/core/session_manager/*)
      require_libfx "$path: code libfx owns changed" ;;
    src/mcp/* | src/core/mcp_host/* | src/core/mcp/*)
      require_mcp "$path: MCP code changed" ;;
    tests/tla/mcp/* | tests/tla/mcp_host/*)
      require_mcp "$path: MCP model changed" ;;
    src/ui/transcript/transcript_window*)
      require_transcript_window "$path: transcript window code changed" ;;
    tests/tla/transcript_window/*)
      require_transcript_window "$path: transcript window model changed" ;;
    tests/e2e/fixtures/mcp-* | tests/e2e/tmux-helpers.ts | tests/evals/eval-helpers.ts | tests/e2e/render-lab/tape.ts)
      require_mcp "$path: a file the MCP drivers load changed" ;;
  esac
done <<<"$changed_files"



report() {
  local name="$1" needed="$2"
  shift 2
  if [ "$needed" = true ]; then
    printf '%s check needed:\n' "$name"
    printf '  %s\n' "$@"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      {
        printf '### %s check runs\n\n' "$name"
        printf -- '- %s\n' "$@"
        printf '\n'
      } >>"$GITHUB_STEP_SUMMARY"
    fi
  else
    printf 'No %s change; the %s check runs on main.\n' "$name" "$name"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      printf 'No %s change; the %s check runs on main.\n\n' "$name" "$name" >>"$GITHUB_STEP_SUMMARY"
    fi
  fi
}



report libfx "$libfx" ${libfx_reasons[@]+"${libfx_reasons[@]}"}
report MCP "$mcp" ${mcp_reasons[@]+"${mcp_reasons[@]}"}
report "transcript window" "$transcript_window" ${transcript_window_reasons[@]+"${transcript_window_reasons[@]}"}

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    printf 'libfx=%s\n' "$libfx"
    printf 'mcp=%s\n' "$mcp"
    printf 'transcript_window=%s\n' "$transcript_window"
  } >>"$GITHUB_OUTPUT"
fi
