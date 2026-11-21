export type JsonValue = string | number | boolean | null | readonly JsonValue[] | { readonly [key: string]: JsonValue | undefined }
export type Status = 'exists' | 'planned' | 'absent'

export interface HostVersion {
  interface: 1
  minor: number
  host: 'fx' | 'thebird'
  hostVersion: string
  table: string
}

export interface Capability {
  present: boolean
  since: number
  status: Status
}

export type CapabilityId =
  | 'tools.file' | 'tools.shell' | 'tools.web' | 'tools.agent' | 'tools.session' | 'tools.browser' | 'tools.mcp'
  | 'agent.core' | 'agent.persistence'
  | 'net.fetch' | 'net.tls' | 'net.server' | 'net.ws'
  | 'fs' | 'watch' | 'proc' | 'pty' | 'timers' | 'dns' | 'crypto' | 'sqlite' | 'loader' | 'reload'

export type PermissionMode = 'ask' | 'auto' | 'yolo' | 'dontAsk'
export type DenialReason =
  | 'user_denied' | 'auto_denied' | 'review_caution' | 'review_evidence_incomplete'
  | 'review_unavailable' | 'policy_denied' | 'permission_required' | 'dont_ask_denied'

export declare class FxHostError extends Error {
  code: string
}
export declare class FxPermissionDenied extends FxHostError {
  reason: DenialReason
  tool: string
  target: string | null
  text: string
}
export declare class FxPermissionRequired extends FxHostError {
  tool: string
  target: string | null
  grantSuggestions: JsonValue[]
}
export declare class FxPolicyDenied extends FxHostError {
  rule: string
}
export declare class FxUnknownTool extends FxHostError {
  name: string
}
export declare class FxInvalidArgs extends FxHostError {
  field: string | null
}
export declare class FxToolFailed extends FxHostError {
  text: string
  details: JsonValue
}
export declare class FxDeadline extends FxHostError {
  deadlineMs: number
  scope: 'body' | 'call'
}
export declare class FxUnsupported extends FxHostError {
  name: string
}
export declare class FxCanceled extends FxHostError {}
export declare class FxDenied extends FxHostError {
  target: string
  class: string
}

export interface ToolImage {
  mimeType: string
  data?: string
  sourceRef?: string
}
export interface ToolResult {
  ok: true
  text: string
  images: ToolImage[]
  details?: JsonValue
}

export interface GlobFilesArgs { pattern: string; path?: string; mode?: string; head_limit?: number; offset?: number; include_ignored?: boolean }
export interface GrepFilesArgs {
  pattern: string; path?: string; literal?: boolean; word?: boolean; regex?: boolean; glob?: string; include?: string; type?: string
  output_mode?: string; case_insensitive?: boolean; head_limit?: number; offset?: number; multiline?: boolean
  include_ignored?: boolean; mode?: string; context_lines?: number
}
export interface ReadFileArgs { path: string; start_line?: number; line_count?: number; line_offset?: number; column_offset?: number; n_lines?: number; max_chars?: number }
export interface ReadMediaFileArgs { path: string; region?: JsonValue; full_resolution?: boolean }
export interface WriteFileArgs { path: string; content: string; mode?: 'append' }
export interface EditFileArgs { path: string; old_string: string; new_string: string; replace_all?: boolean }
export interface FetchUrlArgs { url: string; timeout?: number; query?: string; regex?: boolean }
export interface WebSearchArgs { query: string }
export interface BashArgs {
  command: string; cwd?: string; timeout?: number; description?: string
  run_in_background?: boolean; disable_timeout?: boolean; name?: string
}
export interface TaskOutputArgs { task_id: string; wait?: number; tail?: number }
export interface TaskStopArgs { task_id: string; reason?: string }
export interface TaskListArgs { active_only?: boolean; limit?: number }
export interface WaitForArgs { timeout: number; task_id?: string; pid?: number }
export interface SkillArgs { skill: string; args?: string }
export interface InstallSkillArgs { source: string; skill?: string }
export interface AgentArgs { prompt?: string; description?: string; subagent_type?: string; resume?: string; run_in_background?: boolean; fork?: boolean; model?: string }
export interface AgentSwarmArgs { description: string; subagent_type?: string; prompt_template?: string; items?: JsonValue[]; fork?: boolean; resume_agent_ids?: { [id: string]: JsonValue }; model?: string }
export interface SuperagentArgs { action: string; agent?: string; prompt?: string; cwd?: string; session?: string; queue?: JsonValue[]; offset?: number; limit?: number }
export interface AskUserQuestionArgs { questions: JsonValue[]; background?: boolean }
export interface TodoListArgs { todos?: JsonValue[] }
export interface NotifyUserArgs { message: string; title?: string }
export interface ExitPlanModeArgs { plan?: string; options?: JsonValue[] }
export interface VisionArgs { focus: string }
export interface ReadToolResultArgs { handle?: string; query?: string; start_byte?: number; byte_count?: number }
export interface CapabilitySearchArgs { query: string; server?: string }
export interface SelectToolsArgs { names: string[] }
export interface ReadMcpResourceArgs { server: string; uri: string }
export interface CreateGoalArgs { objective: string; completionCriterion?: string; replace?: boolean }
export interface SetGoalBudgetArgs { value: number; unit: 'turns' | 'tokens' | 'milliseconds' | 'seconds' | 'minutes' | 'hours' }
export interface UpdateGoalArgs { status: string }
export interface BrowserArgs { action: string; url?: string; target_id?: string; session_id?: string; expression?: string }

