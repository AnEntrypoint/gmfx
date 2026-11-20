













import { expect, test } from "bun:test";
import { dlopen, FFIType, ptr } from "bun:ffi";
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { artifacts, binary } from "../lib/context";
import { cliLogin, fixture, fxEnv, save, startFake, storePath, waitFor, writeProfile, type Fixture } from "./driver";
import { checkTrace, type TraceRecord, type Verdict } from "./trace";


const REFRESH_MAX = 30_000;
const BUDGET = 10_000;
const SLACK = 2_000;

const TOLERANCE = 600;



const uptime = process.platform === "darwin"
  ? dlopen("/usr/lib/libSystem.B.dylib", { clock_gettime_nsec_np: { args: [FFIType.i32], returns: FFIType.u64 } }).symbols
  : null;
const libc = process.platform === "linux"
  ? dlopen("libc.so.6", { clock_gettime: { args: [FFIType.i32, FFIType.ptr], returns: FFIType.i32 } }).symbols
  : null;
const timespec = new BigInt64Array(2);
const CLOCK_MONOTONIC = 1;
function awakeMs(): number {
  if (uptime) return Number(BigInt(uptime.clock_gettime_nsec_np(8)) / 1_000_000n);
  if (libc && libc.clock_gettime(CLOCK_MONOTONIC, ptr(timespec)) === 0) return Number(timespec[0]! * 1000n + timespec[1]! / 1_000_000n);
  throw new Error("no awake clock to read on this platform");
}

interface Proc { label: string; child: ReturnType<typeof Bun.spawn>; trace: string; done: Promise<{ code: number; out: string; err: string }> }
interface Scene { f: Fixture; fake: Awaited<ReturnType<typeof startFake>>; t0: number; records: TraceRecord[]; procs: Proc[]; holders: ReturnType<typeof Bun.spawn>[] }


async function scene(name: string, server: Record<string, unknown>): Promise<Scene> {
  const f = fixture(artifacts, name);
  const fake = await startFake(f, server);
  writeProfile(f, { web: { type: "http", url: fake.url, startupTimeoutMs: 60_000 } });
  const login = await cliLogin(binary, f);
  const url = await waitFor("the authorization URL", () => /\n\s+(http\S+)\n/.exec(login.out())?.[1], 30_000);
  const redirect = await fetch(url, { redirect: "manual" });
  await (await fetch(redirect.headers.get("location")!)).text();
  expect(await login.done()).toBe(0);
  expire(f);
  return { f, fake, t0: awakeMs(), records: [], procs: [], holders: [] };
}


function expire(f: Fixture) {
  const doc = JSON.parse(readFileSync(storePath(f), "utf8"));
  for (const s of doc.servers) {
    const c = JSON.parse(s.credential);
    c.expires_at_ms = Date.now() - 60_000;
    s.credential = JSON.stringify(c);
  }
  writeFileSync(storePath(f), JSON.stringify(doc), { mode: 0o600 });
}

const refreshes = (s: Scene) => s.fake.entries().filter((e) => e.dir === "auth" && e.path?.endsWith("/token") && e.form?.grant_type === "refresh_token");

function note(s: Scene, event: string, p: string) {
  const at = awakeMs() - s.t0;
  s.records.push({ event, data: { p, at }, at });
}

function start(s: Scene, label: string): Proc {
  const trace = join(s.f.base, `${label}.trace`);
  const child = Bun.spawn([binary, "mcp", "show", "web"], {
    cwd: s.f.workspace, env: fxEnv(s.f, { FX_TRACE_LOG: trace, FX_TRACE_SCOPES: "mcp" }), stdin: "ignore", stdout: "pipe", stderr: "pipe",
  });
  const done = Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]).then(([code, out, err]) => ({ code, out, err }));
  const p = { label, child, trace, done };
  s.procs.push(p);
  return p;
}

interface Seen { takes: number[]; stamps: number[]; releases: number[]; goaheads: { at: number; started: number }[]; events: { event: string; at: number; started?: number }[] }


