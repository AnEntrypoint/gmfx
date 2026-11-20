














export interface AuthServer {

  metadata?: "oauth" | "oidc";

  issuer?: string;

  pkce?: boolean;

  issSupported?: boolean;

  iss?: "correct" | "omit" | "wrong";

  dcr?: boolean;
  scopesSupported?: string[];
  expiresIn?: number;

  refresh?: boolean;
  rotate?: boolean;

  refreshError?: string;

  refreshStatus?: number;

  refreshDelayMs?: number[];

  insecureEndpoint?: boolean;

  internalEndpoint?: boolean;

  grantOnly?: string[];

  deny?: string;

  revoke?: boolean;

  codeError?: { error: string; description?: string };

  tokenType?: string;

  tokenSuffix?: string;
}

export interface AuthConfig {

  prm?: string;

  inChallenge?: boolean;

  challengeUrl?: string;

  resource?: string;

  authorizationServer?: string;
  scopesSupported?: string[];

  challengeScope?: string;

  requiredScopes?: Record<string, string[]>;
  servers: AuthServer[];

  migrateAfterTokens?: number;

  tokenUses?: number;
}

type Log = (entry: object) => void;

interface Token {
  server: number;
  scopes: string[];
  uses: number;
}

export function createAuth(config: AuthConfig, base: () => string, log: Log) {
  let active = 0;
  let tokens = 0;
  let clients = 0;
  const access = new Map<string, Token>();
  const refresh = new Map<string, { server: number; scopes: string[] }>();

  const refreshes: number[] = [];
  const codes = new Map<string, { server: number; challenge: string; redirect: string; scopes: string[]; resource: string }>();
  const prmPath = config.prm === undefined || config.prm === "path" ? "/.well-known/oauth-protected-resource/mcp" : config.prm === "root" ? "/.well-known/oauth-protected-resource" : config.prm;
  const prmUrl = () => base() + prmPath;
  const serverUrl = (i: number) => `${base()}/as${i + 1}`;
  const issuerOf = (i: number) => config.servers[i].issuer ?? serverUrl(i);

  function challenge(error?: string, scope?: string): string {
    const parts = ["Bearer"];
    const params: string[] = [];
    if (error) params.push(`error="${error}"`);
    if (scope) params.push(`scope="${scope}"`);
    const url = config.challengeUrl === "foreign" ? prmUrl().replace("127.0.0.1", "localhost") : (config.challengeUrl ?? prmUrl());
    if (config.inChallenge !== false) params.push(`resource_metadata="${url}"`);
    return parts.concat(params.join(", ")).join(" ");
  }

  function metadata(i: number) {
    const s = config.servers[i];
    const url = serverUrl(i);
    return {
      issuer: issuerOf(i),
      authorization_endpoint: `${url}/authorize`,
      token_endpoint: s.insecureEndpoint ? "http://auth.example.com/token" : s.internalEndpoint ? "https://0.0.0.0:1/token" : `${url}/token`,
      ...(s.dcr === false ? {} : { registration_endpoint: `${url}/register` }),
      ...(s.revoke ? { revocation_endpoint: `${url}/revoke` } : {}),
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      ...(s.pkce === false ? {} : { code_challenge_methods_supported: ["S256"] }),
      ...(s.issSupported === false ? {} : { authorization_response_iss_parameter_supported: true }),
      token_endpoint_auth_methods_supported: ["none"],
      ...(s.scopesSupported ? { scopes_supported: s.scopesSupported } : {}),
    };
  }

  function issue(server: number, scopes: string[]) {
    const s = config.servers[server];
    tokens += 1;
    const at = `at${tokens}${s.tokenSuffix ?? ""}`;
    access.set(at, { server, scopes, uses: 0 });
    const body: Record<string, unknown> = { access_token: at, token_type: s.tokenType ?? "Bearer", expires_in: s.expiresIn ?? 3600, scope: scopes.join(" ") };
    if (s.refresh !== false) {
      const rt = `rt${tokens}`;
      refresh.set(rt, { server, scopes });
      body.refresh_token = rt;
    }
    if (config.migrateAfterTokens !== undefined && tokens >= config.migrateAfterTokens && active + 1 < config.servers.length) active += 1;
    return body;
  }

  async function sha256url(text: string): Promise<string> {
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
    return Buffer.from(digest).toString("base64url");
  }

  return {

    async route(req: Request): Promise<Response | null> {
      const url = new URL(req.url);
      const path = url.pathname;
      if (path === prmPath && req.method === "GET") {
        log({ dir: "auth", path, host: req.headers.get("host"), encoding: req.headers.get("accept-encoding") });
        return Response.json({ resource: config.resource ?? `${base()}/mcp`, authorization_servers: [config.authorizationServer ?? issuerOf(active)], ...(config.scopesSupported ? { scopes_supported: config.scopesSupported } : {}) });
      }
      const m = path.match(/^(?:\/\.well-known\/(oauth-authorization-server|openid-configuration))?\/as(\d+)(\/.*)?$/);
      if (!m) return null;
      const i = Number(m[2]) - 1;
      const s = config.servers[i];
      if (!s) return null;
      const rest = m[3] ?? "";
      const form = req.method === "POST" && (req.headers.get("content-type") ?? "").includes("form") ? Object.fromEntries(new URLSearchParams(await req.text())) : undefined;
      const json = req.method === "POST" && (req.headers.get("content-type") ?? "").includes("json") ? await req.json() : undefined;
      log({ dir: "auth", path, host: req.headers.get("host"), encoding: req.headers.get("accept-encoding"), query: Object.fromEntries(url.searchParams), form, json, authorization: req.headers.get("authorization") });
      const wellKnown = m[1] ?? (rest === "/.well-known/openid-configuration" ? "openid-configuration-appended" : undefined);
      if (wellKnown) {
        const want = s.metadata === "oidc" ? "openid-configuration-appended" : "oauth-authorization-server";
        return wellKnown === want ? Response.json(metadata(i)) : new Response("Not Found", { status: 404 });
      }
      if (rest === "/authorize") {
        const q = url.searchParams;
        const code = `code${codes.size + 1}`;
        codes.set(code, { server: i, challenge: q.get("code_challenge") ?? "", redirect: q.get("redirect_uri") ?? "", scopes: (q.get("scope") ?? "").split(" ").filter(Boolean), resource: q.get("resource") ?? "" });
        const back = new URL(q.get("redirect_uri") ?? "http://invalid/");
        if (s.deny) {
          back.searchParams.set("error", "access_denied");
          back.searchParams.set("error_description", s.deny);
        } else back.searchParams.set("code", code);
        if (q.get("state")) back.searchParams.set("state", q.get("state")!);
        const iss = s.iss ?? "correct";
        if (iss === "correct") back.searchParams.set("iss", issuerOf(i));
        if (iss === "wrong") back.searchParams.set("iss", "https://evil.example.com");
        return Response.redirect(back.toString(), 302);
      }
      if (rest === "/register" && req.method === "POST") {
        clients += 1;
        return Response.json({ client_id: `client${clients}-as${i + 1}`, token_endpoint_auth_method: "none", redirect_uris: json?.redirect_uris ?? [] }, { status: 201 });
      }
      if (rest === "/revoke" && req.method === "POST" && form && s.revoke) {
        refresh.delete(form.token);
        access.delete(form.token);
        return new Response(null, { status: 200 });
      }
      if (rest === "/token" && req.method === "POST" && form) {
        if (form.grant_type === "authorization_code") {
          const c = codes.get(form.code);
          codes.delete(form.code);
          if (s.codeError) {
            const { error, description } = s.codeError;
            return Response.json(description === undefined ? { error } : { error, error_description: description }, { status: 400 });
          }
          if (!c || c.server !== i || c.redirect !== form.redirect_uri || !form.resource || c.challenge !== (await sha256url(form.code_verifier ?? "")))
            return Response.json({ error: "invalid_grant" }, { status: 400 });
          return Response.json(issue(i, s.grantOnly ? c.scopes.filter((x) => s.grantOnly!.includes(x)) : c.scopes));
        }
        if (form.grant_type === "refresh_token") {
          if (s.refreshError) {
            const status = s.refreshStatus ?? 400;
            return Response.json(status === 200 ? { ok: false, error: s.refreshError } : { error: s.refreshError }, { status });
          }
          const r = refresh.get(form.refresh_token);
          if (!r || r.server !== i || !form.resource) return Response.json({ error: "invalid_grant" }, { status: 400 });
          const body = issue(i, r.scopes);
          if (s.rotate === false) {
            refresh.delete(body.refresh_token as string);
            delete body.refresh_token;
          } else refresh.delete(form.refresh_token);
          const n = refreshes[i] ?? 0;
          refreshes[i] = n + 1;
          const delay = s.refreshDelayMs?.[n] ?? 0;
          if (delay > 0) await Bun.sleep(delay);
          return Response.json(body);
        }
        return Response.json({ error: "unsupported_grant_type" }, { status: 400 });
      }
      return new Response("Not Found", { status: 404 });
    },


    check(req: Request, method: string | undefined): Response | null {
      const header = req.headers.get("authorization") ?? "";
      const t = header.startsWith("Bearer ") ? access.get(header.slice(7)) : undefined;
      const limit = config.tokenUses ?? Infinity;
      if (!t || t.server !== active || t.uses >= limit) {
        return Response.json({ error: "invalid_token" }, { status: 401, headers: { "www-authenticate": challenge(undefined, config.challengeScope) } });
      }
      const needed = (method && config.requiredScopes?.[method]) ?? [];
      if (!needed.every((n) => t.scopes.includes(n))) {
        return Response.json({ error: "insufficient_scope" }, { status: 403, headers: { "www-authenticate": challenge("insufficient_scope", needed.join(" ")) } });
      }
      t.uses += 1;
      return null;
    },
  };
}
