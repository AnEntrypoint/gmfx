import { afterEach, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { chmodSync, existsSync, linkSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";
import { fakeGatewayFinalText, heldFakeGatewayFinalText, startFakeGateway, TmuxSession, tmuxAvailable } from "./tmux-helpers";



const MODERN_FIXTURE = join(import.meta.dirname, "fixtures", "mcp-modern-stdio.mjs");

let cleanup: string | null = null;
let gateway: ReturnType<typeof startFakeGateway> | null = null;
let tui: TmuxSession | null = null;
let failureNotes: (() => string) | null = null;

afterEach(async () => {
  if (failureNotes) console.log(failureNotes());
  failureNotes = null;
  if (tui) await tui.kill();
  tui = null;
  gateway?.stop();
  gateway = null;
  if (cleanup) rmSync(cleanup, { recursive: true, force: true });
  cleanup = null;
});

function isRunning(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function createRoot(profile?: unknown, project?: unknown) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-mcp-verbs-")));
  cleanup = root;
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), "{}");
  if (profile !== undefined) writeFileSync(join(home, ".fx", "mcp.json"), typeof profile === "string" ? profile : JSON.stringify(profile));
  if (project !== undefined) writeFileSync(join(workspace, ".mcp.json"), JSON.stringify(project));
  return {
    home,
    workspace,
    profilePath: join(home, ".fx", "mcp.json"),
    projectPath: join(workspace, ".mcp.json"),
    env: {
      HOME: home,
      FX_DISABLE_KEYCHAIN: "1",
      FX_AUTO_UPGRADE: "0",
      AI_GATEWAY_API_KEY: "fake-mcp-verbs-key",
      VERCEL_OIDC_TOKEN: undefined,
    },
  };
}

type Root = ReturnType<typeof createRoot>;

function mcp(root: Root, ...args: string[]) {
  return runFx(["mcp", ...args], { cwd: root.workspace, env: root.env, timeoutMs: 20_000 });
}

const fixtureServer = (extra: Record<string, unknown> = {}) => ({
  command: process.execPath,
  args: [MODERN_FIXTURE],
  ...extra,
});

