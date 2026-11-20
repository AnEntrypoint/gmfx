import { readFileSync, readdirSync } from "node:fs";
import { Profile, type Shell } from "../tests/e2e/shell-sessions";
import { fakeGatewayFinalText, fakeGatewayToolCall } from "../tests/e2e/tmux-helpers";

const SETTLE_MS = 2000;
const IDLE_WATCH_MS = 60_000;
const LONG_TURN_MS = 600_000;
const FIRST_STEP_BATCH = 50;
const SECOND_STEP_BATCH = 150;
const CLEARED_ROUNDS = 3;
const REWRITE_ROUNDS = 3;
const REWRITES = 8;
const REWRITTEN_LINES = 1000;

type Memory = { rss: number; anon: number; file: number; pss: number | null };
type Process = { pid: number; parent: number; name: string; command: string };
type Sample = { state: string; fx: Memory; descendants: Array<Process & { memory: Memory }>; total: number };
type Leftover = { state: string; alive: Process[] };

function statusField(status: string, field: string): number {
  return Number(new RegExp(`^${field}:\\s+(\\d+) kB`, "m").exec(status)?.[1] ?? 0);
}

function memoryOf(pid: number): Memory | null {
  try {
    const status = readFileSync(`/proc/${pid}/status`, "utf8");
    let pss: number | null = null;
    try {
      pss = statusField(readFileSync(`/proc/${pid}/smaps_rollup`, "utf8"), "Pss");
    } catch {}
    return { rss: statusField(status, "VmRSS"), anon: statusField(status, "RssAnon"), file: statusField(status, "RssFile"), pss };
  } catch {
    return null;
  }
}

function peakOf(pid: number): number | null {
  try {
    return statusField(readFileSync(`/proc/${pid}/status`, "utf8"), "VmHWM");
  } catch {
    return null;
  }
}

function processTable(): Map<number, Process> {
  const table = new Map<number, Process>();
  for (const entry of readdirSync("/proc")) {
    const pid = Number(entry);
    if (!Number.isInteger(pid)) continue;
    try {
      const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
      const name = stat.slice(stat.indexOf("(") + 1, stat.lastIndexOf(")"));
      const fields = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
      if (fields[0] === "Z") continue;
      const command = readFileSync(`/proc/${pid}/cmdline`, "utf8").replace(/[\0\s]+/g, " ").trim();
      table.set(pid, { pid, parent: Number(fields[1]), name, command });
    } catch {}
  }
  return table;
}

function startedUnder(pid: number, home: string): boolean {
  try {
    return readFileSync(`/proc/${pid}/environ`, "utf8").split("\0").includes(`HOME=${home}`);
  } catch {
    return false;
  }
}

function ancestorsOf(table: Map<number, Process>, pid: number): Set<number> {
  const ancestors = new Set<number>();
  for (let at = table.get(pid)?.parent; at !== undefined && at > 1 && !ancestors.has(at); at = table.get(at)?.parent) ancestors.add(at);
  return ancestors;
}

function descendsFrom(table: Map<number, Process>, pid: number, root: number): boolean {
  const seen = new Set<number>();
  for (let at = table.get(pid)?.parent; at !== undefined && at > 1 && !seen.has(at); at = table.get(at)?.parent) {
    if (at === root) return true;
    seen.add(at);
  }
  return false;
}

function familyOf(root: number, home: string, wrappers: Set<number>): Process[] {
  const table = processTable();
  return [...table.values()].filter((entry) =>
    entry.pid !== root && entry.pid !== process.pid && !wrappers.has(entry.pid) &&
    (descendsFrom(table, entry.pid, root) || startedUnder(entry.pid, home))
  );
}

function megabytes(kilobytes: number): string {
  return `${(kilobytes / 1024).toFixed(1)} MB`;
}

function describe(memory: Memory): string {
  return `rss ${megabytes(memory.rss)} (anon ${megabytes(memory.anon)}, file ${megabytes(memory.file)}, pss ${memory.pss === null ? "unreadable" : megabytes(memory.pss)})`;
}

