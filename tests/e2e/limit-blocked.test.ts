import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";
import { fakeGatewayFinalText, startFakeGateway } from "./tmux-helpers";

const TIMEOUT = 30_000;
const BLOCKED_NOTICE = "blocked: a provider limit ended this turn";

function isolatedRoot() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-limit-e2e-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  return { root, home, workspace };
}

function gatewayEnv(home: string, gateway: ReturnType<typeof startFakeGateway>) {
  return {
    HOME: home,
    AI_GATEWAY_API_KEY: "fake-limit-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: gateway.model,
    FX_SOUND: "0",
  };
}

function limitResponse(status: number, body: object, headers: Record<string, string> = {}) {
  return () => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...headers } });
}

async function askOnce(responses: Parameters<typeof startFakeGateway>[0], prompt: string) {
  const root = isolatedRoot();
  const gateway = startFakeGateway(responses);
  try {
    const result = await runFx(["ask", "--auto", "--json", prompt], {
      cwd: root.workspace,
      env: gatewayEnv(root.home, gateway),
      timeoutMs: TIMEOUT,
    });
    return { result, requests: gateway.requests.length };
  } finally {
    gateway.stop();
    rmSync(root.root, { recursive: true, force: true });
  }
}

describe("a turn ended by a provider limit", () => {
  test("HTTP 402 ends fx ask as blocked after one request", async () => {
    const { result, requests } = await askOnce(
      [limitResponse(402, { error: { code: "insufficient_quota", message: "The account has no credits left." } })],
      "Say hello after a payment error.",
    );
    expect(requests).toBe(1);
    expect(result.code).toBe(1);
    expect(JSON.parse(result.stdout.trim()).blocked).toBe("limit");
    expect(result.stderr).toContain(BLOCKED_NOTICE);
  }, TIMEOUT);

  test("a usage limit message on HTTP 429 is not retried and ends as blocked", async () => {
    const { result, requests } = await askOnce(
      [limitResponse(429, { error: { type: "rate_limit_error", message: "You've reached your usage limit for this period." } })],
      "Say hello at the usage limit.",
    );
    expect(requests).toBe(1);
    expect(result.code).toBe(1);
    expect(JSON.parse(result.stdout.trim()).blocked).toBe("limit");
    expect(result.stderr).toContain(BLOCKED_NOTICE);
  }, TIMEOUT);

  test("a rate limit that will not clear within five minutes is not waited out", async () => {
    const { result, requests } = await askOnce(
      [limitResponse(429, { error: { code: "rate_limit_exceeded", message: "Too many requests." } }, { "retry-after": "900" })],
      "Say hello behind a long rate limit.",
    );
    expect(requests).toBe(1);
    expect(result.code).toBe(1);
    expect(JSON.parse(result.stdout.trim()).blocked).toBe("limit");
  }, TIMEOUT);

  test("a short rate limit is retried and the answer is not marked blocked", async () => {
    const { result, requests } = await askOnce(
      [
        limitResponse(429, { error: { code: "rate_limit_exceeded", message: "Too many requests." } }, { "retry-after": "1" }),
        () => fakeGatewayFinalText("Hello after the short wait."),
      ],
      "Say hello behind a short rate limit.",
    );
    expect(requests).toBe(2);
    expect(result.code).toBe(0);
    const parsed = JSON.parse(result.stdout.trim());
    expect(parsed.blocked).toBeUndefined();
    expect(parsed.output).toContain("Hello after the short wait.");
  }, TIMEOUT);
});
