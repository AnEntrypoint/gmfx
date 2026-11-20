#!/usr/bin/env python3
import argparse
import fcntl
import hashlib
import http.server
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import re
import select
import shutil
import signal
import statistics
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time

MANIFEST_NAME = "manifest.json"
GATEWAY_MODEL = "openai/gpt-5.5"
MODELS_PATH = "/coding-agent/v1/models"
CHAT_PATH = "/v4/ai/language-model"
EVALUATION_PATH = "/v4/ai/evaluation-model"
TITLE_GENERATION_MARKER = "Generate a short title"
PERMISSION_DECISION_MARKER = '"permission_decision"'
FIRST_FRAME_MARKER = "Run /help"
SCRUBBED_ENV_PREFIXES = ("FX_", "OPENAI_", "GROK_", "XAI_", "AI_GATEWAY_", "VERCEL_", "ANTHROPIC_", "KIMI_")
STARTUP_SETTINGS = {
    "model": "openai/gpt-5.4",
    "effort": "high",
    "fast_mode": False,
    "startup_scrollback": True,
    "prompt_history": {"enabled": True},
    "statusLine": {"sandbox": True, "context": True},
    "permission": {"bash": {"git status *": "allow"}},
}
GATEWAY_SETTINGS = {"provider": "gateway", "model": GATEWAY_MODEL, "max_agent_steps": 0, "session_titles": False}
UI_ACTIVITY_BINARY = "ui-activity-progress-bench"
APPROVAL_REVIEW_BINARY = "approval-review-bench"
FILE_INDEX_BINARY = "file-index-bench"
FILE_INDEX_OWN_BUDGET_VERDICT = "latency gate: FAIL"
APPROVAL_REVIEW_SCENARIOS = ("transcript", "diff", "combined", "payload", "edge")
DURATION_UNIT_MILLISECONDS = {"us": 0.001, "ms": 1.0, "s": 1000.0}
WAIT_CPU_STATES = (
    "wait_cpu.idle_fresh_prompt",
    "wait_cpu.idle_after_turn",
    "wait_cpu.model_reply_held",
    "wait_cpu.foreground_bash",
    "wait_cpu.waitfor_background_task",
    "wait_cpu.idle_after_printed_output",
)
PRINTED_OUTPUT_COMMAND = "for i in $(seq 1 40); do echo printed-line-$i; done"
ESCAPE_SEQUENCE = re.compile(rb"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-?]*[ -/]*[@-~]|\x1b[PX^_][^\x1b]*\x1b\\|\x1b[@-Z\\-_]|\s+")
CLOCK_TICKS_PER_SECOND = os.sysconf("SC_CLK_TCK")
SCRIPT_DIRECTORY = Path(__file__).resolve().parent


class StepTimeout(Exception):
    pass


class Reporter:
    def __init__(self, out_path, only):
        self.only = only
        self.ok_count = 0
        self.handle = None
        if out_path:
            Path(out_path).resolve().parent.mkdir(parents=True, exist_ok=True)
            self.handle = open(out_path, "w")

    def wants_group(self, group):
        if not self.only:
            return True
        return any(name == group or name.startswith(group + ".") or group.startswith(name + ".") for name in self.only)

    def wants_config(self, config):
        if not self.only:
            return True
        return any(config == name or config.startswith(name + ".") for name in self.only)

    def emit(self, config, unit, samples, ok=True, note="", headline=None, force=False):
        if not force and not self.wants_config(config):
            return
        values = [round(float(value), 3) for value in samples]
        usable = ok and bool(values)
        line = {
            "config": config,
            "unit": unit,
            "samples": values,
            "median": None,
            "min": None,
            "max": None,
            "spread": None,
            "runs": len(values),
            "ok": usable,
            "note": note if usable or note else "no samples",
        }
        if values:
            line["median"] = round(statistics.median(values) if headline is None else float(headline), 3)
            line["min"] = min(values)
            line["max"] = max(values)
            line["spread"] = round(max(values) - min(values), 3)
        if usable:
            self.ok_count += 1
        text = json.dumps(line)
        print(text, flush=True)
        if self.handle:
            self.handle.write(text + "\n")
            self.handle.flush()

    def record_payload(self, manifest):
        line = {
            "config": "payload",
            "ok": True,
            "run_id": manifest.get("run_id"),
            "git": manifest.get("git"),
            "files": len(manifest["entries"]),
            "bytes": sum(entry["bytes"] for entry in manifest["entries"]),
            "host": host_description(),
            "note": "every file matched its manifest size and sha256",
        }
        text = json.dumps(line)
        print(text, flush=True)
        if self.handle:
            self.handle.write(text + "\n")
            self.handle.flush()

    def fail(self, config, unit, reason, force=False):
        self.emit(config, unit, [], ok=False, note=reason, force=force)

    def close(self):
        if self.handle:
            self.handle.close()


def host_description():
    try:
        models = sorted(set(re.findall(r"model name\s*:\s*(.+)", Path("/proc/cpuinfo").read_text())))
    except OSError:
        models = []
    return {
        "cpu_models": models,
        "cpus": os.cpu_count(),
        "usable_cpus": len(os.sched_getaffinity(0)),
        "kernel": platform.release(),
        "libc": " ".join(platform.libc_ver()),
        "python": platform.python_version(),
    }


def file_sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def manifest_entries(payload):
    manifest = json.loads((payload / MANIFEST_NAME).read_text())
    return manifest["entries"] if isinstance(manifest, dict) else manifest