function measure(state: string, shell: Shell, wrappers: Set<number>): Sample {
  const fx = memoryOf(shell.pid);
  if (!fx) throw new Error(`fx ${shell.pid} was gone at "${state}"`);
  const descendants = familyOf(shell.pid, shell.profile.home, wrappers).flatMap((entry) => {
    const memory = memoryOf(entry.pid);
    return memory ? [{ ...entry, memory }] : [];
  });
  const total = fx.rss + descendants.reduce((sum, entry) => sum + entry.memory.rss, 0);
  const listed = descendants.length === 0
    ? "none"
    : descendants.map((entry) => `${entry.name}(${entry.pid}) ${megabytes(entry.memory.rss)} [${entry.command.slice(0, 60)}]`).join(", ");
  console.log(`SESSION-MEMORY ${state}: fx ${describe(fx)}; descendants ${descendants.length}: ${listed}; total rss ${megabytes(total)}`);
  return { state, fx, descendants, total };
}

async function leftoversAfter(state: string, shell: Shell, wrappers: Set<number>): Promise<Leftover> {
  await Bun.sleep(SETTLE_MS);
  const alive = familyOf(shell.pid, shell.profile.home, wrappers);
  const listed = alive.length === 0
    ? "nothing"
    : alive.map((entry) => `${entry.name}(${entry.pid}) parent ${entry.parent} [${entry.command.slice(0, 60)}]`).join(", ");
  console.log(`SESSION-MEMORY alive ${SETTLE_MS / 1000} s after ${state}: ${listed}`);
  for (const entry of alive) {
    try {
      process.kill(entry.pid, "SIGKILL");
    } catch {}
  }
  return { state, alive };
}

function steps(label: string, count: number, answer: string) {
  return [
    ...Array.from({ length: count }, (_, index) => () =>
      fakeGatewayToolCall(`${label}-${index}`, "Bash", { command: `echo ${label}-step-${index}`, description: "Print one line" })),
    () => fakeGatewayFinalText(answer),
  ];
}

function rewrittenFile(round: number, index: number): string {
  return Array.from({ length: REWRITTEN_LINES }, (_, line) => `round ${round} rewrite ${index} line ${line} ${"x".repeat(40)}`).join("\n") + "\n";
}

async function turn(shell: Shell, prompt: string, answer: string, timeout = 60_000) {
  await shell.session.sendText(prompt);
  await shell.session.waitForText(answer, timeout);
  await shell.session.waitForStableComposer(timeout);
}

async function askPeak(profile: Profile, prompt: string): Promise<number> {
  const env: Record<string, string> = { PATH: process.env.PATH ?? "", FX_DISABLE_KEYCHAIN: "1", FX_E2E_DISABLE_DOTENV: "1" };
  for (const [key, value] of Object.entries(profile.env(""))) {
    if (value !== undefined && !key.startsWith("FX_RECORD") && !key.startsWith("FX_TRACE")) env[key] = value;
  }
  const child = Bun.spawn([profile.bin, "ask", "--json", "--yolo", prompt], { cwd: profile.workspace, env, stdout: "ignore", stderr: "ignore" });
  let peak = 0;
  let running = true;
  void child.exited.then(() => {
    running = false;
  });
  while (running) {
    peak = Math.max(peak, peakOf(child.pid) ?? 0);
    await Bun.sleep(5);
  }
  const code = await child.exited;
  if (code !== 0) throw new Error(`fx ask "${prompt}" exited ${code}`);
  return peak;
}

async function familyRuns(shell: Shell, wrappers: Set<number>, command: string): Promise<void> {
  const deadline = Date.now() + 60_000;
  while (Date.now() < deadline) {
    if (familyOf(shell.pid, shell.profile.home, wrappers).some((entry) => entry.command.includes(command))) return;
    await Bun.sleep(50);
  }
  throw new Error(`no process of fx ${shell.pid} ran "${command}":\n${(await shell.session.capturePane()).trimEnd()}`);
}

async function killedMidCommand(profile: Profile, state: string, prompt: string, running: string): Promise<Leftover> {
  const shell = await profile.launch();
  const wrappers = ancestorsOf(processTable(), shell.pid);
  await shell.session.sendText(prompt);
  await familyRuns(shell, wrappers, running);
  await Bun.sleep(SETTLE_MS);
  measure(`${state}, before the kill`, shell, wrappers);
  await shell.crash();
  return leftoversAfter(state, shell, wrappers);
}

