import { readFileSync, readdirSync } from "node:fs";
import { Profile } from "../tests/e2e/shell-sessions";
import { fakeGatewayFinalText, fakeGatewayToolCall } from "../tests/e2e/tmux-helpers";

const SAMPLE_SECONDS = 10;
const TICKS_PER_SECOND = 100;
const IDLE_BUDGET_PERCENT = 1.5;
const WAITING_BUDGET_PERCENT = 6;

type Result = { state: string; percent: number; budget: number; wakes: number; threads: string };

function threadTicks(pid: number): Map<string, number> {
  const ticks = new Map<string, number>();
  for (const tid of readdirSync(`/proc/${pid}/task`)) {
    const fields = readFileSync(`/proc/${pid}/task/${tid}/stat`, "utf8").split(") ")[1]!.split(" ");
    ticks.set(tid, Number(fields[11]) + Number(fields[12]));
  }
  return ticks;
}

function voluntarySwitches(pid: number): number {
  return Number(/voluntary_ctxt_switches:\s+(\d+)/.exec(readFileSync(`/proc/${pid}/task/${pid}/status`, "utf8"))![1]);
}

async function sample(state: string, pid: number, budget: number): Promise<Result> {
  const before = threadTicks(pid);
  const switchesBefore = voluntarySwitches(pid);
  await Bun.sleep(SAMPLE_SECONDS * 1000);
  const after = threadTicks(pid);
  const percentOf = (ticks: number) => (ticks * 100) / TICKS_PER_SECOND / SAMPLE_SECONDS;
  const rows = [...after]
    .map(([tid, value]) => [tid, value - (before.get(tid) ?? 0)] as const)
    .filter(([, used]) => used > 0)
    .sort((a, b) => b[1] - a[1]);
  const result: Result = {
    state,
    percent: percentOf(rows.reduce((sum, [, used]) => sum + used, 0)),
    budget,
    wakes: Math.round((voluntarySwitches(pid) - switchesBefore) / SAMPLE_SECONDS),
    threads: rows.map(([tid, used]) => `${tid === String(pid) ? "main" : tid}=${percentOf(used).toFixed(1)}%`).join(" "),
  };
  const verdict = result.percent <= budget ? "within" : "OVER";
  console.log(
    `WAIT-CPU ${state}: ${result.percent.toFixed(1)}% of a core (${verdict} the ${budget}% budget); main thread wakes ${result.wakes}/s; threads ${result.threads}`,
  );
  return result;
}

const check = process.argv.includes("--check");
const profile = new Profile("wait-cpu");
const results: Result[] = [];
try {
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
  const shell = await profile.launch();
  const pid = shell.pid;

  results.push(await sample("idle at a fresh prompt", pid, IDLE_BUDGET_PERCENT));

  await shell.prompt("Say hello.", "Hello done.");
  results.push(await sample("idle after a turn", pid, IDLE_BUDGET_PERCENT));

  const held = await shell.begin("Hold the model.");
  results.push(await sample("model reply held", pid, WAITING_BUDGET_PERCENT));
  await held.release("Held done.");

  await shell.session.sendText("Run the long command.");
  await Bun.sleep(4000);
  results.push(await sample("foreground Bash running", pid, WAITING_BUDGET_PERCENT));
  await shell.session.waitForText("Long command done.", 60_000);

  await shell.session.sendText("Start a task and wait.");
  await Bun.sleep(5000);
  results.push(await sample("WaitFor on a background task", pid, WAITING_BUDGET_PERCENT));
  await shell.session.waitForText("Waited done.", 60_000);

  await shell.session.sendText("Print some lines.");
  await shell.session.waitForText("Printed lines done.", 60_000);
  await shell.session.waitForStableComposer(60_000);
  await Bun.sleep(2000);
  results.push(await sample("idle after a command that printed output", pid, IDLE_BUDGET_PERCENT));

  await shell.quit();
} finally {
  await profile.close(false);
}

const over = results.filter((result) => result.percent > result.budget);
if (check && over.length > 0) {
  console.error(`WAIT-CPU ${over.length} of ${results.length} states are over budget: ${over.map((result) => result.state).join(", ")}`);
  process.exit(1);
}