def entry_mismatch(payload, entry):
    path = payload / entry["path"]
    if not path.is_file():
        return f"{entry['path']} is missing"
    size = path.stat().st_size
    if size != entry["bytes"]:
        return f"{entry['path']} is {size} bytes, manifest says {entry['bytes']}"
    digest = file_sha256(path)
    if digest != entry["sha256"]:
        return f"{entry['path']} sha256 {digest} differs from manifest {entry['sha256']}"
    return None


def payload_mismatches(payload):
    return [problem for problem in (entry_mismatch(payload, entry) for entry in manifest_entries(payload)) if problem]


def companion_script(name, payload):
    roots = ([payload] if payload else []) + [SCRIPT_DIRECTORY, SCRIPT_DIRECTORY.parent]
    for root in roots:
        candidate = root / name
        if candidate.is_file():
            return candidate
    return None


def load_companion_module(name, payload):
    path = companion_script(name + ".py", payload)
    if path is None:
        return None
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def scrubbed_environment():
    env = {key: value for key, value in os.environ.items() if not key.startswith(SCRUBBED_ENV_PREFIXES)}
    for key in ("TMUX", "ZDOTDIR", "BASH_ENV", "ENV"):
        env.pop(key, None)
    env.setdefault("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
    env["FX_AUTO_UPGRADE"] = "0"
    env["FX_SOUND"] = "0"
    env["FX_DISABLE_KEYCHAIN"] = "1"
    return env


def gateway_environment(home, base_url):
    env = scrubbed_environment()
    env.update(
        HOME=str(home),
        AI_GATEWAY_API_KEY="fixture-key",
        FX_GATEWAY_BASE_URL=base_url,
        FX_GATEWAY_CHAT_URL=base_url + CHAT_PATH,
        FX_TEST_GATEWAY_CHAT_URL=base_url + CHAT_PATH,
        FX_TEST_GATEWAY_MODELS_URL=base_url + MODELS_PATH,
        FX_MODEL=GATEWAY_MODEL,
        FX_MAX_AGENT_STEPS="0",
        FX_PERMISSION_MODE="yolo",
        KIMI_CODE_TRUST_WORKSPACE="1",
    )
    return env


def write_gateway_home(root):
    home, workspace = root / "home", root / "workspace"
    (home / ".fx").mkdir(parents=True, mode=0o700)
    (home / ".fx/settings.json").write_text(json.dumps(GATEWAY_SETTINGS))
    workspace.mkdir()
    return home, workspace


def sse_body(events):
    return ("".join("data: " + json.dumps(event) + "\n\n" for event in events) + "data: [DONE]\n\n").encode()


def finish_event(reason):
    return {
        "type": "finish",
        "finishReason": {"unified": reason, "raw": reason},
        "usage": {"inputTokens": {"total": 3}, "outputTokens": {"total": 5}},
    }


def tool_call_events(call_id, tool_name, tool_input):
    return [{"type": "tool-call", "toolCallId": call_id, "toolName": tool_name, "input": tool_input}, finish_event("tool-calls")]


def final_text_events(text):
    return [{"type": "text-delta", "id": "answer_1", "delta": text}, finish_event("stop")]


class HeldReply:
    def __init__(self, text, keep_alive_seconds=0.05):
        self.text = text
        self.keep_alive_seconds = keep_alive_seconds
        self.released = threading.Event()

    def release(self):
        self.released.set()


class ScriptedGateway:
    def __init__(self, respond):
        self.respond = respond
        self.lock = threading.Lock()
        self.arrivals = []
        self.handled = []
        self.bodies_seen = 0
        gateway = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"
            disable_nagle_algorithm = True

            def log_message(self, *_):
                pass

            def reply(self, data, content_type):
                self.send_response(200)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                self.wfile.flush()

            def chunk(self, data):
                self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n")
                self.wfile.flush()

            def stream_held(self, held):
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                try:
                    self.chunk(b": hold-response\n\n")
                    while not held.released.wait(held.keep_alive_seconds):
                        self.chunk(b": hold-response\n\n")
                    self.chunk(sse_body(final_text_events(held.text)))
                    self.wfile.write(b"0\r\n\r\n")
                    self.wfile.flush()
                except OSError:
                    self.close_connection = True

            def do_GET(self):
                models = {"object": "list", "data": [{"id": GATEWAY_MODEL, "type": "language", "tags": ["tool-use"], "context_window": 1000000}]}
                self.reply(json.dumps(models).encode(), "application/json")

            def do_POST(self):
                arrival = time.monotonic()
                body = self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode("utf-8", "replace")
                if self.path.startswith(EVALUATION_PATH):
                    answer = {"answers": {"decision": {"type": "choice", "choice": "clear", "probabilities": {"clear": 0.99, "caution": 0.01}}}, "usage": {"inputTokens": 100, "outputTokens": 10}, "warnings": []}
                    self.reply(json.dumps(answer).encode(), "application/json")
                    return
                if PERMISSION_DECISION_MARKER in body:
                    decision = {"risk": "low", "decision": "clear", "rationale": "benchmark fixture"}
                    self.reply(sse_body(tool_call_events("permission_decision_1", "permission_decision", decision)), "text/event-stream")
                    return
                if TITLE_GENERATION_MARKER in body:
                    self.reply(sse_body([finish_event("stop")]), "text/event-stream")
                    return
                with gateway.lock:
                    index = len(gateway.arrivals)
                    gateway.arrivals.append(arrival)
                    gateway.handled.append(None)
                    answer = gateway.respond(index, body)
                if isinstance(answer, HeldReply):
                    self.stream_held(answer)
                else:
                    self.reply(sse_body(answer), "text/event-stream")
                gateway.handled[index] = time.monotonic()

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.base_url = f"http://127.0.0.1:{self.server.server_port}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def request_count(self):
        return len(self.arrivals)

    def stop(self):
        self.server.shutdown()
        self.server.server_close()


class PromptScripts:
    def __init__(self):
        self.replies = {}
        self.requests = {}

    def script(self, prompt, replies):
        self.replies[prompt] = list(replies)
        self.requests[prompt] = 0

    def respond(self, _index, body):
        newest = max(self.replies, key=body.rfind, default=None)
        if newest is None or body.rfind(newest) < 0:
            return final_text_events("UNSCRIPTED PROMPT")
        self.requests[newest] += 1
        remaining = self.replies[newest]
        return remaining.pop(0) if remaining else final_text_events("UNSCRIPTED REQUEST")


class PtySession:
    def __init__(self, argv, cwd, env, query_replies, rows=48, cols=120):
        self.query_replies = query_replies
        self.master, slave = os.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

        def become_session_leader():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        self.process = subprocess.Popen(argv, cwd=cwd, env=env, stdin=slave, stdout=slave, stderr=slave, preexec_fn=become_session_leader, close_fds=True)
        os.close(slave)
        self.pid = self.process.pid
        self.raw = bytearray()
        self.mark = 0
        self.last_output = time.monotonic()

    def read_available(self, timeout):
        ready, _, _ = select.select([self.master], [], [], max(0.0, timeout))
        if not ready:
            return False
        try:
            data = os.read(self.master, 65536)
        except OSError:
            data = b""
        if not data:
            time.sleep(min(0.02, max(0.0, timeout)))
            return False
        self.raw += data
        self.last_output = time.monotonic()
        answer = self.query_replies(data)
        if answer:
            os.write(self.master, answer)
        return True

    def pump(self, seconds):
        deadline = time.monotonic() + seconds
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return
            self.read_available(remaining)

    def wait_until(self, condition, timeout, label):
        deadline = time.monotonic() + timeout
        while not condition():
            if self.process.poll() is not None:
                raise StepTimeout(f"fx exited with {self.process.returncode} while waiting for {label}: {self.tail()}")
            if time.monotonic() > deadline:
                raise StepTimeout(f"timed out after {timeout:g}s waiting for {label}: {self.tail()}")
            self.read_available(0.02)

    def visible_since_mark(self):
        return ESCAPE_SEQUENCE.sub(b"", bytes(self.raw[self.mark:]))

    def tail(self):
        return self.visible_since_mark()[-160:].decode("utf-8", "replace")

    def shows(self, text):
        needle = text.encode()
        return needle in self.raw[self.mark:] or re.sub(rb"\s+", b"", needle) in self.visible_since_mark()

    def wait_for_text(self, text, timeout):
        self.wait_until(lambda: self.shows(text), timeout, f"text {text!r}")

    def wait_for_quiet(self, quiet_seconds, timeout):
        deadline = time.monotonic() + timeout
        self.last_output = time.monotonic()
        while time.monotonic() - self.last_output < quiet_seconds and time.monotonic() < deadline:
            self.read_available(0.05)

    def submit(self, text):
        self.mark = len(self.raw)
        os.write(self.master, text.encode())
        self.pump(0.1)
        os.write(self.master, b"\r")

    def close(self):
        if self.process.poll() is None:
            try:
                os.write(self.master, b"\x15/quit\r")
            except OSError:
                pass
            deadline = time.monotonic() + 5
            while self.process.poll() is None and time.monotonic() < deadline:
                self.read_available(0.05)
        if self.process.poll() is None:
            try:
                os.killpg(self.pid, signal.SIGKILL)
            except OSError:
                self.process.kill()
        self.process.wait()
        os.close(self.master)


def thread_ticks(pid):
    ticks = {}
    for tid in os.listdir(f"/proc/{pid}/task"):
        try:
            fields = Path(f"/proc/{pid}/task/{tid}/stat").read_text().rsplit(") ", 1)[1].split(" ")
        except (OSError, IndexError):
            continue
        ticks[tid] = int(fields[11]) + int(fields[12])
    return ticks


def voluntary_switches(pid):
    status = Path(f"/proc/{pid}/task/{pid}/status").read_text()
    return int(re.search(r"voluntary_ctxt_switches:\s+(\d+)", status).group(1))


def descendant_commands(root_pid):
    parents, commands = {}, {}
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        try:
            stat = Path(f"/proc/{name}/stat").read_text()
        except OSError:
            continue
        command = stat[stat.index("(") + 1:stat.rindex(")")]
        parents[int(name)] = int(stat.rsplit(") ", 1)[1].split(" ")[1])
        commands[int(name)] = command
    found = []
    for pid in parents:
        ancestor = parents.get(pid)
        while ancestor and ancestor != root_pid:
            ancestor = parents.get(ancestor)
        if ancestor == root_pid:
            found.append(commands[pid])
    return found


def sample_cpu(session, seconds):
    ticks_before = thread_ticks(session.pid)
    switches_before = voluntary_switches(session.pid)
    started = time.monotonic()
    session.pump(seconds)
    elapsed = time.monotonic() - started
    ticks_after = thread_ticks(session.pid)
    used = sum(max(0, value - ticks_before.get(tid, 0)) for tid, value in ticks_after.items())
    return {
        "percent": used / CLOCK_TICKS_PER_SECOND / elapsed * 100,
        "wakes_per_second": (voluntary_switches(session.pid) - switches_before) / elapsed,
        "threads": len(ticks_after),
    }


def wait_cpu_round(fx, query_replies, sample_seconds, settle_seconds, measured):
    sleep_seconds = math.ceil(sample_seconds + settle_seconds + 13)
    scripts = PromptScripts()
    held = HeldReply("HELDDONE")
    scripts.script("Say hello.", [final_text_events("HELLODONE")])
    scripts.script("Hold the model.", [held])
    scripts.script("Run the long command.", [
        tool_call_events("long-cmd", "Bash", {"command": f"sleep {sleep_seconds}", "description": "Sleep"}),
        final_text_events("LONGDONE"),
    ])
    scripts.script("Start a task and wait.", [
        tool_call_events("bg", "Bash", {"command": f"sleep {sleep_seconds}", "run_in_background": True, "description": "Sleep in background"}),
        tool_call_events("wait", "WaitFor", {"timeout": 60}),
        final_text_events("WAITEDDONE"),
    ])
    scripts.script("Print some lines.", [
        tool_call_events("printed", "Bash", {"command": PRINTED_OUTPUT_COMMAND, "description": "Print lines"}),
        final_text_events("PRINTEDDONE"),
    ])
    gateway = ScriptedGateway(scripts.respond)
    root = Path(tempfile.mkdtemp(prefix="fx-bench-wait-cpu-"))
    home, workspace = write_gateway_home(root)
    env = gateway_environment(home, gateway.base_url)
    env["TERM"] = "xterm-256color"
    env.setdefault("TERM_PROGRAM", "ghostty")
    session = PtySession([fx], str(workspace), env, query_replies)

    def record(state):
        measured.setdefault(state, []).append(sample_cpu(session, sample_seconds))

    def begin_turn(prompt, requests):
        session.submit(prompt)
        session.wait_until(lambda: scripts.requests[prompt] >= requests, 30, f"gateway request {requests} for {prompt!r}")

    def end_turn(answer, timeout):
        session.wait_for_text(answer, timeout)
        session.wait_for_quiet(1.0, 10)

    try:
        session.wait_for_text(FIRST_FRAME_MARKER, 30)
        session.wait_for_quiet(1.0, 10)
        record("wait_cpu.idle_fresh_prompt")

        begin_turn("Say hello.", 1)
        end_turn("HELLODONE", 30)
        record("wait_cpu.idle_after_turn")

        begin_turn("Hold the model.", 1)
        session.pump(settle_seconds)
        record("wait_cpu.model_reply_held")
        held.release()
        end_turn("HELDDONE", 30)

        begin_turn("Run the long command.", 1)
        session.wait_until(lambda: "sleep" in descendant_commands(session.pid), 15, "the foreground sleep process")
        session.pump(settle_seconds)
        record("wait_cpu.foreground_bash")
        end_turn("LONGDONE", sleep_seconds + 60)

        begin_turn("Start a task and wait.", 2)
        session.pump(settle_seconds)
        record("wait_cpu.waitfor_background_task")
        end_turn("WAITEDDONE", sleep_seconds + 60)

        begin_turn("Print some lines.", 2)
        end_turn("PRINTEDDONE", 60)
        session.pump(settle_seconds)
        record("wait_cpu.idle_after_printed_output")
    finally:
        held.release()
        session.close()
        gateway.stop()
        shutil.rmtree(root, ignore_errors=True)


def run_wait_cpu(reporter, fx, payload, rounds, sample_seconds, settle_seconds):
    first_frame = load_companion_module("first_frame", payload)
    if first_frame is None:
        for state in WAIT_CPU_STATES:
            reporter.fail(state, "percent_of_core", "first_frame.py not found")
        return
    measured, failures = {}, []
    for _ in range(rounds):
        try:
            wait_cpu_round(fx, first_frame.query_replies, sample_seconds, settle_seconds, measured)
        except (StepTimeout, OSError) as error:
            failures.append(str(error))
    for state in WAIT_CPU_STATES:
        samples = measured.get(state, [])
        if not samples:
            reporter.fail(state, "percent_of_core", failures[0] if failures else "not reached")
            continue
        wakes = statistics.median(sample["wakes_per_second"] for sample in samples)
        note = f"main thread voluntary context switches {wakes:.1f}/s; {samples[0]['threads']} threads; {sample_seconds:g}s sample after {settle_seconds:g}s settle"
        if len(samples) < rounds:
            note += f"; {rounds - len(samples)} of {rounds} rounds failed: {failures[0] if failures else 'unknown'}"
        reporter.emit(state, "percent_of_core", [sample["percent"] for sample in samples], ok=len(samples) == rounds, note=note)


def timed_spawn(argv, env, cwd, null_fd):
    actions = [(os.POSIX_SPAWN_DUP2, null_fd, 0), (os.POSIX_SPAWN_DUP2, null_fd, 1), (os.POSIX_SPAWN_DUP2, null_fd, 2)]
    previous = os.getcwd()
    os.chdir(cwd)
    try:
        started = time.perf_counter()
        pid = os.posix_spawn(argv[0], argv, env, file_actions=actions)
        _, status = os.waitpid(pid, 0)
        elapsed = time.perf_counter() - started
    finally:
        os.chdir(previous)
    return elapsed * 1000, status


def run_startup(reporter, fx, payload, repeats, warmup):
    root = Path(tempfile.mkdtemp(prefix="fx-bench-startup-"))
    general_home, session_home, workspace = root / "general-home", root / "session-home", root / "workspace"
    (general_home / ".fx").mkdir(parents=True, mode=0o700)
    settings = general_home / ".fx/settings.json"
    settings.write_text(json.dumps(STARTUP_SETTINGS) + "\n")
    settings.chmod(0o600)
    session_home.mkdir()
    workspace.mkdir()
    fixture = companion_script("session_list_fixture.py", payload)
    session_note = ""
    if fixture is None:
        session_note = "session_list_fixture.py not found: listed an empty session store"
    else:
        generated = subprocess.run([sys.executable, str(fixture), "--home", str(session_home), "--workspace", str(workspace)], capture_output=True, text=True)
        if generated.returncode != 0:
            session_note = f"session fixture failed: {generated.stderr.strip()[-200:]}"
    true_binary = next((path for path in ("/usr/bin/true", "/bin/true") if os.access(path, os.X_OK)), None)
    commands = [
        ("startup.true_baseline", [true_binary] if true_binary else None, general_home, {}, "process spawn baseline"),
        ("startup.bare_fx_bench", [fx], general_home, {"FX_BENCH": "1"}, "fx with FX_BENCH=1, the startup.sh 'fx (startup)' row"),
        ("startup.version", [fx, "--version"], general_home, {}, ""),
        ("startup.help", [fx, "--help"], general_home, {}, ""),
        ("startup.help_command", [fx, "help"], general_home, {}, "the startup.sh 'fx help' row"),
        ("startup.status_json", [fx, "status", "--json"], general_home, {}, ""),
        ("startup.sessions_json", [fx, "sessions", "--json"], session_home, {}, session_note),
        ("startup.doctor_json", [fx, "doctor", "--json"], general_home, {}, ""),
    ]
    null_fd = os.open(os.devnull, os.O_RDWR)
    try:
        for config, argv, home, extra_env, note in commands:
            if not reporter.wants_config(config):
                continue
            if argv is None:
                reporter.fail(config, "ms", "no true binary found")
                continue
            env = scrubbed_environment()
            env.update(extra_env, HOME=str(home))
            try:
                for _ in range(warmup):
                    timed_spawn(argv, env, str(workspace), null_fd)
                runs = [timed_spawn(argv, env, str(workspace), null_fd) for _ in range(repeats)]
            except OSError as error:
                reporter.fail(config, "ms", f"spawn failed: {error}")
                continue
            failed = [status for _, status in runs if status != 0]
            if failed:
                note = f"{len(failed)} of {len(runs)} runs exited with wait status {failed[0]}" + (f"; {note}" if note else "")
            reporter.emit(config, "ms", [elapsed for elapsed, _ in runs], ok=not failed, note=note)
    finally:
        os.close(null_fd)
        shutil.rmtree(root, ignore_errors=True)


def launch_to_first_frame(fx, cwd, env, query_replies, window_seconds, rows=50, cols=200):
    master, slave = os.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    def become_session_leader():
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)

    started = time.perf_counter()
    process = subprocess.Popen([fx], cwd=cwd, env=env, stdin=slave, stdout=slave, stderr=slave, preexec_fn=become_session_leader, close_fds=True)
    os.close(slave)
    marker = FIRST_FRAME_MARKER.encode()
    first_frame = end_of_input_sent = None
    seen = b""
    while True:
        if end_of_input_sent is None and time.perf_counter() - started >= window_seconds:
            os.write(master, b"\x04\x04")
            end_of_input_sent = time.perf_counter()
        ready, _, _ = select.select([master], [], [], 0.02)
        if ready:
            try:
                data = os.read(master, 65536)
            except OSError:
                data = b""
            if data:
                stamp = time.perf_counter()
                seen = (seen + data)[-65536:]
                answer = query_replies(data)
                if answer:
                    os.write(master, answer)
                if first_frame is None and marker in seen:
                    first_frame = stamp
        pid, status, usage = os.wait4(process.pid, os.WNOHANG)
        if pid:
            break
        if end_of_input_sent is not None and time.perf_counter() - end_of_input_sent > 10:
            process.kill()
            _, _, usage = os.wait4(process.pid, 0)
            status = -9
            break
    process.returncode = status
    os.close(master)
    peak_rss_bytes = usage.ru_maxrss * (1024 if sys.platform.startswith("linux") else 1)
    return {
        "first_frame_ms": None if first_frame is None else (first_frame - started) * 1000,
        "cpu_ms": (usage.ru_utime + usage.ru_stime) * 1000,
        "max_rss_mib": peak_rss_bytes / (1024 * 1024),
        "status": status,
    }