export interface Tools {
  glob_files(args: GlobFilesArgs): Promise<ToolResult>
  grep_files(args: GrepFilesArgs): Promise<ToolResult>
  read_file(args: ReadFileArgs): Promise<ToolResult>
  ReadMediaFile(args: ReadMediaFileArgs): Promise<ToolResult>
  write_file(args: WriteFileArgs): Promise<ToolResult>
  edit_file(args: EditFileArgs): Promise<ToolResult>
  FetchURL(args: FetchUrlArgs): Promise<ToolResult>
  WebSearch(args: WebSearchArgs): Promise<ToolResult>
  Bash(args: BashArgs): Promise<ToolResult>
  TaskOutput(args: TaskOutputArgs): Promise<ToolResult>
  TaskStop(args: TaskStopArgs): Promise<ToolResult>
  TaskList(args?: TaskListArgs): Promise<ToolResult>
  WaitFor(args: WaitForArgs): Promise<ToolResult>
  Skill(args: SkillArgs): Promise<ToolResult>
  install_skill(args: InstallSkillArgs): Promise<ToolResult>
  Agent(args: AgentArgs): Promise<ToolResult>
  AgentSwarm(args: AgentSwarmArgs): Promise<ToolResult>
  superagent(args: SuperagentArgs): Promise<ToolResult>
  AskUserQuestion(args: AskUserQuestionArgs): Promise<ToolResult>
  TodoList(args?: TodoListArgs): Promise<ToolResult>
  NotifyUser(args: NotifyUserArgs): Promise<ToolResult>
  ExitPlanMode(args?: ExitPlanModeArgs): Promise<ToolResult>
  vision(args: VisionArgs): Promise<ToolResult>
  read_tool_result(args: ReadToolResultArgs): Promise<ToolResult>
  capability_search(args: CapabilitySearchArgs): Promise<ToolResult>
  select_tools(args: SelectToolsArgs): Promise<ToolResult>
  ReadMcpResourceTool(args: ReadMcpResourceArgs): Promise<ToolResult>
  CronCreate(args: { cron: string; prompt: string; recurring?: boolean }): Promise<ToolResult>
  CronList(args?: {}): Promise<ToolResult>
  CronDelete(args: { id: string }): Promise<ToolResult>
  CreateGoal(args: CreateGoalArgs): Promise<ToolResult>
  GetGoal(args?: {}): Promise<ToolResult>
  SetGoalBudget(args: SetGoalBudgetArgs): Promise<ToolResult>
  UpdateGoal(args: UpdateGoalArgs): Promise<ToolResult>
  Browser(args: BrowserArgs): Promise<ToolResult>
  TowerInit(args: { [key: string]: JsonValue }): Promise<ToolResult>
  TowerPlan(args: { [key: string]: JsonValue }): Promise<ToolResult>
  TowerSpawn(args: { [key: string]: JsonValue }): Promise<ToolResult>
  TowerMission(args: { [key: string]: JsonValue }): Promise<ToolResult>
  TowerStatus(args: { [key: string]: JsonValue }): Promise<ToolResult>
  TowerMerge(args: { [key: string]: JsonValue }): Promise<ToolResult>
  TowerRebase(args: { [key: string]: JsonValue }): Promise<ToolResult>
  TowerTeardown(args: { [key: string]: JsonValue }): Promise<ToolResult>
  TowerInbox(args: { [key: string]: JsonValue }): Promise<ToolResult>
  TowerSend(args: { [key: string]: JsonValue }): Promise<ToolResult>
  TowerFinding(args: { [key: string]: JsonValue }): Promise<ToolResult>
  TowerReview(args: { [key: string]: JsonValue }): Promise<ToolResult>
  TowerComplete(args: { [key: string]: JsonValue }): Promise<ToolResult>
  $list(): { name: string; description: string; kind: 'tool' | 'host' }[]
}