describe("fx mcp", () => {
  test("add writes each file and keeps every key it doesn't know", async () => {

    const root = createRoot('{"theme":"dark","mcp":{"old":{"command":"true","environment":{"A":"1"},"startupTimeoutMs":1.50}}}');
    writeFileSync(root.projectPath, '{"mcpServers":{},"note":"shared"}');
    chmodSync(root.projectPath, 0o640);

    const http = await mcp(root, "add", "web", "https://mcp.example/mcp", "--header", "X-Key=${KEY}");
    expect(http.stderr).toBe("");
    expect(http.code).toBe(0);
    expect(http.stdout).toBe("Added web to ~/.fx/mcp.json.\n");
    const stdio = await mcp(root, "add", "--project", "--env", "TOKEN=x", "local", "--", "node", "server.js", "-h");
    expect(stdio.code).toBe(0);
    expect(stdio.stdout).toBe("Added local to .mcp.json.\n");

    const profileText = readFileSync(root.profilePath, "utf8");
    expect(profileText).toContain('"startupTimeoutMs": 1.50');
    expect(JSON.parse(profileText)).toEqual({
      theme: "dark",
      mcp: {
        old: { command: "true", environment: { A: "1" }, startupTimeoutMs: 1.5 },
        web: { type: "http", url: "https://mcp.example/mcp", headers: { "X-Key": "${KEY}" } },
      },
    });
    expect(JSON.parse(readFileSync(root.projectPath, "utf8"))).toEqual({
      mcpServers: { local: { command: "node", args: ["server.js", "-h"], env: { TOKEN: "x" } } },
      note: "shared",
    });
    expect(statSync(root.profilePath).mode & 0o777).toBe(0o600);
    expect(statSync(root.projectPath).mode & 0o777).toBe(0o640);
  });

  test("add refuses a name that's there, a file it can't read, and a bad name", async () => {
    const root = createRoot({ mcpServers: { web: { type: "http", url: "https://a/mcp" } } });
    const before = readFileSync(root.profilePath, "utf8");
    const taken = await mcp(root, "add", "web", "https://b/mcp");
    expect(taken.code).toBe(1);
    expect(taken.stderr).toBe("Couldn't add web to ~/.fx/mcp.json: that name is already in the file; remove it first.\n");
    expect(readFileSync(root.profilePath, "utf8")).toBe(before);

    writeFileSync(root.profilePath, '{"mcpServers":{},"mcpServers":{}}');
    const broken = await mcp(root, "add", "other", "https://b/mcp");
    expect(broken.code).toBe(1);
    expect(broken.stderr).toContain("isn't valid JSON, or repeats a key");
    expect(readFileSync(root.profilePath, "utf8")).toBe('{"mcpServers":{},"mcpServers":{}}');

    const bad = await mcp(root, "add", "bad name", "https://b/mcp");
    expect(bad.code).toBe(2);
    expect(bad.stderr).toStartWith("'bad name' can't be a server name: use letters, digits, '-' and '_'.\nusage: fx mcp add ");
    const notUrl = await mcp(root, "add", "web2", "mcp.example");
    expect(notUrl.code).toBe(2);
    expect(notUrl.stderr).toStartWith("'mcp.example' isn't a URL. A stdio server's command goes after --.\n");
  });



  test("add and remove refuse a linked config file and name what it points to", async () => {
    const root = createRoot();
    const shared = join(root.workspace, "shared");
    mkdirSync(shared);
    const target = join(shared, "mcp.json");
    const text = JSON.stringify({ mcpServers: { one: { command: "true" } } });
    writeFileSync(target, text);
    symlinkSync(target, root.projectPath);
    const why = `it's a link to ${target}, and fx edits only a plain file; edit ${target} by hand.\n`;
    const added = await mcp(root, "add", "--project", "two", "--", "true");
    expect(added.code).toBe(1);
    expect(added.stderr).toBe(`Couldn't add two to .mcp.json: ${why}`);
    const removed = await mcp(root, "remove", "--project", "one");
    expect(removed.code).toBe(1);
    expect(removed.stderr).toBe(`Couldn't remove one from .mcp.json: ${why}`);
    expect(lstatSync(root.projectPath).isSymbolicLink()).toBe(true);
    expect(readFileSync(target, "utf8")).toBe(text);


    rmSync(root.projectPath);
    linkSync(target, root.projectPath);
    const hard = await mcp(root, "add", "--project", "two", "--", "true");
    expect(hard.code).toBe(1);
    expect(hard.stderr).toBe("Couldn't add two to .mcp.json: it has another hard link, and fx edits only a plain file; edit it by hand.\n");
    expect(readFileSync(target, "utf8")).toBe(text);


    const profileTarget = join(shared, "profile.json");
    writeFileSync(profileTarget, "{}");
    symlinkSync(profileTarget, root.profilePath);
    const profile = await mcp(root, "add", "three", "--", "true");
    expect(profile.code).toBe(1);
    expect(profile.stderr).toBe(`Couldn't add three to ~/.fx/mcp.json: it's a link to ${profileTarget}, and fx edits only a plain file; edit ${profileTarget} by hand.\n`);
    expect(lstatSync(root.profilePath).isSymbolicLink()).toBe(true);
    expect(readFileSync(profileTarget, "utf8")).toBe("{}");
  });

  test("list shows each server's file, transport, and status without connecting", async () => {
    const root = createRoot(
      {
        mcpServers: {
          ctx: { type: "http", url: "https://mcp.example/mcp" },
          off: { command: "never-run", enabled: false },
          sse: { type: "sse", url: "https://old.example/sse" },
          keyed: { type: "http", url: "https://k.example/mcp", bearerTokenEnvVar: "MISSING_TOKEN" },
        },
      },
      { mcpServers: { docs: { command: "never-run" } } },
    );
    const text = await mcp(root, "list");
    expect(text.stderr).toBe("");
    expect(text.code).toBe(0);
    expect(text.stdout).toBe(
      [
        "NAME   SOURCE          TRANSPORT  STATUS",
        "ctx    ~/.fx/mcp.json  http       not started",
        "off    ~/.fx/mcp.json  stdio      disabled",
        "sse    ~/.fx/mcp.json  sse        not started",
        "keyed  ~/.fx/mcp.json  http       needs $MISSING_TOKEN",
        "docs   .mcp.json       stdio      waiting for approval",
        "",
      ].join("\n"),
    );
    const json = await mcp(root, "list", "--json");
    expect(json.code).toBe(0);
    const servers = JSON.parse(json.stdout).servers;
    expect(servers.map((s: { name: string; status: string }) => [s.name, s.status])).toEqual([
      ["ctx", "not_started"],
      ["off", "disabled"],
      ["sse", "not_started"],
      ["keyed", "missing_env"],
      ["docs", "waiting_for_approval"],
    ]);
    expect(servers[4]).toMatchObject({ source: "project", file: root.projectPath, transport: "stdio", tools: null, error: null });


    writeFileSync(root.projectPath, JSON.stringify({ mcpServers: { docs: { command: "x", args: ["${FX_VERBS_UNSET}"] } } }));
    await mcp(root, "approve", "docs");
    const noted = await mcp(root, "list");
    expect(noted.code).toBe(0);
    expect(noted.stderr).toBe("note: .mcp.json server 'docs' field argument requires environment variable 'FX_VERBS_UNSET'; set it or use ${FX_VERBS_UNSET:-default}.\n");
    expect(noted.stdout).not.toContain("docs");



    writeFileSync(root.profilePath, JSON.stringify({ mcpServers: { bad: { type: "http", url: "https://b/mcp", headers: { Authorization: "Bearer x" } } } }));
    const refused = await mcp(root, "list");
    expect(refused.code).toBe(0);
    expect(refused.stderr).toContain(
      "note: ~/.fx/mcp.json server 'bad' was skipped: fx won't send its Authorization header; put the token in \"bearerTokenEnvVar\", or sign in with login.\n",
    );
    expect(refused.stdout).not.toContain("bad");

    const empty = await mcp(createRoot(), "list");
    expect(empty.code).toBe(0);
    expect(empty.stdout).toBe("No MCP servers configured. Add one with: fx mcp add NAME URL\n");
  });

  test("show connects to a server and lists its tools; a broken one exits 1", async () => {
    const root = createRoot({ mcpServers: { fixture: fixtureServer(), broken: { command: "fx-mcp-verbs-missing-binary" } } });
    const text = await mcp(root, "show", "fixture");
    expect(text.stderr).toBe("");
    expect(text.code).toBe(0);
    expect(text.stdout).toMatch(/^fixture\n  status     ready, \d+ tools?\n  version    2026-07-28\n  transport  stdio\n  command    /);
    expect(text.stdout).toMatch(/\n    echo +Echo text through the modern MCP fixture\n/);

    const json = await mcp(root, "show", "fixture", "--json");
    expect(json.code).toBe(0);
    const shown = JSON.parse(json.stdout);
    expect(shown).toMatchObject({ name: "fixture", status: "ready", version: "2026-07-28", url: null });
    expect(shown.tools).toContainEqual({ name: "echo", description: "Echo text through the modern MCP fixture" });

    const broken = await mcp(root, "show", "broken");
    expect(broken.code).toBe(1);
    expect(broken.stdout).toMatch(/status     (failed|retrying)\n/);
    expect(broken.stdout).toMatch(/\n  error      .+\n/);

    const unknown = await mcp(root, "show", "nope");
    expect(unknown.code).toBe(1);
    expect(unknown.stderr).toBe("No MCP server named nope. fx mcp list shows them.\n");
  });

  test("a variable a header can't carry holds its server back instead of aborting fx", async () => {

    const root = createRoot({
      mcp: {
        token: { type: "http", url: "http://127.0.0.1:1/mcp", bearerTokenEnvVar: "FX_VERBS_TOKEN" },
        team: { type: "http", url: "http://127.0.0.1:1/mcp", header_env: { "X-Team": "FX_VERBS_TEAM" } },
      },
    });
    root.env = { ...root.env, FX_VERBS_TOKEN: "a\r\nb", FX_VERBS_TEAM: "x\nInjected: yes" } as typeof root.env;
    const shown = await mcp(root, "show", "token");
    expect(shown.stderr).toBe("");
    expect(shown.code).toBe(1);
    expect(shown.stdout).toContain("  status     can't use $FX_VERBS_TOKEN\n");
    const json = await mcp(root, "list", "--json");
    expect(json.code).toBe(0);
    expect(JSON.parse(json.stdout).servers.map((s: { name: string; status: string }) => [s.name, s.status])).toEqual([
      ["token", "invalid_env"],
      ["team", "invalid_env"],
    ]);
  });

  test("${VAR} works in the profile too", async () => {
    const root = createRoot({ mcpServers: { fixture: fixtureServer({ args: ["${FX_VERBS_FIXTURE}"] }) } });
    root.env = { ...root.env, FX_VERBS_FIXTURE: MODERN_FIXTURE } as typeof root.env;
    const shown = await mcp(root, "show", "fixture");
    expect(shown.stderr).toBe("");
    expect(shown.code).toBe(0);
    expect(shown.stdout).toContain("status     ready");
  });

  test("remove finds the server's file, and asks when both files have it", async () => {
    const root = createRoot(
      { mcpServers: { twin: { command: "a" }, solo: { command: "b" } }, other: 1 },
      { mcpServers: { twin: { command: "c" } } },
    );
    const both = await mcp(root, "remove", "twin");
    expect(both.code).toBe(2);
    expect(both.stderr).toBe("twin is in both ~/.fx/mcp.json and .mcp.json. Add --global or --project.\n");

    const project = await mcp(root, "remove", "--project", "twin");
    expect(project.code).toBe(0);
    expect(project.stdout).toBe("Removed twin from .mcp.json.\n");
    expect(JSON.parse(readFileSync(root.projectPath, "utf8"))).toEqual({ mcpServers: {} });

    const solo = await mcp(root, "remove", "solo");
    expect(solo.code).toBe(0);
    expect(JSON.parse(readFileSync(root.profilePath, "utf8"))).toEqual({ mcpServers: { twin: { command: "a" } }, other: 1 });

    const gone = await mcp(root, "remove", "solo");
    expect(gone.code).toBe(1);
    expect(gone.stderr).toBe("No MCP server named solo in ~/.fx/mcp.json or .mcp.json.\n");


    const global = await mcp(root, "remove", "--global", "twin");
    expect(global.code).toBe(0);
    expect(JSON.parse(readFileSync(root.profilePath, "utf8"))).toEqual({ mcpServers: {}, other: 1 });
    const profile = await mcp(root, "remove", "--profile", "twin");
    expect(profile.code).toBe(1);

    expect(profile.stderr).toBe(
      "fx mcp remove: --profile is deprecated and stops working in fx 0.0.18; use --global\nNo MCP server named twin in ~/.fx/mcp.json.\n",
    );
  });

  test("approve and reject say exactly what they trust", async () => {
    const root = createRoot(
      { mcpServers: { mine: { command: "x" } } },
      { mcpServers: { docs: { command: "node", args: ["docs server.js"] }, web: { type: "http", url: "https://w.example/mcp" } } },
    );
    const approved = await mcp(root, "approve", "docs");
    expect(approved.stderr).toBe("");
    expect(approved.code).toBe(0);
    expect(approved.stdout).toBe("Approved docs, which runs: node 'docs server.js'\n");

    const rejected = await mcp(root, "reject", "web");
    expect(rejected.code).toBe(0);
    expect(rejected.stdout).toBe("Rejected web. fx won't start it in this project.\n");

    const all = await mcp(root, "approve", "--all");
    expect(all.code).toBe(0);
    expect(all.stdout).toBe("Approved docs, which runs: node 'docs server.js'\n");

    const settings = JSON.parse(readFileSync(join(root.home, ".fx", "settings.json"), "utf8"));
    expect(settings.workspaces[root.workspace]).toEqual({ enabledMcpjsonServers: ["docs"], disabledMcpjsonServers: ["web"] });

    const list = JSON.parse((await mcp(root, "list", "--json")).stdout).servers;
    expect(list.map((s: { name: string; status: string }) => [s.name, s.status])).toEqual([
      ["mine", "not_started"],
      ["docs", "not_started"],
      ["web", "rejected"],
    ]);

    const profileServer = await mcp(root, "approve", "mine");
    expect(profileServer.code).toBe(1);
    expect(profileServer.stderr).toBe("No project server named mine in .mcp.json.\n");
    const project = JSON.parse(readFileSync(root.projectPath, "utf8"));
    project.mcpServers.later = { command: "node", args: ["later.js"] };
    writeFileSync(root.projectPath, JSON.stringify(project));
    const after = JSON.parse((await mcp(root, "list", "--json")).stdout).servers;
    expect(after.find((s: { name: string }) => s.name === "later")?.status).toBe("waiting_for_approval");
  });

  test("approve --all approves each server it shows, and one added later still waits", async () => {
    const root = createRoot(undefined, { mcpServers: { a: { command: "node", args: ["a.js"] }, b: { type: "http", url: "https://b.example/mcp" } } });
    const all = await mcp(root, "approve", "--all");
    expect(all.code).toBe(0);
    expect(all.stdout).toBe("Approved a, which runs: node a.js\nApproved b, which connects to: https://b.example/mcp\n");
    const settings = JSON.parse(readFileSync(join(root.home, ".fx", "settings.json"), "utf8"));
    expect(settings.workspaces[root.workspace]).toEqual({ enabledMcpjsonServers: ["a", "b"] });
    writeFileSync(root.projectPath, JSON.stringify({ mcpServers: { a: { command: "node", args: ["a.js"] }, b: { type: "http", url: "https://b.example/mcp" }, c: { command: "node", args: ["c.js"] } } }));
    const list = JSON.parse((await mcp(root, "list", "--json")).stdout).servers;
    expect(list.map((s: { name: string; status: string }) => [s.name, s.status])).toEqual([
      ["a", "not_started"],
      ["b", "not_started"],
      ["c", "waiting_for_approval"],
    ]);
  });

  test("help, usage mistakes, and old verbs", async () => {
    const root = createRoot();
    const overview = await mcp(root);
    expect(overview.code).toBe(0);
    expect(overview.stdout).toStartWith("usage: fx mcp COMMAND\n\n  list [--json]               configured servers; never connects\n");
    const verbHelp = await mcp(root, "remove", "-h");
    expect(verbHelp.code).toBe(0);
    expect(verbHelp.stdout).toBe("usage: fx mcp remove [--global | --project | --scope user|project|local] NAME\n");

    const unknownVerb = await mcp(root, "nope");
    expect(unknownVerb.code).toBe(2);
    expect(unknownVerb.stderr).toStartWith("'nope' isn't an fx mcp command.\nusage: fx mcp COMMAND\n");
    const badFlag = await mcp(root, "logout", "--json", "x");
    expect(badFlag.code).toBe(2);
    expect(badFlag.stderr).toBe("fx mcp logout: unknown flag --json\nusage: fx mcp logout NAME\n");

    for (const [args, message] of [
      [["auth", "x"], "fx mcp auth is now fx mcp login NAME.\n"],
      [["trust", "approve", "x"], "fx mcp trust is now fx mcp approve NAME and fx mcp reject NAME.\n"],
      [["path"], "fx mcp path is gone: fx mcp list shows each server's file.\n"],
      [["list", "--connect"], "fx mcp list --connect is now fx mcp show NAME.\n"],
    ] as const) {
      const old = await mcp(root, ...args);
      expect(old.code).toBe(2);
      expect(old.stderr).toBe(message);
      expect(old.stdout).toBe("");
    }
    expect(existsSync(root.profilePath)).toBe(false);
  });

  test("fx mcp commands keep a trace when FX_TRACE_LOG asks for one", async () => {
    const root = createRoot({ mcp: { noisy: { command: "sh", args: ["-c", "echo trace-me >&2; exit 3"], startupTimeoutMs: 2_000 } } });
    const trace = join(root.home, "trace.log");
    const show = await runFx(["mcp", "show", "noisy"], { cwd: root.workspace, env: { ...root.env, FX_TRACE_LOG: trace, FX_TRACE_SCOPES: "mcp" }, timeoutMs: 20_000 });
    expect(show.signal).toBeNull();
    expect(existsSync(trace)).toBe(true);
    expect(readFileSync(trace, "utf8")).toContain("line=trace-me");
  }, 30_000);
});