def run_first_frame(reporter, fx, payload, repeats, warmup, window_seconds):
    configs = (("first_frame.p50", "ms"), ("first_frame.p95", "ms"), ("first_frame.cpu_ms", "ms"), ("first_frame.rss_mib", "mib"))
    first_frame = load_companion_module("first_frame", payload)
    if first_frame is None:
        for config, unit in configs:
            reporter.fail(config, unit, "first_frame.py not found")
        return
    root = Path(tempfile.mkdtemp(prefix="fx-bench-first-frame-"))
    home, workspace = root / "home", root / "workspace"
    home.mkdir()
    workspace.mkdir()
    env = scrubbed_environment()
    env.update(HOME=str(home), TERM="xterm-256color", KIMI_CODE_TRUST_WORKSPACE="1")
    env.setdefault("TERM_PROGRAM", "ghostty")
    try:
        for _ in range(warmup):
            launch_to_first_frame(fx, str(workspace), env, first_frame.query_replies, window_seconds)
        samples = [launch_to_first_frame(fx, str(workspace), env, first_frame.query_replies, window_seconds) for _ in range(repeats)]
    except OSError as error:
        for config, unit in configs:
            reporter.fail(config, unit, f"launch failed: {error}")
        return
    finally:
        shutil.rmtree(root, ignore_errors=True)
    frames = [sample["first_frame_ms"] for sample in samples if sample["first_frame_ms"] is not None]
    failed = sum(1 for sample in samples if sample["status"] != 0)
    missing = len(samples) - len(frames)
    healthy = not failed and not missing
    problem = "" if healthy else f"{failed} launches failed, {missing} showed no frame; "
    method = f"pty launch to the {FIRST_FRAME_MARKER!r} frame, empty HOME, {window_seconds:g}s window"
    reporter.emit("first_frame.p50", "ms", frames, ok=healthy, note=problem + method, headline=first_frame.percentile(frames, 50))
    reporter.emit("first_frame.p95", "ms", frames, ok=healthy, note=problem + "the median field holds the nearest-rank p95 of the samples", headline=first_frame.percentile(frames, 95))
    reporter.emit("first_frame.cpu_ms", "ms", [sample["cpu_ms"] for sample in samples], ok=healthy, note=problem + "user plus system CPU of the whole launch")
    reporter.emit("first_frame.rss_mib", "mib", [sample["max_rss_mib"] for sample in samples], ok=healthy, note=problem + "ru_maxrss of the launch")