function seen(s: Scene, p: Proc): Seen {
  const text = existsSync(p.trace) ? readFileSync(p.trace, "utf8") : "";
  const out: Seen = { takes: [], stamps: [], releases: [], goaheads: [], events: [] };
  for (const line of text.split("\n")) {
    let m = /MCP refresh lock taken stamp=(\d+)/.exec(line);
    if (m) out.events.push({ event: "take", at: Number(m[1]) - s.t0 });
    m = /MCP refresh lock stamped stamp=(\d+)/.exec(line);
    if (m) out.events.push({ event: "stamp", at: Number(m[1]) - s.t0 });
    m = /MCP refresh lock released stamp=\d+ at=(\d+)/.exec(line);
    if (m) out.events.push({ event: "release", at: Number(m[1]) - s.t0 });
    m = /MCP refresh went ahead server=\S+ reason=another fx stopped refreshing started=(\d+) at=(\d+)/.exec(line);
    if (m) out.events.push({ event: "goahead", started: Number(m[1]) - s.t0, at: Number(m[2]) - s.t0 });
  }
  for (const e of out.events) {
    if (e.event === "goahead") out.goaheads.push({ at: e.at, started: e.started! });
    else ({ take: out.takes, stamp: out.stamps, release: out.releases } as Record<string, number[]>)[e.event]!.push(e.at);
  }
  return out;
}

async function waitForTake(s: Scene, p: Proc) {
  await waitFor(`${p.label} taking the refresh lock`, () => seen(s, p).takes.length > 0, 30_000, 10);
}


async function finish(s: Scene): Promise<{ verdict: Verdict; seen: Seen[]; results: Awaited<Proc["done"]>[] }> {
  const results = await Promise.all(s.procs.map((p) => p.done));
  const all = s.procs.map((p) => seen(s, p));
  for (const [k, p] of s.procs.entries()) {
    for (const e of all[k]!.events) {
      s.records.push({ event: e.event, data: { p: p.label, at: e.at, ...(e.started === undefined ? {} : { started: e.started }) }, at: e.at });
    }
  }


  const rank: Record<string, number> = { kill: 0, release: 0, foreign_release: 0, thaw: 1, freeze: 2, goahead: 3, take: 4, foreign: 4, stamp: 5 };
  const order = new Map(s.records.map((r, k) => [r, k]));
  const who = (r: TraceRecord) => (r.data as { p?: string } | undefined)?.p;
  s.records.sort((a, b) => (a.at ?? 0) - (b.at ?? 0)
    || (who(a) === who(b) ? order.get(a)! - order.get(b)! : (rank[a.event] ?? 6) - (rank[b.event] ?? 6)));
  const verdict = await checkTrace({
    module: "RefreshLease", records: s.records, dir: join(s.f.base, "trace"),
    constants: { ObsRefreshMax: REFRESH_MAX, ObsBudget: BUDGET, ObsSlack: SLACK, ObsTolerance: TOLERANCE },
  });
  save(join(s.f.base, "seen.json"), { seen: all, results: results.map((r) => ({ code: r.code, err: r.err })), refreshes: refreshes(s).length });
  console.log(`${s.f.base}: ${verdict.verdict}${verdict.broken ? ` broken=${verdict.broken.join(",")}` : ""} records=${verdict.records}`);
  return { verdict, seen: all, results };
}

function cleanup(s: Scene) {
  for (const p of s.procs) try { process.kill(p.child.pid, "SIGCONT"); p.child.kill("SIGKILL"); } catch {}
  for (const h of s.holders) try { h.kill("SIGKILL"); } catch {}
  s.fake.stop();
}