export type StopReason = 'end_turn' | 'max_output_tokens' | 'max_model_turns' | 'refused' | 'cancelled' | 'yielded'
export interface Usage { inputTokens?: number; outputTokens?: number; cacheReadTokens?: number; cacheWriteTokens?: number; reasoningTokens?: number }
export type TurnEvent =
  | { type: 'text_delta'; delta: string }
  | { type: 'reasoning_delta'; delta: string }
  | { type: 'user_message'; text: string; id?: string }
  | { type: 'tool_start'; id: string; name: string; input?: JsonValue; inputTruncated?: true; inputPreview?: string }
  | { type: 'tool_end'; id: string; name: string; content?: string; isError: boolean }

export interface ToolContext {
  signal: AbortSignal
  executionId: string
  sessionId: string
  context?: JsonValue
}
export interface HostTool<Input = any> {
  name: string
  description: string
  inputSchema: { readonly [key: string]: any }
  execute(input: Input, context: ToolContext): unknown
  idempotent?: boolean
  writes?: boolean
}
export interface ProviderTool { name: 'web_search'; providerExecuted: true }

export interface CustomProvider {
  provider: {
    name: string
    baseUrl: string
    protocol?: 'openai-chat-completions' | 'anthropic-messages'
    models?: { [id: string]: { contextWindow?: number; maxOutputTokens?: number; supportsToolUse?: boolean; supportsVision?: boolean } }
  }
  credentials?(request: { provider: string; sessionId?: string }): { apiKey: string } | Promise<{ apiKey: string }>
}

export interface Persistence {
  load(): Promise<{ checkpoint?: { data: ArrayBuffer | ArrayBufferView; through: string }; journal?: Iterable<{ cursor: string; data: ArrayBuffer | ArrayBufferView }> | AsyncIterable<{ cursor: string; data: ArrayBuffer | ArrayBufferView }>; head?: string | null }>
  append(input: { expected: string | null; idempotencyKey: string; data: Uint8Array; barrier: boolean; marks?: JsonValue[] }): Promise<{ cursor: string }>
  saveCheckpoint?(input: { through: string; data: Uint8Array }): Promise<void>
  marks?: boolean
}

export interface HookEvent {
  version: 1
  type: string
  sessionId: string
  rootSessionId: string
  parentSessionId: string | null
  turnId: string | null
  executionId: string | null
  stepIndex: number
  timestamp: number
  data: JsonValue
}
export interface Hooks {
  onEvent(event: HookEvent): void | Promise<void>
  onError?(error: unknown): void | Promise<void>
  captureContent?: boolean
}

export type NativeHookKind = 'pre_tool_use' | 'stop' | 'post_turn_end' | 'attention_required' | 'user_prompt_submit' | 'observation'