def turn_loop_round(fx, steps, timeout):
    root = Path(tempfile.mkdtemp(prefix="fx-bench-turn-loop-"))
    home, workspace = write_gateway_home(root)
    evidence = workspace / "evidence.txt"

    def respond(index, _body):
        if index >= steps:
            return final_text_events("TURN_LOOP_COMPLETE")
        evidence.write_text(f"{index}\n")
        return tool_call_events(f"read_{index + 1}", "read_file", {"path": "evidence.txt"})

    gateway = ScriptedGateway(respond)
    env = gateway_environment(home, gateway.base_url)
    try:
        with open(root / "stdout.json", "w") as out, open(root / "stderr.log", "w") as err:
            process = subprocess.Popen([fx, "ask", "--json", "--yolo", "--no-save", "Read the evidence file until the fixture finishes."], cwd=workspace, env=env, stdin=subprocess.DEVNULL, stdout=out, stderr=err, start_new_session=True)
            try:
                code = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
                code = "timeout"
        try:
            result = json.loads((root / "stdout.json").read_text())
        except ValueError:
            result = {}
        calls = result.get("tool_calls", [])
        arrivals, handled = list(gateway.arrivals), list(gateway.handled)
        problem = None
        if code != 0:
            problem = f"fx ask exited with {code}: {(root / 'stderr.log').read_text()[-200:]}"
        elif len(arrivals) != steps + 1 or result.get("final_output") != "TURN_LOOP_COMPLETE":
            problem = f"{len(arrivals)} requests for {steps} steps, final output {result.get('final_output')!r}"
        elif len(calls) != steps or not all(call.get("name") == "read_file" and call.get("status") == "success" for call in calls):
            problem = f"{len(calls)} tool calls reported, not {steps} successful read_file calls"
        gaps = [(arrivals[i + 1] - handled[i]) * 1000 for i in range(len(arrivals) - 1) if handled[i] is not None]
        return gaps, problem
    finally:
        gateway.stop()
        shutil.rmtree(root, ignore_errors=True)