describe("/mcp in the shell", () => {
  test.skipIf(!tmuxAvailable())("/mcp runs the same verbs and prints the same text", async () => {

    const root = createRoot({ mcpServers: { fixture: fixtureServer({ env: { FX_MCP_EXPECT_ELICITATION: "both" } }) } });
    gateway = startFakeGateway([], { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
    tui = await TmuxSession.create({
      isolated: true,
      cwd: root.workspace,
      width: 120,
      height: 40,
      env: { ...root.env, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5" },
    });
    await tui.waitForComposer(15_000);




    const listed = "fixture  ~/.fx/mcp.json  stdio      ready, 1 tool";
    for (let i = 0; i < 20 && !(await tui.capturePane()).includes(listed); i++) {
      await tui.sendText("/mcp list");
      await tui.waitForText(listed, 500).catch(() => {});
    }
    await tui.waitForText(listed, 1_000);
    expect(await tui.capturePane()).not.toMatch(/mcp \d+\/\d+/);
    await tui.sendText("/mcp show fixture");
    await tui.waitForText("Echo text through the modern MCP fixture", 15_000);
    await tui.waitForText("version    2026-07-28", 5_000);


    await tui.sendLiteral("/mcp ");
    await tui.waitForText("connect to a server and list its tools", 10_000);
    await tui.sendLiteral("show ");
    await tui.waitForText("show fixture", 10_000);
    await tui.sendKeys("C-u");
    await tui.sendLiteral("/mcp login ");
    await Bun.sleep(600);
    expect(await tui.capturePane()).not.toContain("login fixture");
    await tui.sendKeys("C-u");

    await tui.sendText("/mcp add web https://w.example/mcp");
    await tui.waitForText("Added web to ~/.fx/mcp.json.", 10_000);
    await tui.waitForText("It joins the sessions you start from now on; this session keeps the servers it started with.", 10_000);
    await tui.sendText("/mcp list");
    await tui.waitForText("ready, ", 5_000);
    await Bun.sleep(1_000);
    expect(await tui.capturePane()).not.toMatch(/web +~\/\.fx\/mcp\.json +http/);

    await tui.sendText("/mcp nope");
    await tui.waitForText("'nope' isn't a /mcp command.", 10_000);
    await tui.sendText("/mcp list --json");
    await tui.waitForText("/mcp list: unknown flag --json", 10_000);
    await tui.sendText("/mcp auth web");
    await tui.waitForText("/mcp auth is now /mcp login NAME.", 10_000);
    expect(JSON.parse(readFileSync(root.profilePath, "utf8")).mcpServers.web).toEqual({ type: "http", url: "https://w.example/mcp" });
  }, 90_000);

  test.skipIf(!tmuxAvailable())("/mcp add joins a backslash-newline in its arguments the way the shell does", async () => {


    const root = createRoot();
    gateway = startFakeGateway([], { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
    tui = await TmuxSession.create({
      isolated: true,
      cwd: root.workspace,
      width: 120,
      height: 40,
      env: { ...root.env, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5" },
    });
    await tui.waitForComposer(15_000);
    await tui.pasteText('/mcp add probe -- /bin/echo "a\\\nb"');
    await tui.sendKeys("Enter");
    await tui.waitForText("Added probe to ~/.fx/mcp.json.", 10_000);
    expect(JSON.parse(readFileSync(root.profilePath, "utf8")).mcpServers.probe).toEqual({ command: "/bin/echo", args: ["ab"] });
  }, 60_000);

  test.skipIf(!tmuxAvailable())("a config change restarts only the server it changed, never freezes the shell, and a server runs one copy at a time", async () => {


    const root = createRoot();
    const pidPath = join(root.home, "s.pid");
    const eofPath = join(root.home, "s.eof");
    const projPid = join(root.home, "proj.pid");
    const env = { FX_MCP_EXPECT_ELICITATION: "both", FX_MCP_IGNORE_EOF: "1", FX_MCP_IGNORE_TERM: "1", FX_MCP_PID_PATH: pidPath, FX_MCP_EOF_PATH: eofPath };
    writeFileSync(root.profilePath, JSON.stringify({ mcpServers: { s: fixtureServer({ env }) } }));
    writeFileSync(root.projectPath, JSON.stringify({ mcpServers: { proj: fixtureServer({ env: { FX_MCP_PID_PATH: projPid } }) } }));
    gateway = startFakeGateway([], { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
    tui = await TmuxSession.create({
      isolated: true,
      cwd: root.workspace,
      width: 120,
      height: 40,
      env: { ...root.env, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5" },
    });

    const pids = new Set<number>();
    const killServers = () => {
      for (const path of [pidPath, projPid]) if (existsSync(path)) pids.add(Number(readFileSync(path, "utf8")));
      for (const pid of pids) if (isRunning(pid)) process.kill(pid, "SIGKILL");
    };
    const pidIn = (path: string) => (existsSync(path) ? Number(readFileSync(path, "utf8").trim() || "0") : 0);
    try {
      await tui.waitForComposer(15_000);

      const upBy = Date.now() + 10_000;
      while (pidIn(pidPath) === 0 && Date.now() < upBy) await Bun.sleep(5);
      const oldPid = pidIn(pidPath);
      pids.add(oldPid);


      await tui.sendText("/mcp add web https://w.example/mcp");
      await tui.waitForText("Added web to ~/.fx/mcp.json.", 10_000);
      await tui.sendText("/mcp approve proj");
      await tui.waitForText("Approved proj", 10_000);
      const projBy = Date.now() + 10_000;
      while (pidIn(projPid) === 0 && Date.now() < projBy) await Bun.sleep(5);
      expect(pidIn(projPid)).not.toBe(0);
      await tui.sendText("/mcp remove web");
      await tui.waitForText("Removed web from ~/.fx/mcp.json.", 10_000);
      expect(pidIn(pidPath)).toBe(oldPid);
      expect(existsSync(eofPath)).toBe(false);
      expect(isRunning(oldPid)).toBe(true);


      await tui.sendText("/mcp remove s");
      await tui.waitForText("Removed s from ~/.fx/mcp.json.", 10_000);
      const eofBy = Date.now() + 10_000;

      while (!(existsSync(eofPath) && readFileSync(eofPath, "utf8").trim() !== "") && Date.now() < eofBy) await Bun.sleep(5);
      expect(readFileSync(eofPath, "utf8").trim()).toBe(String(oldPid));
      const flags = Object.entries(env).map(([k, v]) => `--env ${k}=${v}`).join(" ");
      await tui.sendText(`/mcp add ${flags} s -- ${process.execPath} ${MODERN_FIXTURE}`);
      await tui.waitForText("Added s to ~/.fx/mcp.json.", 10_000);

      const typedAt = Date.now();
      await tui.sendLiteral("zq");
      await tui.waitForText("zq", 5_000);
      expect(Date.now() - typedAt).toBeLessThan(1_000);
      expect(isRunning(oldPid)).toBe(true);


      const startBy = Date.now() + 15_000;
      while (pidIn(pidPath) === oldPid && Date.now() < startBy) await Bun.sleep(5);
      expect(pidIn(pidPath)).not.toBe(oldPid);
      expect(isRunning(oldPid)).toBe(false);
      await tui.sendKeys("C-u");
      await tui.sendText("/mcp list");
      await tui.waitForText(/s +~\/\.fx\/mcp\.json +stdio +ready, 1 tool/, 15_000);
    } finally {

      await tui?.kill();
      tui = null;
      killServers();
    }
  }, 90_000);

  test.skipIf(!tmuxAvailable())("a config change while a server is in use leaves it running, and the call finishes on the same process", async () => {

    const root = createRoot();
    const pidPath = join(root.home, "s.pid");
    writeFileSync(root.profilePath, JSON.stringify({ mcpServers: { s: fixtureServer({ env: { FX_MCP_EXPECT_ELICITATION: "both", FX_MCP_DISCOVER_DELAY_MS: "3000", FX_MCP_PID_PATH: pidPath } }) } }));
    gateway = startFakeGateway([], { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
    tui = await TmuxSession.create({
      isolated: true,
      cwd: root.workspace,
      width: 120,
      height: 40,
      env: { ...root.env, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5" },
    });
    const pids = new Set<number>();
    try {
      await tui.waitForComposer(15_000);
      const startBy = Date.now() + 10_000;
      while (!existsSync(pidPath) && Date.now() < startBy) await Bun.sleep(5);
      const oldPid = Number(readFileSync(pidPath, "utf8"));
      pids.add(oldPid);

      await tui.sendText("/mcp show s");
      await Bun.sleep(300);
      await tui.sendText("/mcp add web https://w.example/mcp");
      await tui.waitForText("Added web to ~/.fx/mcp.json.", 10_000);
      expect(await tui.capturePane()).not.toContain("Echo text through the modern MCP fixture");


      await tui.waitForText("Echo text through the modern MCP fixture", 10_000);
      pids.add(Number(readFileSync(pidPath, "utf8")));
      expect([...pids]).toEqual([oldPid]);
      expect(isRunning(oldPid)).toBe(true);
    } finally {
      await tui?.kill();
      tui = null;
      for (const pid of pids) if (isRunning(pid)) process.kill(pid, "SIGKILL");
    }
  }, 90_000);

  test.skipIf(!tmuxAvailable())("a server added by fx mcp outside the session waits for the next session, and one removed stays listed as removed", async () => {
    const root = createRoot({ mcpServers: { fixture: fixtureServer() } });
    gateway = startFakeGateway([fakeGatewayFinalText("first done"), fakeGatewayFinalText("second done")], {
      models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }],
    });
    tui = await TmuxSession.create({
      isolated: true,
      cwd: root.workspace,
      width: 120,
      height: 40,
      env: { ...root.env, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5" },
    });
    await tui.waitForComposer(15_000);
    const servers = (body: string) => {
      const from = body.lastIndexOf("<mcp_servers>");
      return from < 0 ? "" : body.slice(from, body.lastIndexOf("</mcp_servers>"));
    };

    expect((await mcp(root, "add", "outside", "--", process.execPath, MODERN_FIXTURE)).code).toBe(0);

    await tui.sendText("first prompt");
    await tui.waitForText("first done", 15_000);
    expect(gateway.requests).toHaveLength(1);
    expect(servers(gateway.requests[0]!.body)).toContain("fixture");
    expect(servers(gateway.requests[0]!.body)).not.toContain("outside");

    await tui.sendText("/mcp list");
    await tui.waitForText(/fixture +~\/\.fx\/mcp\.json +stdio/, 10_000);
    expect(await tui.capturePane()).not.toMatch(/outside +~\/\.fx\/mcp\.json/);

    expect((await mcp(root, "remove", "fixture")).code).toBe(0);
    await tui.sendText("second prompt");
    await tui.waitForText("second done", 15_000);
    expect(gateway.requests).toHaveLength(2);
    expect(servers(gateway.requests[1]!.body)).not.toContain("fixture");
    expect(servers(gateway.requests[1]!.body)).not.toContain("outside");

    await tui.sendText("/mcp list");
    await tui.waitForText(/fixture +~\/\.fx\/mcp\.json +stdio +removed, \d+ tools?/, 10_000);
    expect(await tui.capturePane()).not.toMatch(/outside +~\/\.fx\/mcp\.json/);
  }, 90_000);

  test.skipIf(!tmuxAvailable())("a prompt sent while a turn runs keeps the current servers, and the next prompt after the turn loads the change", async () => {

    const root = createRoot();
    const launcher = join(root.home, "slow.sh");
    writeFileSync(launcher, `#!/bin/sh\necho $$ > slow.pid\nexec '${process.execPath}' '${MODERN_FIXTURE}'\n`, { mode: 0o755 });
    writeFileSync(root.profilePath, JSON.stringify({ mcpServers: { slow: { command: launcher, env: { FX_MCP_EXPECT_ELICITATION: "both" } } } }));
    const held = heldFakeGatewayFinalText();
    gateway = startFakeGateway([held.response, fakeGatewayFinalText("second done"), fakeGatewayFinalText("third done")], {
      models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }],
    });
    tui = await TmuxSession.create({
      isolated: true,
      cwd: root.workspace,
      width: 120,
      height: 40,
      env: { ...root.env, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5" },
    });
    await tui.waitForComposer(15_000);
    const pidPath = join(root.workspace, "slow.pid");
    for (let i = 0; i < 200 && !existsSync(pidPath); i++) await Bun.sleep(25);
    const pid = Number(readFileSync(pidPath, "utf8").trim());
    try {
      expect(isRunning(pid)).toBe(true);
      await tui.sendText("first prompt");
      for (let i = 0; i < 600 && gateway.requests.length === 0; i++) await Bun.sleep(25);
      expect(gateway.requests).toHaveLength(1);

      expect((await mcp(root, "remove", "slow")).code).toBe(0);
      await tui.sendText("second prompt");
      await tui.waitForText("second prompt", 10_000);

      for (let i = 0; i < 50; i++) {
        expect(isRunning(pid)).toBe(true);
        await Bun.sleep(50);
      }
      held.release("first done");
      await tui.waitForText("second done", 15_000);

      await tui.sendText("third prompt");
      await tui.waitForText("third done", 15_000);
      for (let i = 0; i < 200 && isRunning(pid); i++) await Bun.sleep(25);
      expect(isRunning(pid)).toBe(false);
    } finally {
      held.dispose();
      if (isRunning(pid)) process.kill(pid, "SIGKILL");
    }
  }, 90_000);

  test.skipIf(!tmuxAvailable())("a project .mcp.json that is a FIFO or a link to /dev/tty can't stop the shell starting or checking the config", async () => {
    for (const kind of ["fifo", "tty"] as const) {
      const root = createRoot();
      if (kind === "fifo") expect(Bun.spawnSync(["mkfifo", root.projectPath]).exitCode).toBe(0);
      else symlinkSync("/dev/tty", root.projectPath);
      gateway = startFakeGateway([], { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
      tui = await TmuxSession.create({
        isolated: true,
        cwd: root.workspace,
        width: 120,
        height: 30,
        env: { ...root.env, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5" },
      });
      await tui.waitForComposer(15_000);

      await tui.sendText("/mcp list");
      await tui.waitForText("No MCP servers configured", 10_000);
      expect(await tui.captureFullScrollback()).toContain(".mcp.json server 'unknown' was skipped: fx can't read it.");
      await tui.kill();
      tui = null;
      gateway.stop();
      gateway = null;
      rmSync(cleanup!, { recursive: true, force: true });
      cleanup = null;
    }
  }, 60_000);

  test.skipIf(!tmuxAvailable())("the status line, not the transcript, names failing project servers and config problems", async () => {
    const root = createRoot(
      { mcpServers: { docs: { command: "node", args: ["s.js", "${DOCS_TOKEN}"] } } },
      { mcpServers: { broken: { command: "nope" }, proj: { command: "node", args: ["p.js"] } } },
    );
    gateway = startFakeGateway([], { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
    tui = await TmuxSession.create({
      isolated: true,
      cwd: root.workspace,
      width: 140,
      height: 36,
      env: { ...root.env, DOCS_TOKEN: undefined, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5" },
    });

    await tui.waitForComposer(15_000);
    await tui.waitForText("2 MCP need attention · /mcp", 10_000);

    await tui.sendText("/mcp reject broken");
    await tui.waitForText("proj is retrying · /mcp", 10_000);
    await tui.sendText("/mcp reject proj");

    await tui.waitForText("MCP config has 1 problem · /mcp list", 10_000);
    await tui.sendText("/mcp list");
    await tui.waitForText("server 'docs' field argument requires environment variable 'DOCS_TOKEN'", 10_000);

    const scrollback = await tui.captureFullScrollback();
    expect(scrollback).not.toContain("waiting for approval: broken");
    expect(scrollback).not.toContain("Use /mcp approve");
  }, 60_000);

  test.skipIf(!tmuxAvailable())("quitting waits for no server: each gets SIGTERM", async () => {

    const root = createRoot({
      mcpServers: { slow: { command: "/bin/sh", args: ["-c", "echo $$ > slow.pid; trap 'exit 0' TERM; while :; do sleep 0.05; done"] } },
    });
    gateway = startFakeGateway([], { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
    tui = await TmuxSession.create({
      isolated: true,
      cwd: root.workspace,
      width: 140,
      height: 36,
      env: { ...root.env, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5" },
    });
    await tui.waitForComposer(15_000);
    await tui.sendText("/mcp show slow");
    const pidPath = join(root.workspace, "slow.pid");
    for (let i = 0; i < 200 && !existsSync(pidPath); i++) await Bun.sleep(25);
    const pid = Number(readFileSync(pidPath, "utf8").trim());
    try {
      expect(isRunning(pid)).toBe(true);
      await tui.sendKeys("C-c");
      await Bun.sleep(300);
      const start = Date.now();
      await tui.sendKeys("C-c");
      while (tui.isAlive() && Date.now() - start < 5_000) await Bun.sleep(20);

      expect(Date.now() - start).toBeLessThan(1_000);
      for (let i = 0; i < 50 && isRunning(pid); i++) await Bun.sleep(20);
      expect(isRunning(pid)).toBe(false);
    } finally {
      if (isRunning(pid)) process.kill(pid, "SIGKILL");
    }
  }, 60_000);

  test.skipIf(!tmuxAvailable())("/mcp alone opens the menu, whose choices run the verbs", async () => {
    const root = createRoot(
      { mcpServers: { fixture: fixtureServer({ env: { FX_MCP_EXPECT_ELICITATION: "both" } }), web: { type: "http", url: "https://w.example/mcp" } } },
      { mcpServers: { proj: { command: "node", args: ["proj.js", "--port", "4100"], env: { FX_MCP_EXPECT_ELICITATION: "both" } } } },
    );
    symlinkSync(MODERN_FIXTURE, join(root.workspace, "proj.js"));
    expect((await mcp(root, "reject", "proj")).code).toBe(0);
    gateway = startFakeGateway([], { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
    const tracePath = join(root.home, "fx-trace.log");
    tui = await TmuxSession.create({
      isolated: true,
      cwd: root.workspace,
      width: 100,
      height: 36,
      env: { ...root.env, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5", FX_TRACE_LOG: tracePath, FX_TRACE_SCOPES: "mcp" },
    });
    const menuSession = tui;
    failureNotes = () => {
      const trace = existsSync(tracePath) ? readFileSync(tracePath, "utf8").split("\n").slice(-40).join("\n") : "no trace file";
      const profile = existsSync(root.profilePath) ? readFileSync(root.profilePath, "utf8") : "no profile file";
      return `MCP-MENU-ROW-FAILED pane=${JSON.stringify(menuSession.paneStatus())}\nprofile=${profile}\ntrace:\n${trace}`;
    };
    await tui.waitForComposer(15_000);

    await tui.sendText("/mcp");
    await tui.waitForText("MCP servers  3", 10_000);
    await tui.waitForText(/proj +rejected +project/, 5_000);
    await tui.waitForText("↑↓ navigate     enter open     esc close", 5_000);


    await tui.sendLiteral("fix");
    await tui.waitForText("MCP servers  1 of 3", 5_000);
    await tui.sendKeys("Enter");
    await tui.waitForText("Echo text through the modern MCP fixture", 15_000);
    await tui.waitForText("› Remove        /mcp remove fixture", 5_000);

    await tui.sendLiteral("zz");
    await tui.waitForText("No tools match.", 5_000);
    await tui.sendKeys("BSpace BSpace");
    await tui.sendLiteral("THROUGH");
    await tui.waitForText("Tools 1 of 1", 5_000);
    await tui.waitForText("Echo text through the modern MCP fixture", 5_000);

    await tui.sendKeys("Down");
    await tui.waitForText("↑↓ navigate     esc back", 5_000);

    await tui.sendKeys("Escape");
    await tui.waitForText("MCP servers  1 of 3", 5_000);
    await tui.sendKeys("Escape");
    await tui.waitForPane((pane) => !pane.includes("MCP servers") && !pane.includes("fix"), 5_000);


    await tui.sendText("/mcp");
    await tui.waitForText("MCP servers  3", 10_000);
    await tui.sendKeys("Enter");
    await tui.waitForText("↑↓ navigate     enter run     esc back", 10_000);

    await tui.sendKeys("Left");
    await tui.waitForText("↑↓ navigate     enter open     esc close", 5_000);
    await tui.sendKeys("Right");
    await tui.waitForText("↑↓ navigate     enter run     esc back", 10_000);
    await tui.sendKeys("C-c");
    await tui.waitForPane((pane) => !pane.includes("MCP servers") && !pane.includes("esc back"), 5_000);
    expect(await tui.capturePane()).not.toContain("press ctrl+c again to exit");


    await tui.sendText("/mcp");
    await tui.waitForText("MCP servers  3", 10_000);
    await tui.sendKeys("Down Enter");
    await tui.waitForText("› Approve       /mcp approve proj", 5_000);
    await tui.waitForText("Its tools couldn't load: the project server was rejected", 5_000);
    await tui.sendKeys("Enter");
    await tui.waitForText("Approve proj for this project? It runs:", 5_000);
    await tui.waitForText("node proj.js --port 4100", 5_000);
    await tui.waitForText("enter confirm     esc cancel", 5_000);
    await tui.sendLiteral("n");
    await tui.waitForText("↑↓ navigate     enter run     esc back", 5_000);
    expect(await tui.capturePane()).not.toContain("Approved proj");



    await tui.sendKeys("Enter");
    await tui.waitForText("enter confirm     esc cancel", 5_000);
    await tui.sendKeys("Enter");

    await tui.waitForText("› Reject        /mcp reject proj", 10_000);
    expect(await tui.captureFullScrollback()).not.toContain("Approved proj");


    await tui.sendKeys("Escape");
    await tui.waitForText("MCP servers  3", 5_000);

    await tui.sendKeys("Down Enter");
    await tui.waitForText("› Remove        /mcp remove web", 5_000);
    await tui.sendKeys("Enter");

    await tui.waitForText("› Remove web from ~/.fx/mcp.json?   yes  no", 5_000);
    expect(await tui.capturePane()).toContain("↑↓ navigate     enter run     esc back");

    await tui.sendKeys("Right Enter");
    await tui.waitForText("› Remove        /mcp remove web", 5_000);
    await tui.waitForText("↑↓ navigate     enter run     esc back", 5_000);
    expect(JSON.parse(readFileSync(root.profilePath, "utf8")).mcpServers.web).toBeDefined();
    await tui.sendKeys("Enter");
    await tui.waitForText("Remove web from ~/.fx/mcp.json?", 5_000);
    await tui.sendKeys("Enter");

    await tui.waitForText(/web +removed, 0 tools/, 10_000);
    expect(await tui.capturePane()).toContain("MCP servers  3");
    expect(JSON.parse(readFileSync(root.profilePath, "utf8")).mcpServers.web).toBeUndefined();
    expect(await tui.captureFullScrollback()).not.toContain("Removed web");
    failureNotes = null;
  }, 90_000);

  test.skipIf(!tmuxAvailable() || !existsSync("/usr/bin/prlimit"))("a menu choice that cannot start its thread says so, changes nothing, and fx keeps running", async () => {
    const root = createRoot({ mcpServers: { web: { type: "http", url: "https://w.example/mcp" } } });
    gateway = startFakeGateway([], { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
    const tracePath = join(root.home, "fx-trace.log");
    const stderrPath = join(root.home, "fx-stderr.log");
    tui = await TmuxSession.create({
      isolated: true,
      cwd: root.workspace,
      width: 100,
      height: 36,
      stderrPath,
      env: { ...root.env, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5", FX_TRACE_LOG: tracePath, FX_TRACE_SCOPES: "mcp" },
    });
    failureNotes = () => {
      const tail = (path: string) => (existsSync(path) ? readFileSync(path, "utf8").split("\n").slice(-60).join("\n") : "none");
      return `MCP-THREAD-ROW-FAILED\nstderr:\n${tail(stderrPath)}\ntrace:\n${tail(tracePath)}`;
    };
    await tui.waitForComposer(15_000);
    await tui.sendText("/mcp");
    await tui.waitForText(/MCP servers +1/, 10_000);
    await tui.sendKeys("Enter");
    await tui.waitForText("› Remove        /mcp remove web", 10_000);
    await tui.sendKeys("Enter");
    await tui.waitForText("Remove web from ~/.fx/mcp.json?", 5_000);

    const fxPid = String(tui.processPid());
    execFileSync("prlimit", ["--pid", fxPid, "--nproc=1:"]);
    try {
      await tui.sendKeys("Enter");
      await tui.waitForText("fx couldn't start /mcp remove", 10_000);
    } finally {
      execFileSync("prlimit", ["--pid", fxPid, "--nproc=unlimited:"]);
    }
    expect(tui.paneStatus()).toEqual({ dead: false, status: null });
    expect(JSON.parse(readFileSync(root.profilePath, "utf8")).mcpServers.web).toBeDefined();

    await tui.sendKeys("Enter");
    await tui.waitForText("› Remove        /mcp remove web", 10_000);
    await tui.sendKeys("Enter");
    await tui.waitForText("Remove web from ~/.fx/mcp.json?", 5_000);
    await tui.sendKeys("Enter");
    await tui.waitForText(/web +removed, 0 tools/, 10_000);
    expect(JSON.parse(readFileSync(root.profilePath, "utf8")).mcpServers.web).toBeUndefined();
    failureNotes = null;
  }, 90_000);

  test.skipIf(!tmuxAvailable())("/mcp names HOME and writes nothing when HOME is not absolute", async () => {


    const root = createRoot();
    gateway = startFakeGateway([], { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
    tui = await TmuxSession.create({
      isolated: true,
      cwd: root.workspace,
      width: 120,
      height: 40,
      env: { ...root.env, HOME: "relative/home", FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5" },
    });
    await tui.waitForComposer(15_000);
    await tui.sendText("/mcp add web https://w.example/mcp");
    await tui.waitForText("/mcp: HOME is not set to an absolute path", 10_000);
    expect(existsSync(join(root.workspace, ".fx"))).toBe(false);
    expect(existsSync(join(root.workspace, "relative"))).toBe(false);
  }, 60_000);
});

describe("fx ask", () => {
  test("fx ask names unapproved project servers and the command that approves them", async () => {
    const root = createRoot(undefined, { mcpServers: { proj: fixtureServer() } });
    gateway = startFakeGateway([fakeGatewayFinalText("done")], { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
    const result = await runFx(["ask", "--no-save", "hello"], {
      cwd: root.workspace,
      env: { ...root.env, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5" },
      timeoutMs: 30_000,
    });
    expect(result.stderr).toContain("Warning: this folder is not trusted; skipped 1 project-level MCP server: proj.");
    expect(result.stderr).toContain("fx ask: skipped unapproved project MCP servers: proj. Approve with fx mcp approve <name> before retrying.");
  }, 60_000);

  test("a project server whose name holds an escape sequence is skipped with an escaped note, never printed raw", async () => {

    const evil = "evil\u001b]0;pwned\u0007";
    const root = createRoot(undefined, { mcpServers: { proj: fixtureServer(), [evil]: fixtureServer() } });
    const note = "note: .mcp.json server 'evil\\x1b]0;pwned\\x07' was skipped: its name has a character fx won't print.";

    const list = await runFx(["mcp", "list"], { cwd: root.workspace, env: root.env, timeoutMs: 30_000 });
    expect(list.code).toBe(0);
    expect(list.stderr).toContain(note);
    expect(list.stdout).toContain("proj");
    expect(list.stdout).not.toContain("evil");
    expect(list.stdout + list.stderr).not.toContain("\u001b");

    gateway = startFakeGateway([fakeGatewayFinalText("done")], { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
    const ask = await runFx(["ask", "--no-save", "hello"], {
      cwd: root.workspace,
      env: { ...root.env, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5" },
      timeoutMs: 30_000,
    });
    expect(ask.stderr).toContain(note);
    expect(ask.stderr).toContain("fx ask: skipped unapproved project MCP servers: proj. Approve");
    expect(ask.stdout + ask.stderr).not.toContain("\u001b");
  }, 60_000);

  test("a profile with both mcpServers and mcp names each server it leaves out", async () => {
    const root = createRoot({ mcpServers: { alpha: fixtureServer() }, mcp: { beta: fixtureServer() } });
    const note = "note: ~/.fx/mcp.json server 'beta' was skipped: the file has both \"mcpServers\" and \"mcp\", and fx reads only \"mcpServers\"; merge them into one.";

    const list = await runFx(["mcp", "list"], { cwd: root.workspace, env: root.env, timeoutMs: 30_000 });
    expect(list.code).toBe(0);
    expect(list.stdout).toContain("alpha");
    expect(list.stdout).not.toContain("beta");
    expect(list.stderr).toContain(note);

    gateway = startFakeGateway([fakeGatewayFinalText("done")], { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
    const ask = await runFx(["ask", "--no-save", "hello"], {
      cwd: root.workspace,
      env: { ...root.env, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5" },
      timeoutMs: 30_000,
    });
    expect(ask.code).toBe(0);
    expect(ask.stderr).toContain(note);
  }, 60_000);
});