export interface AgentOptions {
  name?: string
  tools?: readonly (HostTool | ProviderTool)[] | { [name: string]: Partial<HostTool> | ProviderTool }
  nativeTools?: boolean | string[]
  instructions?: string | readonly string[]
  hooks?: Hooks
  persistence?: Persistence
  checkpoint?: ArrayBuffer | ArrayBufferView
  model?: string | { id: string; effort?: string; fast?: boolean; ultrafast?: boolean }
  effort?: string
  provider?: 'gateway' | 'codex' | 'grok' | CustomProvider['provider']
  apiKey?: string
  credentials?: CustomProvider['credentials']
  fetch?: (input: string, init: RequestInit) => Promise<Response>
  onEvent?(event: { type: string; timestamp: number; [key: string]: unknown }): void
}

export interface Turn {
  readonly accepted: Promise<{ messageId: string; sessionId: string }>
  readonly result: Promise<{ messageId: string; stopReason: StopReason | 'error' | 'unknown'; usage?: Usage; error?: { name: string; message: string; code?: string | number } }>
  readonly messageId: string | null
  readonly readable: ReadableStream<Uint8Array>
  [Symbol.asyncIterator](): AsyncIterator<TurnEvent & { epoch?: number }>
}

export interface Session {
  readonly id: string | null
  prompt(input: string | readonly JsonValue[], options?: { messageId?: string; signal?: AbortSignal }): Turn
  resume(): Turn
  stream(cursor?: number): ReadableStream<Uint8Array>
  steer(input: string | readonly JsonValue[], options?: { messageId?: string }): Promise<{ messageId: string }>
  cancel(): Promise<void>
  checkpoint(): Promise<Uint8Array>
}

export interface Agent {
  readonly name: string
  readonly sessionId: string | null
  session(id?: string, options?: { context?: JsonValue; model?: string; instructions?: string | readonly string[] }): Session
  newSessionId(): Promise<string>
  prompt(input: string | readonly JsonValue[], options?: { messageId?: string; signal?: AbortSignal }): Turn
  checkpoint(): Promise<Uint8Array>
  wakeHandler(): (request: Request) => Promise<Response>
  close(): Promise<void>
}

export interface AgentApi {
  (options: AgentOptions): Agent
  sessions: {
    list(): Promise<{ id: string; title?: string }[]>
    open(id: string): Session
    fork(id: string): Promise<string>
    delete(id: string): Promise<void>
  }
  hooks: {
    on(kind: NativeHookKind, handler: (input: JsonValue) => JsonValue | void | Promise<JsonValue | void>): () => void
  }
  createMemoryPersistence(): Persistence
}

export interface FsApi {
  readFile(path: string): Promise<Uint8Array>
  writeFile(path: string, data: Uint8Array, options?: { append?: boolean }): Promise<void>
  readRange(path: string, position: number, length: number): Promise<Uint8Array>
  writeAt(path: string, position: number, data: Uint8Array): Promise<void>
  readdir(path: string): Promise<{ name: string; type: string }[]>
  stat(path: string, options?: { follow?: boolean }): Promise<{ size: number; mode: number; type: string; mtimeMs: number }>
  exists(path: string): Promise<boolean>
  mkdir(path: string, options?: { recursive?: boolean }): Promise<void>
  mkdtemp(prefix: string): Promise<string>
  rm(path: string, options?: { recursive?: boolean; force?: boolean }): Promise<void>
  rename(from: string, to: string): Promise<void>
  copy(from: string, to: string, options?: { recursive?: boolean }): Promise<void>
  realpath(path: string): Promise<string>
  readlink(path: string): Promise<string>
  symlink(target: string, path: string): Promise<void>
  link(existing: string, path: string): Promise<void>
  chmod(path: string, mode: number): Promise<void>
  truncate(path: string, length?: number): Promise<void>
}

export interface WatchEvent { type: 'create' | 'change' | 'remove' | 'rename'; path: string }
export interface Watcher { close(): void }

export interface Spawned {
  pid: number
  stdin: WritableStream<Uint8Array>
  stdout: ReadableStream<Uint8Array>
  stderr: ReadableStream<Uint8Array>
  exited: Promise<{ code: number | null; signal: string | null }>
  kill(signal?: string): void
}

export interface Pty {
  write(data: string | Uint8Array): void
  onData(callback: (data: Uint8Array) => void): () => void
  resize(cols: number, rows: number): void
  kill(signal?: string): void
  exited: Promise<{ code: number | null; signal: string | null }>
}