def run_turn_loop(reporter, fx, rounds, steps, timeout):
    medians, tails, problems = [], [], []
    for _ in range(rounds):
        gaps, problem = turn_loop_round(fx, steps, timeout)
        if problem:
            problems.append(problem)
        elif gaps:
            medians.append(statistics.median(gaps))
            tails.append(sorted(gaps)[max(1, math.ceil(0.95 * len(gaps))) - 1])
    if not medians:
        reporter.fail("turn_loop.step_ms", "ms", problems[0] if problems else "no gaps measured")
        return
    note = f"each sample is the median of {steps} read_file steps in one fx ask; step = next request arrival minus previous response written; p95 of a round {statistics.median(tails):.3f} ms"
    if problems:
        note += f"; {len(problems)} rounds failed: {problems[0]}"
    reporter.emit("turn_loop.step_ms", "ms", medians, ok=not problems, note=note)


def companion_measurements(script, arguments, timeout):
    root = Path(tempfile.mkdtemp(prefix="fx-bench-companion-"))
    try:
        try:
            completed = subprocess.run([sys.executable, str(script), "--output", str(root / "run")] + arguments, capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            return None, f"{script.name} timed out after {timeout}s"
        try:
            report = json.loads((root / "run/measurements.json").read_text())
        except (OSError, ValueError):
            return None, f"{script.name} exited {completed.returncode} without measurements: {(completed.stderr or completed.stdout).strip()[-200:]}"
        return report, None
    finally:
        shutil.rmtree(root, ignore_errors=True)


def run_long_turn(reporter, fx, payload, rounds, steps, timeout):
    config = "long_turn.peak_rss_mib"
    script = companion_script("long_turn_memory.py", payload)
    if script is None:
        reporter.fail(config, "mib", "long_turn_memory.py not found")
        return
    peaks, problems = [], []
    for _ in range(rounds):
        report, problem = companion_measurements(script, ["--binary", fx, "--steps", str(steps), "--timeout", str(timeout)], timeout + 60)
        if report is not None and not report.get("completed"):
            problem = f"turn did not complete: code {report.get('code')}, {report.get('requests')} requests for {steps} steps"
        if problem:
            problems.append(problem)
        else:
            peaks.append(report["peak_rss_kib"] / 1024)
    if not peaks:
        reporter.fail(config, "mib", problems[0])
        return
    note = f"peak VmRSS sampled every 100 ms over a {steps}-step saved fx ask turn"
    if problems:
        note += f"; {len(problems)} rounds failed: {problems[0]}"
    reporter.emit(config, "mib", peaks, ok=not problems, note=note)


def run_shell_command(reporter, fx, payload, rounds, calls, timeout):
    config = "shell_command.per_call_ms"
    script = companion_script("shell_command_overhead.py", payload)
    if script is None:
        reporter.fail(config, "ms", "shell_command_overhead.py not found")
        return
    medians, problems, loads, kinds = [], [], [], set()
    for _ in range(rounds):
        report, problem = companion_measurements(script, ["--binary", fx, "--calls", str(calls), "--timeout", str(timeout)], timeout + 60)
        if report is not None and not report.get("completed"):
            problem = f"run did not complete: code {report.get('code')}, {report.get('requests')} requests, {report.get('ls_failures')} ls failures, PATH marker present {report.get('path_marker_present')}"
        if problem:
            problems.append(problem)
        else:
            medians.append(report["per_call_ms"]["median"])
            loads.append(report["rc_loads"])
            kinds.add(str(report.get("shell_kind")))
    if not medians:
        reporter.fail(config, "ms", problems[0])
        return
    note = f"rc_loads {sorted(set(loads))} per {calls} Bash ls calls; login shell kind {','.join(sorted(kinds))}; each sample is one run's median call"
    if problems:
        note += f"; {len(problems)} rounds failed: {problems[0]}"
    reporter.emit(config, "ms", medians, ok=not problems, note=note)


def run_build_sizes(reporter, payload):
    if payload is None:
        reporter.fail("build_size", "bytes", "no payload manifest")
        return
    for entry in manifest_entries(payload):
        if entry.get("kind", "build") != "build":
            continue
        config = "build_size." + entry["name"]
        problem = entry_mismatch(payload, entry)
        if problem:
            reporter.fail(config, "bytes", problem)
        else:
            reporter.emit(config, "bytes", [entry["bytes"]], note=f"sha256={entry['sha256']}")


def run_bench_binary(binary, arguments, timeout):
    started = time.perf_counter()
    try:
        completed = subprocess.run([str(binary)] + arguments, capture_output=True, text=True, errors="replace", timeout=timeout, stdin=subprocess.DEVNULL)
    except (subprocess.TimeoutExpired, OSError) as error:
        return None, "", f"run failed: {error}"
    elapsed = (time.perf_counter() - started) * 1000
    if completed.returncode != 0:
        return None, completed.stdout, f"exit {completed.returncode}: {(completed.stderr or completed.stdout)[-300:]}"
    return elapsed, completed.stdout, None


def bench_binary(payload, name):
    binary = payload / "bin" / name if payload else None
    return binary if binary is not None and os.access(binary, os.X_OK) else None


def reported_milliseconds(pattern, output):
    found = re.search(pattern + r"\s+([0-9.]+)(us|ms|s)\b", output)
    if found is None:
        return None
    return float(found.group(1)) * DURATION_UNIT_MILLISECONDS[found.group(2)]


def run_ui_activity(reporter, payload, rounds, timeout):
    wall, comparison, growth = "tui_bench.ui_activity", "tui_bench.ui_activity.comparison_ratio", "tui_bench.ui_activity.growth_ratio"
    binary = bench_binary(payload, UI_ACTIVITY_BINARY)
    if binary is None:
        for config, unit in ((wall, "ms"), (comparison, "ratio"), (growth, "ratio")):
            reporter.fail(config, unit, "not in payload")
        return
    elapsed, ratios, problem = [], {comparison: [], growth: []}, None
    for _ in range(rounds):
        took, output, problem = run_bench_binary(binary, [], timeout)
        if problem:
            break
        elapsed.append(took)
        for config, label in ((comparison, "comparison_median_ratio"), (growth, "growth_median_ratio")):
            found = re.search(label + r"=([0-9.]+)x", output)
            if found:
                ratios[config].append(float(found.group(1)))
    if problem:
        for config, unit in ((wall, "ms"), (comparison, "ratio"), (growth, "ratio")):
            reporter.fail(config, unit, problem)
        return
    reporter.emit(wall, "ms", elapsed, note="wall time of the whole benchmark process, which passed its own ratio checks")
    reporter.emit(comparison, "ratio", ratios[comparison], ok=len(ratios[comparison]) == rounds, note="candidate over baseline median, as the benchmark prints it")
    reporter.emit(growth, "ratio", ratios[growth], ok=len(ratios[growth]) == rounds, note="cost growth with transcript size, as the benchmark prints it")


def run_approval_review(reporter, payload, runs, timeout):
    binary = bench_binary(payload, APPROVAL_REVIEW_BINARY)
    for scenario in APPROVAL_REVIEW_SCENARIOS:
        paint, written = f"tui_bench.approval_review.{scenario}.paint_ms", f"tui_bench.approval_review.{scenario}.terminal_bytes"
        if not (reporter.wants_config(paint) or reporter.wants_config(written)):
            continue
        if binary is None:
            reporter.fail(paint, "ms", "not in payload")
            reporter.fail(written, "bytes", "not in payload")
            continue
        _, output, problem = run_bench_binary(binary, [scenario, str(runs), "1"], timeout)
        paint_by_run, bytes_by_run = {}, {}
        if not problem:
            try:
                for text in output.splitlines():
                    sample = json.loads(text)
                    if sample.get("kind") != "sample":
                        continue
                    paint_by_run[sample["run"]] = paint_by_run.get(sample["run"], 0) + sample["paint_ns"]
                    bytes_by_run[sample["run"]] = bytes_by_run.get(sample["run"], 0) + sample["terminal_bytes"]
            except (ValueError, KeyError) as error:
                problem = f"unreadable sample line: {error}"
        if not problem and len(paint_by_run) != runs:
            problem = f"{len(paint_by_run)} runs reported, not {runs}"
        if problem:
            reporter.fail(paint, "ms", problem)
            reporter.fail(written, "bytes", problem)
            continue
        reporter.emit(paint, "ms", [nanoseconds / 1e6 for nanoseconds in paint_by_run.values()], note="each sample is one run's paint time summed over the seven review phases, as the benchmark measures it in process")
        reporter.emit(written, "bytes", list(bytes_by_run.values()), note="terminal bytes written over the seven review phases of one run")


def run_file_index(reporter, payload, rounds, timeout):
    wall = "tui_bench.file_index"
    reported = (
        ("tui_bench.file_index.index_build_ms", r"indexed:\s+\d+ candidates in"),
        ("tui_bench.file_index.search_p50_ms", r"search p50"),
        ("tui_bench.file_index.search_p95_ms", r"search p95"),
    )
    binary = bench_binary(payload, FILE_INDEX_BINARY)
    elapsed, values, problem = [], {config: [] for config, _ in reported}, None if binary else "not in payload"
    for _ in range(rounds if binary else 0):
        started = time.perf_counter()
        took, output, problem = run_bench_binary(binary, [], timeout)
        if problem and FILE_INDEX_OWN_BUDGET_VERDICT in output:
            took, problem = (time.perf_counter() - started) * 1000, None
        if problem:
            break
        elapsed.append(took)
        for config, pattern in reported:
            value = reported_milliseconds(pattern, output)
            if value is not None:
                values[config].append(value)
    if problem:
        for config in (wall,) + tuple(config for config, _ in reported):
            reporter.fail(config, "ms", problem)
        return
    reporter.emit(wall, "ms", elapsed, note="wall time of the whole benchmark process: 100000 candidates, 4000 searches; its own fixed 16 ms verdict is not applied here")
    for config, _ in reported:
        reporter.emit(config, "ms", values[config], ok=len(values[config]) == rounds, note="as the benchmark prints it, one sample per process")


def run_tui_benchmarks(reporter, payload, rounds, repeats, timeout):
    if reporter.wants_group("tui_bench.ui_activity"):
        run_ui_activity(reporter, payload, rounds, timeout)
    if reporter.wants_group("tui_bench.approval_review"):
        run_approval_review(reporter, payload, repeats, timeout)
    if reporter.wants_group("tui_bench.file_index"):
        run_file_index(reporter, payload, rounds, timeout)


def main():
    parser = argparse.ArgumentParser(description="Run the fx benchmark configurations and write one JSON line per configuration.")
    parser.add_argument("--fx", help="fx binary; defaults to bin/fx in the payload")
    parser.add_argument("--payload", help="payload directory holding manifest.json")
    parser.add_argument("--out", help="results file, one JSON line per configuration")
    parser.add_argument("--repeats", type=int, default=30, help="runs per startup and first-frame configuration")
    parser.add_argument("--only", action="append", default=[], help="configuration or group name to run (repeatable)")
    parser.add_argument("--rounds", type=int, default=3, help="upper bound on whole-scenario rounds for the slow configurations")
    parser.add_argument("--warmup", type=int, default=3, help="unrecorded launches before the startup and first-frame samples")
    parser.add_argument("--sample-seconds", type=float, default=10.0, help="length of each wait-CPU sample")
    parser.add_argument("--settle-seconds", type=float, default=2.0, help="pause between reaching a waiting state and sampling it")
    parser.add_argument("--first-frame-window", type=float, default=2.0, help="seconds each first-frame launch stays open")
    parser.add_argument("--turn-steps", type=int, default=50, help="tool calls per turn-loop round")
    parser.add_argument("--long-turn-steps", type=int, default=200, help="tool calls in the peak-RSS turn")
    parser.add_argument("--shell-calls", type=int, default=30, help="Bash calls per shell-overhead round")
    parser.add_argument("--timeout", type=int, default=600, help="seconds allowed for one scripted fx run")
    args = parser.parse_args()
    if args.repeats < 1:
        parser.error("--repeats must be at least 1")

    reporter = Reporter(args.out, args.only)
    payload = Path(args.payload).resolve() if args.payload else None
    if payload is not None:
        try:
            mismatches = payload_mismatches(payload)
        except (OSError, ValueError, KeyError, TypeError) as error:
            mismatches = [f"unreadable {MANIFEST_NAME}: {error}"]
        if mismatches:
            reporter.fail("payload", "bytes", "; ".join(mismatches), force=True)
            reporter.close()
            return 2
        reporter.record_payload(json.loads((payload / MANIFEST_NAME).read_text()))
    fx = args.fx or (str(payload / "bin/fx") if payload else None)
    if fx is None or not os.access(fx, os.X_OK):
        reporter.fail("payload", "bytes", f"fx binary is not executable: {fx}", force=True)
        reporter.close()
        return 2
    fx = str(Path(fx).resolve())
    rounds = max(1, min(args.repeats, args.rounds))

    groups = [
        ("build_size", lambda: run_build_sizes(reporter, payload)),
        ("startup", lambda: run_startup(reporter, fx, payload, args.repeats, args.warmup)),
        ("first_frame", lambda: run_first_frame(reporter, fx, payload, args.repeats, min(args.warmup, 2), args.first_frame_window)),
        ("wait_cpu", lambda: run_wait_cpu(reporter, fx, payload, rounds, args.sample_seconds, args.settle_seconds)),
        ("turn_loop", lambda: run_turn_loop(reporter, fx, rounds, args.turn_steps, args.timeout)),
        ("long_turn", lambda: run_long_turn(reporter, fx, payload, rounds, args.long_turn_steps, args.timeout)),
        ("shell_command", lambda: run_shell_command(reporter, fx, payload, rounds, args.shell_calls, args.timeout)),
        ("tui_bench", lambda: run_tui_benchmarks(reporter, payload, rounds, min(args.repeats, 30), args.timeout)),
    ]
    for group, run in groups:
        if not reporter.wants_group(group):
            continue
        try:
            run()
        except Exception as error:
            reporter.fail(group, "ms", f"{type(error).__name__}: {error}", force=True)
    reporter.close()
    return 0 if reporter.ok_count else 1


if __name__ == "__main__":
    raise SystemExit(main())