test("a refresh answered 15 s late: the next fx waits for it and takes the login it saved", async () => {
  const s = await scene("rl-slow", { refreshDelayMs: [15_000] });
  try {
    const first = start(s, "first");
    await waitForTake(s, first);
    await waitFor("the first refresh", () => refreshes(s).length === 1, 10_000, 10);
    const second = start(s, "second");
    const { verdict, seen: all } = await finish(s);

    expect(refreshes(s).length).toBe(1);
    expect(all.map((v) => v.goaheads.length)).toEqual([0, 0]);
    expect(all[1]!.takes[0]!).toBeGreaterThanOrEqual(all[0]!.releases[0]!);
    expect(readFileSync(second.trace, "utf8")).toContain("MCP refresh replaced server=web reason=another fx refreshed");
    expect(verdict.verdict).toBe("ACCEPTED");
  } finally { cleanup(s); }
}, 120_000);

test("a refresher frozen with its refresh out: the next fx goes ahead 32 s after its stamp, not before", async () => {

  const s = await scene("rl-frozen", { refreshDelayMs: [60_000], rotate: false });
  try {
    const first = start(s, "first");
    await waitForTake(s, first);
    await waitFor("the first refresh", () => refreshes(s).length === 1, 10_000, 10);

    process.kill(first.child.pid, "SIGSTOP");
    note(s, "freeze", "first");
    const second = start(s, "second");
    await second.done;
    first.child.kill("SIGKILL");
    note(s, "kill", "first");
    const { verdict, seen: all } = await finish(s);

    expect(all[1]!.goaheads.length).toBe(1);
    expect(all[1]!.goaheads[0]!.at - Math.max(...all[0]!.stamps)).toBeGreaterThanOrEqual(REFRESH_MAX + SLACK - TOLERANCE);
    expect(refreshes(s).length).toBe(2);
    expect(verdict.verdict).toBe("ACCEPTED");
  } finally { cleanup(s); }
}, 120_000);

test("an older fx holds the refresh lock and stamps nothing: the next fx goes ahead 32 s after it starts", async () => {
  const s = await scene("rl-older", { rotate: false });
  try {

    const once = start(s, "once");
    expect((await once.done).code).toBe(0);
    expire(s.f);
    const dir = join(s.f.home, ".fx", "mcp-credentials");
    const lock = readdirSync(dir).find((n) => /^refresh-v3-.*\.lock$/.test(n));
    if (!lock) throw new Error("no refresh lock file");
    const holder = Bun.spawn(["perl", "-e", 'use Fcntl qw(:flock); open(my $f, ">>", $ARGV[0]) or die; flock($f, LOCK_EX) or die; $| = 1; print "held\\n"; sleep $ARGV[1];', join(dir, lock), "60"], { stdout: "pipe" });
    s.holders.push(holder);
    const { value } = await holder.stdout.getReader().read();
    expect(new TextDecoder().decode(value)).toBe("held\n");
    note(s, "foreign", "older");
    const waiter = start(s, "waiter");
    await waiter.done;
    holder.kill();
    note(s, "foreign_release", "older");
    const { verdict, seen: all } = await finish(s);
    const g = all[1]!.goaheads[0]!;
    expect(g.at - g.started).toBeGreaterThanOrEqual(REFRESH_MAX + SLACK - TOLERANCE);
    expect(refreshes(s).length).toBe(2);
    expect(verdict.verdict).toBe("ACCEPTED");
  } finally { cleanup(s); }
}, 120_000);

test("a refresher killed mid-refresh: the next fx takes the lock at once and refreshes", async () => {
  const s = await scene("rl-kill", { refreshDelayMs: [30_000], rotate: false });
  try {
    const first = start(s, "first");
    await waitForTake(s, first);
    await waitFor("the first refresh", () => refreshes(s).length === 1, 10_000, 10);
    const second = start(s, "second");
    await Bun.sleep(2_000);
    first.child.kill("SIGKILL");
    note(s, "kill", "first");
    const killedAt = awakeMs() - s.t0;
    const r = await second.done;
    const { verdict, seen: all } = await finish(s);
    expect(r.code).toBe(0);
    expect(all[1]!.goaheads.length).toBe(0);
    expect(all[1]!.takes[0]! - killedAt).toBeLessThan(TOLERANCE);
    expect(verdict.verdict).toBe("ACCEPTED");
  } finally { cleanup(s); }
}, 120_000);
