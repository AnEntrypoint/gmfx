import { execFileSync } from "node:child_process";
import { readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

export type OwnedTmuxSession = {
  name: string;
  exitStatusPath: string;
  ownSocketName?: string;
  sharedSocketName?: string;
};

type OwnedServer = { stop(closeActiveConnections?: boolean): void };

const HANGUP_GRACE_MS = 200;
const EXIT_CODE_BY_SIGNAL = { SIGHUP: 129, SIGINT: 130, SIGTERM: 143 } as const;
const OWN_SOCKET = /^fx-e2e-(\d+)-\d+-\d+$/;
const OWN_SESSION = /^fx-test-(\d+)-\d+(?:-setup)?$/;
const OWN_EXIT_STATUS = /^fx-test-(\d+)-\d+\.exit-status$/;

const tmuxSessions = new Map<string, OwnedTmuxSession>();
const servers = new Set<OwnedServer>();
const tempDirs = new Set<string>();
let hooked = false;
let swept = false;

export function ownTmuxSession(session: OwnedTmuxSession): void {
  hookProcessEnd();
  tmuxSessions.set(session.name, session);
}

export function disownTmuxSession(name: string): void {
  tmuxSessions.delete(name);
}

export function ownServer<Server extends OwnedServer>(server: Server): Server {
  hookProcessEnd();
  servers.add(server);
  return server;
}

export function disownServer(server: OwnedServer): void {
  servers.delete(server);
}

export function ownTempDir(path: string): string {
  hookProcessEnd();
  tempDirs.add(path);
  return path;
}

export function disownTempDir(path: string): void {
  tempDirs.delete(path);
}

export function ownedLeftovers(): { tmuxSessions: string[]; servers: number; tempDirs: string[] } {
  return { tmuxSessions: [...tmuxSessions.keys()], servers: servers.size, tempDirs: [...tempDirs] };
}

export function tearDownOwned(): void {
  for (const session of tmuxSessions.values()) endTmuxSession(session);
  tmuxSessions.clear();
  for (const server of servers) {
    try {
      server.stop(true);
    } catch {}
  }
  servers.clear();
  for (const dir of tempDirs) rmSync(dir, { recursive: true, force: true });
  tempDirs.clear();
}

export function removeSocketOfEndedTmuxServer(socketName: string): void {
  if (tmux(["-L", socketName, "list-sessions"]) !== null) return;
  rmSync(join(tmuxSocketDir(), socketName), { force: true });
}

export function sweepLeftoversOfEndedTestProcesses(): void {
  if (swept) return;
  swept = true;
  const socketDir = tmuxSocketDir();
  for (const socket of entriesOf(socketDir)) {
    if (!ownerEnded(OWN_SOCKET.exec(socket))) continue;
    tmux(["-L", socket, "kill-server"]);
    rmSync(join(socketDir, socket), { force: true });
  }
  for (const session of (tmux(["list-sessions", "-F", "#{session_name}"]) ?? "").split("\n")) {
    if (ownerEnded(OWN_SESSION.exec(session))) tmux(["kill-session", "-t", session]);
  }
  for (const file of entriesOf(tmpdir())) {
    if (ownerEnded(OWN_EXIT_STATUS.exec(file))) rmSync(join(tmpdir(), file), { force: true });
  }
}

function endTmuxSession(session: OwnedTmuxSession): void {
  const socket = session.ownSocketName ?? session.sharedSocketName;
  const onSocket = socket ? ["-L", socket] : [];
  const pane = Number.parseInt(tmux([...onSocket, "display-message", "-p", "-t", session.name, "#{pane_pid}"]) ?? "", 10);
  tmux(session.ownSocketName ? [...onSocket, "kill-server"] : [...onSocket, "kill-session", "-t", session.name]);
  if (Number.isSafeInteger(pane) && pane > 1) endProcessGroup(pane);
  if (session.ownSocketName) rmSync(join(tmuxSocketDir(), session.ownSocketName), { force: true });
  rmSync(session.exitStatusPath, { force: true });
}

function endProcessGroup(leader: number): void {
  const deadline = Date.now() + HANGUP_GRACE_MS;
  while (Date.now() < deadline && isRunning(-leader)) Bun.sleepSync(10);
  try {
    process.kill(-leader, "SIGKILL");
  } catch {}
}

function hookProcessEnd(): void {
  if (hooked) return;
  hooked = true;
  process.on("exit", tearDownOwned);
  for (const [signal, code] of Object.entries(EXIT_CODE_BY_SIGNAL)) {
    process.on(signal, () => {
      tearDownOwned();
      process.exit(code);
    });
  }
}

function tmux(args: string[]): string | null {
  try {
    return execFileSync("tmux", args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
  } catch {
    return null;
  }
}

function tmuxSocketDir(): string {
  return join(process.env.TMUX_TMPDIR ?? "/tmp", `tmux-${process.getuid?.() ?? 0}`);
}

function entriesOf(dir: string): string[] {
  try {
    return readdirSync(dir);
  } catch {
    return [];
  }
}

function ownerEnded(match: RegExpExecArray | null): boolean {
  if (!match) return false;
  const owner = Number(match[1]);
  return owner !== process.pid && !isRunning(owner);
}

function isRunning(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
}