const check = process.argv.includes("--check");
const profile = new Profile("session-memory");
const hooked = new Profile("session-memory-hook");
const samples: Sample[] = [];
const leftovers: Leftover[] = [];
try {
  profile.settings({ max_agent_steps: 0 });
  profile.answer("Say hello.", "Hello done.");
  profile.script("Run the long command.", [
    () => fakeGatewayToolCall("long-cmd", "Bash", { command: "sleep 25", description: "Sleep" }),
    () => fakeGatewayFinalText("Long command done."),
  ]);
  profile.script("Start a task and wait.", [
    () => fakeGatewayToolCall("bg", "Bash", { command: "sleep 25", run_in_background: true, description: "Sleep in background" }),
    () => fakeGatewayToolCall("wait", "WaitFor", { timeout: 60 }),
    () => fakeGatewayFinalText("Waited done."),
  ]);
  profile.script("Print some lines.", [
    () => fakeGatewayToolCall("printed", "Bash", { command: "for i in $(seq 1 40); do echo printed-line-$i; done", description: "Print lines" }),
    () => fakeGatewayFinalText("Printed lines done."),
  ]);
  profile.script("Run fifty steps.", steps("first", FIRST_STEP_BATCH, "Fifty steps done."));
  profile.script("Run many more steps.", steps("second", SECOND_STEP_BATCH, "Many more steps done."));
  profile.script("Leave a task running.", [
    () => fakeGatewayToolCall("left", "Bash", { command: "sleep 3003", run_in_background: true, description: "Sleep in background" }),
    () => fakeGatewayFinalText("Task left running."),
  ]);
  profile.script("Block on a command.", [
    () => fakeGatewayToolCall("blocked", "Bash", { command: "echo blocked-command-started; sleep 3001", description: "Sleep" }),
    () => fakeGatewayFinalText("Blocked command done."),
  ]);
  profile.script("Leave a task and stop.", [
    () => fakeGatewayToolCall("orphan", "Bash", { command: "sleep 3002", run_in_background: true, description: "Sleep in background" }),
    () => fakeGatewayFinalText("Orphan task started."),
  ]);
  profile.script("Follow a file.", [
    () => fakeGatewayToolCall("follow", "Bash", { command: "tail -f /dev/null", description: "Follow a file" }),
    () => fakeGatewayFinalText("Followed the file."),
  ]);
  profile.script("Count to five.", steps("ask", 5, "Counted to five."));
  hooked.settings({ hooks: [{ event: "PreToolUse", command: "sleep 3004" }] });
  hooked.script("Run a hooked command.", [
    () => fakeGatewayToolCall("hooked", "Bash", { command: "echo hooked-command", description: "Print one line" }),
    () => fakeGatewayFinalText("Hooked command done."),
  ]);

  const shell = await profile.launch({ env: { FX_RECORD: undefined, FX_RECORD_INPUT: undefined } });
  const wrappers = ancestorsOf(processTable(), shell.pid);
  const record = (state: string) => samples.push(measure(state, shell, wrappers));

  record("fresh prompt");

  await shell.prompt("Say hello.", "Hello done.");
  record("after one turn");

  const held = await shell.begin("Hold the model.");
  await Bun.sleep(SETTLE_MS);
  record("model reply held");
  await held.release("Held done.");

  await shell.session.sendText("Run the long command.");
  await Bun.sleep(4000);
  record("foreground Bash running");
  await shell.session.waitForText("Long command done.", 60_000);

  await shell.session.sendText("Start a task and wait.");
  await Bun.sleep(5000);
  record("WaitFor on a background task");
  await shell.session.waitForText("Waited done.", 60_000);
  await shell.session.waitForStableComposer(60_000);

  await turn(shell, "Print some lines.", "Printed lines done.");
  await Bun.sleep(SETTLE_MS);
  record("after a turn with 40 printed lines");
  const beforeSteps = samples.at(-1)!;

  await turn(shell, "Run fifty steps.", "Fifty steps done.", LONG_TURN_MS);
  await Bun.sleep(SETTLE_MS);
  record(`after ${FIRST_STEP_BATCH} tool steps`);
  const afterFirst = samples.at(-1)!;

  await turn(shell, "Run many more steps.", "Many more steps done.", LONG_TURN_MS);
  await Bun.sleep(SETTLE_MS);
  record(`after ${FIRST_STEP_BATCH + SECOND_STEP_BATCH} tool steps`);
  const afterSecond = samples.at(-1)!;
  console.log(
    `SESSION-MEMORY growth per tool step: ${((afterFirst.fx.anon - beforeSteps.fx.anon) / FIRST_STEP_BATCH).toFixed(1)} kB over the first ${FIRST_STEP_BATCH}, ${((afterSecond.fx.anon - afterFirst.fx.anon) / SECOND_STEP_BATCH).toFixed(1)} kB over the next ${SECOND_STEP_BATCH} (anonymous memory)`,
  );

  await Bun.sleep(IDLE_WATCH_MS);
  record(`idle ${IDLE_WATCH_MS / 1000} s later`);
  console.log(`SESSION-MEMORY idle growth over ${IDLE_WATCH_MS / 1000} s: ${samples.at(-1)!.fx.rss - afterSecond.fx.rss} kB rss, ${samples.at(-1)!.fx.anon - afterSecond.fx.anon} kB anonymous`);

  for (let round = 1; round <= CLEARED_ROUNDS; round++) {
    await shell.newSession("/clear");
    await Bun.sleep(SETTLE_MS);
    record(`after /clear ${round}`);
    const cleared = samples.at(-1)!;
    profile.script(`Repeat the steps, round ${round}.`, steps(`round-${round}`, FIRST_STEP_BATCH + SECOND_STEP_BATCH, `Round ${round} steps done.`));
    await turn(shell, `Repeat the steps, round ${round}.`, `Round ${round} steps done.`, LONG_TURN_MS);
    await Bun.sleep(SETTLE_MS);
    record(`after /clear ${round} and ${FIRST_STEP_BATCH + SECOND_STEP_BATCH} more tool steps`);
    console.log(
      `SESSION-MEMORY kept from the sessions /clear closed, round ${round}: ${samples.at(-1)!.fx.anon - cleared.fx.anon} kB more anonymous memory after the same ${FIRST_STEP_BATCH + SECOND_STEP_BATCH} steps again (${afterSecond.fx.anon - beforeSteps.fx.anon} kB the first time)`,
    );
  }

  const beforeRewrites = samples.at(-1)!;
  for (let round = 1; round <= REWRITE_ROUNDS; round++) {
    profile.script(`Rewrite the file, round ${round}.`, [
      ...Array.from({ length: REWRITES }, (_, index) => () =>
        fakeGatewayToolCall(`rewrite-${round}-${index}`, "write_file", { path: "notes.txt", content: rewrittenFile(round, index) })),
      () => fakeGatewayFinalText(`Round ${round} rewrites done.`),
    ]);
    await turn(shell, `Rewrite the file, round ${round}.`, `Round ${round} rewrites done.`, LONG_TURN_MS);
    await shell.newSession("/clear");
    await Bun.sleep(SETTLE_MS);
    record(`after ${REWRITES} rewrites of a ${Math.round(rewrittenFile(round, 0).length / 1024)} kB file and /clear, round ${round}`);
  }
  console.log(
    `SESSION-MEMORY kept from file rewrites in sessions /clear closed: ${((samples.at(-1)!.fx.anon - beforeRewrites.fx.anon) / (REWRITE_ROUNDS * REWRITES)).toFixed(1)} kB of anonymous memory per rewrite over ${REWRITE_ROUNDS} rounds`,
  );

  await turn(shell, "Leave a task running.", "Task left running.");
  await Bun.sleep(SETTLE_MS);
  record("idle with a background task running");

  await shell.quit();
  leftovers.push(await leftoversAfter("fx quit with a background task running", shell, wrappers));

  leftovers.push(await killedMidCommand(profile, "SIGKILL during a foreground Bash", "Block on a command.", "sleep 3001"));
  leftovers.push(await killedMidCommand(profile, "SIGKILL with a background task running", "Leave a task and stop.", "sleep 3002"));
  leftovers.push(await killedMidCommand(profile, "SIGKILL during a read-only Bash", "Follow a file.", "tail -f /dev/null"));
  leftovers.push(await killedMidCommand(hooked, "SIGKILL during a PreToolUse hook", "Run a hooked command.", "sleep 3004"));

  console.log(`SESSION-MEMORY fx ask peak rss: one reply ${megabytes(await askPeak(profile, "Say hello."))}, five tool steps ${megabytes(await askPeak(profile, "Count to five."))}`);
} finally {
  await profile.close(false);
  await hooked.close(false);
}

const orphaned = leftovers.filter((leftover) => leftover.alive.length > 0);
if (check && orphaned.length > 0) {
  console.error(`SESSION-MEMORY processes outlived fx in ${orphaned.length} of ${leftovers.length} cases: ${orphaned.map((leftover) => leftover.state).join("; ")}`);
  process.exit(1);
}