export interface ServeOptions {
  hostname?: string
  port?: number
  tls?: { cert: string; key: string }
  fetch(request: Request): Response | Promise<Response>
  websocket?: {
    open?(socket: ServerWebSocket): void
    message?(socket: ServerWebSocket, data: string | Uint8Array): void
    close?(socket: ServerWebSocket, code: number, reason: string): void
    error?(socket: ServerWebSocket, error: Error): void
  }
}
export interface ServerWebSocket {
  send(data: string | Uint8Array): void
  close(code?: number, reason?: string): void
  data: unknown
}
export interface Server {
  port: number
  close(): Promise<void>
  reload(options: Pick<ServeOptions, 'fetch' | 'websocket'>): void
  upgrade(request: Request, data?: unknown): boolean
}

export interface SqliteDatabase {
  exec(sql: string): void
  prepare(sql: string): { all(...params: JsonValue[]): JsonValue[]; get(...params: JsonValue[]): JsonValue | undefined; run(...params: JsonValue[]): { changes: number; lastInsertRowid: number } }
  close(): void
}

export interface ImportMetaHot {
  readonly data: { [key: string]: unknown }
  accept(deps?: string | string[], callback?: (modules: unknown[]) => void): void
  dispose(callback: (data: { [key: string]: unknown }) => void): void
  invalidate(reason?: string): void
  decline(): void
}

export interface ReloadFailure {
  type: 'reload.failed'
  path: string
  phase: 'parse' | 'evaluate' | 'accept' | 'apply'
  error: { name: string; message: string; stack?: string }
}

export interface Host {
  version: HostVersion
  capabilities: { [id in CapabilityId]?: Capability }
  tools: Tools
  agent: AgentApi
  fetch: typeof fetch
  serve(options: ServeOptions): Server
  fs: FsApi
  watch(path: string, options: { recursive?: boolean }, callback: (event: WatchEvent) => void): Watcher
  proc: {
    spawn(options: { cmd: string; args?: string[]; cwd?: string; env?: { [key: string]: string }; signal?: AbortSignal }): Spawned
    exit(code?: number): never
    info(): { pid: number; ppid: number; cwd: string; home: string; tmp: string; exePath: string; args: string[]; env: { [key: string]: string }; platform: string; arch: string }
  }
  pty: { open(options: { cmd: string; args?: string[]; cwd?: string; env?: { [key: string]: string }; cols?: number; rows?: number }): Pty }
  timers: { setTimeout: typeof setTimeout; setInterval: typeof setInterval; clearTimeout: typeof clearTimeout; clearInterval: typeof clearInterval; now(): number }
  dns: { lookup(hostname: string, options?: { family?: 4 | 6 }): Promise<{ address: string; family: 4 | 6 }[]> }
  crypto: {
    randomBytes(n: number): Uint8Array
    hash(algorithm: string, data: Uint8Array): Uint8Array
    hmac(algorithm: string, key: Uint8Array, data: Uint8Array): Uint8Array
    subtle: SubtleCrypto
  }
  sqlite: { open(path: string, options?: { readonly?: boolean }): SqliteDatabase }
  loader: {
    root: { path: string; rule: 'js-root-flag' | 'FX_JS_ROOT' | 'project' | 'home' }
    resolve(specifier: string, parent: string): string
  }
  reload: {
    markHealthy(): void
    dependents(path: string): string[]
    on(event: 'applied' | 'failed', callback: (payload: { path: string } | ReloadFailure) => void): () => void
  }
}

declare module 'fx:host' {
  const host: Host
  export default host
  export const version: Host['version']
  export const capabilities: Host['capabilities']
  export const tools: Host['tools']
  export const agent: Host['agent']
  export const fetch: Host['fetch']
  export const serve: Host['serve']
  export const fs: Host['fs']
  export const watch: Host['watch']
  export const proc: Host['proc']
  export const pty: Host['pty']
  export const timers: Host['timers']
  export const dns: Host['dns']
  export const crypto: Host['crypto']
  export const sqlite: Host['sqlite']
  export const loader: Host['loader']
  export const reload: Host['reload']
}

interface ImportMeta {
  hot?: ImportMetaHot
}
