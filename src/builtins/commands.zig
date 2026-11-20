const std = @import("std");
const command_specs = @import("../core/slash_commands/command_specs.zig");

const Allocator = std.mem.Allocator;

pub const TopLevelKind = command_specs.TopLevelKind;
pub const TopLevelSpec = command_specs.TopLevelSpec;
pub const TopLevelHelpGroup = command_specs.TopLevelHelpGroup;
pub const TopLevelFlag = command_specs.TopLevelFlag;
pub const TopLevelExample = command_specs.TopLevelExample;
pub const TopLevelResource = command_specs.TopLevelResource;
pub const TopLevelRegistry = command_specs.TopLevelRegistry;
pub const HelpStyle = command_specs.HelpStyle;
pub const SlashKind = command_specs.SlashKind;
pub const SlashPresentationCategory = command_specs.SlashPresentationCategory;
pub const SlashSpec = command_specs.SlashSpec;
pub const SlashRegistry = command_specs.SlashRegistry;

const json_option = command_specs.OptionDoc{ .flag = "--json", .description = "Emit machine-readable JSON instead of text" };

pub const json_only_options = [_]command_specs.OptionDoc{json_option};

const login_providers = [_]command_specs.SubcommandDoc{
    .{ .usage = "vercel", .description = "Vercel AI Gateway (the default)", .options = &login_options },
    .{ .usage = "codex", .description = "ChatGPT subscription" },
    .{ .usage = "grok", .description = "Grok subscription" },
};

pub const login_options = [_]command_specs.OptionDoc{
    .{ .flag = "--api-key", .description = "Paste a Vercel AI Gateway API key instead of signing in through the browser" },
};

pub const sessions_options = [_]command_specs.OptionDoc{
    .{ .flag = "--all", .description = "List saved sessions across every workspace in this profile" },
    .{ .flag = "--cwd <path>", .description = "List the saved sessions of this working directory instead of the current one" },
    .{ .flag = "--archived", .description = "Include archived sessions, each marked [archived]" },
    .{ .flag = "--limit <1-100>", .description = "Set the maximum sessions returned per page" },
    .{ .flag = "--cursor <cursor>", .description = "Continue from a prior sessions result" },
    json_option,
};

pub const sessions_convert_options = [_]command_specs.OptionDoc{json_option};

pub const sessions_delete_options = [_]command_specs.OptionDoc{
    .{ .flag = "-y", .description = "Delete the session without asking" },
    .{ .flag = "--yes", .description = "Delete the session without asking" },
};

pub const sessions_purge_options = [_]command_specs.OptionDoc{
    .{ .flag = "--cwd <path>", .description = "Purge the saved sessions of this working directory instead of the current one" },
    .{ .flag = "--older-than <days>", .description = "Delete only sessions last updated more than this many days ago; at least 1" },
    .{ .flag = "-y", .description = "Delete the sessions; without it fx only reports how many would be deleted" },
    .{ .flag = "--yes", .description = "Delete the sessions; without it fx only reports how many would be deleted" },
};

pub const sessions_fork_options = [_]command_specs.OptionDoc{
    .{ .flag = "--cwd <path>", .description = "Fork the most recent session of this working directory instead of the current one" },
    .{ .flag = "-y", .description = "Fork the most recent session without asking; required when no id is given" },
    .{ .flag = "--yes", .description = "Fork the most recent session without asking; required when no id is given" },
};

pub const sessions_import_options = [_]command_specs.OptionDoc{
    .{ .flag = "--days <1-365>", .description = "Import sessions changed within this many days (default: 30)" },
};

pub const sessions_export_options = [_]command_specs.OptionDoc{
    .{ .flag = "-o <path>", .description = "Write the zip archive to this path instead of the temporary directory" },
    .{ .flag = "--output <path>", .description = "Write the zip archive to this path instead of the temporary directory" },
    .{ .flag = "-y", .description = "Export the most recent session without asking; required when no id is given" },
    .{ .flag = "--yes", .description = "Export the most recent session without asking; required when no id is given" },
    .{ .flag = "--no-include-global-log", .description = "Leave the active diagnostic log out of the archive" },
};

pub const usage_options = [_]command_specs.OptionDoc{
    .{ .flag = "--period <today|7d|month>", .description = "Select the period, in UTC days (default: month)" },
    json_option,
};

pub const upgrade_options = [_]command_specs.OptionDoc{
    .{ .flag = "--channel <stable|dev>", .description = "Select and remember the release channel" },
    json_option,
};

pub const workspace_options = [_]command_specs.OptionDoc{json_option};

const workspace_subcommands = [_]command_specs.SubcommandDoc{
    .{ .usage = "list", .description = "List the primary and additional directories (default)" },
    .{ .usage = "add PATH", .description = "Persist an existing additional directory" },
    .{ .usage = "remove PATH", .description = "Remove an additional directory" },
    .{ .usage = "clear", .description = "Remove all additional directories" },
};

const config_subcommands = [_]command_specs.SubcommandDoc{
    .{ .usage = "list", .description = "List the values set in each settings file (default)", .options = &config_options },
    .{ .usage = "get <key>", .description = "Print the value fx uses for a setting", .options = &config_options },
    .{ .usage = "set <key> <value>", .description = "Save a preference in ~/.fx/settings.json", .settable_key = true },
    .{ .usage = "unset <key>", .description = "Remove a preference from ~/.fx/settings.json", .settable_key = true },
    .{ .usage = "schema", .description = "Print the JSON Schema for ~/.fx/settings.json", .options = &config_schema_options },
};

const config_schema_options = [_]command_specs.OptionDoc{
    .{ .flag = "--project", .description = "Print the schema for a project .fx.json instead" },
};

pub const config_parse_options = config_options ++ config_schema_options;

const config_options = [_]command_specs.OptionDoc{
    .{ .flag = "--global", .description = "Only the profile's own settings" },
    .{ .flag = "--workspace", .description = "Only this workspace's override in the profile (list and get)" },
    .{ .flag = "--show-origin", .description = "Start each line with where the value is set" },
    json_option,
};

const session_subcommands = [_]command_specs.SubcommandDoc{
    .{ .usage = "last", .description = "Inspect the current workspace session" },
    .{ .usage = "resume [last|<id>]", .description = "Resume the latest workspace session or a session by id" },
    .{ .usage = "recover <id>", .description = "Copy a recoverable corrupt session into a new session" },
};

pub const session_options = [_]command_specs.OptionDoc{
    .{ .flag = "--id <id>", .description = "Inspect a saved session by exact id" },
    json_option,
};

pub const acp_options = agentRunOptions("sessions this server starts", .without_provider_order) ++ [_]command_specs.OptionDoc{
    .{ .flag = "--log-file <path>", .description = "Write ACP logs to a file" },
    .{ .flag = "--login", .description = "Sign in as fx login does, then exit; ACP clients run it for the terminal login" },
};

pub const acp_usage = "acp " ++ agent_run_usage_base ++ " [--log-file <path>] [--login]";

pub const pr_options = agentRunOptions("this request", .with_provider_order) ++ [_]command_specs.OptionDoc{
    .{ .flag = "--create", .description = "Publish the drafted pull request via the GitHub CLI" },
};

const issue_options = agentRunOptions("this request", .with_provider_order) ++ [_]command_specs.OptionDoc{
    .{ .flag = "--create", .description = "Publish the drafted issue via the GitHub CLI" },
};

pub const replay_options = [_]command_specs.OptionDoc{
    .{ .flag = "--frames", .description = "Render each captured frame" },
    .{ .flag = "--golden <path>", .description = "Write the final rendered grid to a file" },
    .{ .flag = "--frames-dir <path>", .description = "Write rendered frames to a directory" },
    json_option,
};

const mcp_subcommands = [_]command_specs.SubcommandDoc{
    .{ .usage = "list", .description = "List configured servers; never connects", .options = &mcp_list_options },
    .{ .usage = "show NAME", .description = "Connect to a server: status, version, and tools", .options = &mcp_show_options },
    .{
        .usage = "add NAME URL",
        .description = "Add an HTTP server, or a command after --",
        .subcommands = &.{.{ .usage = "slack", .description = "Add Slack's server" }},
        .options = &mcp_add_options,
    },
    .{ .usage = "remove NAME", .description = "Remove a server and its login", .options = &mcp_scope_options },
    .{ .usage = "login NAME", .description = "Sign in to an HTTP server", .options = &mcp_login_options },
    .{ .usage = "logout NAME", .description = "Sign out and delete the login" },
    .{ .usage = "approve NAME", .description = "Approve a project server from .mcp.json", .options = &mcp_approve_options },
    .{ .usage = "reject NAME", .description = "Reject a project server" },
    .{
        .usage = "call TOOL [JSON | -]",
        .description = "Run an MCP tool from a command fx's shell tool runs",
        .subcommands = &.{
            .{ .usage = "list SERVER", .description = "List a server's tools" },
            .{ .usage = "search QUERY...", .description = "Find the tools that match QUERY" },
            .{ .usage = "help TOOL", .description = "Show a tool's arguments" },
        },
    },
};

pub const mcp_scope_options = [_]command_specs.OptionDoc{
    .{ .flag = "--global", .description = "Use ~/.fx/mcp.json, the default" },
    .{ .flag = "--profile", .description = "Older name for --global", .hidden = true },
    .{ .flag = "--project", .description = "Use the project's .mcp.json" },
    .{ .flag = "--scope <user|project|local>", .description = "user is --global, project is --project, local keeps the server for this project only" },
};
pub const mcp_add_options = mcp_scope_options ++ [_]command_specs.OptionDoc{
    .{ .flag = "--transport <http|sse|stdio>", .description = "Pick the transport; without it a URL is http and a command after -- is stdio" },
    .{ .flag = "--env <KEY=VALUE>", .description = "Set an environment variable for a command server" },
    .{ .flag = "--header <KEY=VALUE>", .description = "Send a header to an HTTP server" },
    .{ .flag = "--no-login", .description = "Don't sign in to an HTTP server that needs a login" },
};
const mcp_connect_option: command_specs.OptionDoc = .{ .flag = "--connect", .description = "Moved to show NAME", .hidden = true };
pub const mcp_list_options = [_]command_specs.OptionDoc{ json_option, mcp_connect_option };
pub const mcp_list_shell_options = [_]command_specs.OptionDoc{mcp_connect_option};
pub const mcp_show_options = [_]command_specs.OptionDoc{json_option};
pub const mcp_login_options = [_]command_specs.OptionDoc{
    .{ .flag = "--no-browser", .description = "Print the sign-in address instead of opening it" },
};
pub const mcp_approve_options = [_]command_specs.OptionDoc{
    .{ .flag = "--all", .description = "Approve every project server" },
};

const permission_modes = [_][]const u8{ "ask", "auto", "yolo", "dontAsk", "plan" };
const builtin_providers = [_][]const u8{ "gateway", "codex", "grok" };

const ProviderOrder = enum { with_provider_order, without_provider_order };

fn agentRunOptions(comptime scope: []const u8, comptime provider_order: ProviderOrder) [if (provider_order == .with_provider_order) 18 else 15]command_specs.OptionDoc {
    const all = [_]command_specs.OptionDoc{
        .{ .flag = "--permission-mode <mode>", .description = "Set the permission mode for " ++ scope ++ ": ask, auto, yolo, dontAsk, or plan", .values = &permission_modes },
        .{ .flag = "--ask", .description = "Ask before each action that needs permission" },
        .{ .flag = "--auto", .description = "Never ask: run every action that no deny rule blocks" },
        .{ .flag = "--full-access", .description = "Ask only when needed: for dangerous commands, sensitive files, and ask rules" },
        .{ .flag = "--yolo", .description = "Alias for --full-access" },
        .{ .flag = "-y", .description = "Alias for --yolo", .hidden = true },
        .{ .flag = "--yes", .description = "Alias for --yolo", .hidden = true },
        .{ .flag = "--auto-approve", .description = "Alias for --yolo", .hidden = true },
        .{ .flag = "--provider <name>", .description = "Override the model provider for " ++ scope ++ " (gateway, codex, grok, or a configured name)", .values = &builtin_providers },
        .{ .flag = "--model <id>", .description = "Override the model for " ++ scope },
        .{ .flag = "--effort <level>", .description = "Override the reasoning effort for " ++ scope },
        .{ .flag = "--fast", .description = "Enable Fast mode for " ++ scope ++ " when the model supports it" },
        .{ .flag = "--no-fast", .description = "Disable Fast mode for " ++ scope },
        .{ .flag = "--ultrafast", .description = "Request Ultrafast mode for " ++ scope ++ " when the model supports it" },
        .{ .flag = "--no-ultrafast", .description = "Disable Ultrafast mode for " ++ scope },
        .{ .flag = "--provider-order <a,b,...>", .description = "Prefer these gateway providers in order for " ++ scope },
        .{ .flag = "--provider-strict", .description = "Restrict " ++ scope ++ " to only the providers in --provider-order" },
        .{ .flag = "--no-provider-strict", .description = "Clear the provider restriction for " ++ scope },
    };
    return if (provider_order == .with_provider_order) all else all[0..15].*;
}

const agent_run_usage_base = "[--permission-mode <mode>|--ask|--auto|--full-access] [--provider <name>] [--model <id>] [--effort <level>] [--fast|--no-fast] [--ultrafast|--no-ultrafast]";
const agent_run_usage = agent_run_usage_base ++ " [--provider-order <a,b,...>] [--provider-strict|--no-provider-strict]";

pub const ask_options = agentRunOptions("this request", .with_provider_order) ++ [_]command_specs.OptionDoc{
    .{ .flag = "--image PATH", .description = "Attach an image file; repeat for multiple images" },
    .{ .flag = "--system TEXT", .description = "Replace the built-in system prompt for this request" },
    .{ .flag = "--system-prompt TEXT", .description = "Claude Code's name for --system" },
    .{ .flag = "--system-prompt-file PATH", .description = "Replace the built-in system prompt with the contents of a file" },
    .{ .flag = "--append-system-prompt TEXT", .description = "Add text after the system prompt for this request; repeatable" },
    .{ .flag = "--append-system-prompt-file PATH", .description = "Add the contents of a file after the system prompt for this request" },
    json_option,
    .{ .flag = "--output-format <format>", .description = "Print assistant text (text), one JSON result like --json (json), or one JSON line per message (stream-json)", .values = &.{ "text", "json", "stream-json" } },
    .{ .flag = "--quiet", .description = "Suppress assistant output" },
    .{ .flag = "--prompt-permissions", .description = "Prompt for Y/N permission approval when stdin is a TTY" },
    .{ .flag = "--permission-prompts MODE", .description = "none denies anything that would prompt, as --permission-mode dontAsk does; host keeps the default", .values = &.{ "none", "host" } },
    .{ .flag = "--bare", .description = "Skip hooks, skills, plugins, MCP servers and project instructions for this request" },
    .{ .flag = "--allowed-tools <rules>", .description = "Allow these tools without asking, as comma-separated rules such as Read or Bash(npm test); repeatable" },
    .{ .flag = "--allowedTools <rules>", .description = "Alias for --allowed-tools", .hidden = true },
    .{ .flag = "--tools <names>", .description = "Restrict the built-in tools to these comma-separated names; an empty value gives none, and the last value wins" },
    .{ .flag = "--disallowed-tools <names>", .description = "Remove these comma-separated tools from the tools the model sees; repeatable" },
    .{ .flag = "--disallowedTools <names>", .description = "Alias for --disallowed-tools", .hidden = true },
    .{ .flag = "--name <name>", .description = "Name the saved session instead of generating a title; -n is an alias" },
    .{ .flag = "-n <name>", .description = "Alias for --name", .hidden = true },
    .{ .flag = "--plan", .description = "Rejected in prompt mode, which cannot start in plan mode" },
    .{ .flag = "--timeout <seconds>", .description = "Time limit for each shell command the agent runs" },
    .{ .flag = "--config <key=value>", .description = "Override a setting for this request, with the keys fx config set takes; repeatable" },
    .{ .flag = "--settings <file-or-json>", .description = "Override settings for this request from a JSON object, inline or in a file of at most 2 MiB, with the keys --config takes" },
    .{ .flag = "--max-turns <n>", .description = "Cap the agent steps of each turn for this request, like --config max_agent_steps=<n>" },
    .{ .flag = "--dangerously-skip-permissions", .description = "Claude Code's name for --permission-mode bypassPermissions" },
    .{ .flag = "--no-save", .description = "Do not save the session; incompatible with --resume" },
    .{ .flag = "--no-session-persistence", .description = "Alias for --no-save", .hidden = true },
    .{ .flag = "--no-color", .description = "Render TTY output without colors or hyperlinks; NO_COLOR or TERM=dumb also turns color off" },
    .{ .flag = "--resume <last|<id>>", .description = "Continue the last session or a session by id" },
    .{ .flag = "--resume-id <id>", .description = "Continue a session by exact id", .replacement = "use --resume <id>" },
    .{ .flag = "--continue", .description = "Alias for --resume last", .hidden = true },
    .{ .flag = "-c", .description = "Alias for --resume last", .hidden = true },
    .{ .flag = "--", .description = "Treat every following argument as prompt text" },
};

pub const run_code_options = [_]command_specs.OptionDoc{
    .{ .flag = "--file <path>", .description = "Read the body from this file (required)" },
    .{ .flag = "--deadline-ms <n>", .description = "Wall-clock budget for the whole body, including verb calls (default 120000)" },
    .{ .flag = "--format <esm|cjs>", .description = "esm: the body may start with import statements; cjs: a plain function body (default)" },
    .{ .flag = "--permission-mode <mode>", .description = "Approval mode for the verbs the body calls: ask (default), dontAsk or yolo" },
};

pub const top_level_specs = [_]TopLevelSpec{
    .{
        .kind = .help,
        .token = "help",
        .aliases = &.{ "--help", "-h" },
        .usage = "help",
        .summary = "Show this help",
    },
    .{
        .kind = .ask,
        .token = "ask",
        .usage = "ask " ++ agent_run_usage ++ " [--image PATH] [--system TEXT] [--append-system-prompt TEXT] [--json] [--output-format <format>] [--quiet] [--prompt-permissions] [--permission-prompts MODE] [--bare] [--allowed-tools <rules>] [--timeout <seconds>] [--config <key=value>] [--settings <file-or-json>] [--max-turns <n>] [--no-save] [--no-color] [--resume <last|<id>>] [--] <prompt>",
        .summary = "Run one noninteractive request",
        .options = &ask_options,
        .details = &.{
            "The prompt may be passed as arguments or piped on stdin when no prompt args are given.",
            "TTY stdout uses the Minimal transcript presentation; redirected stdout emits raw assistant Markdown.",
            "Operational progress and diagnostics are written to stderr. JSON `output` keeps accumulated assistant Markdown; `final_output` contains only the completed final response, or an empty string when absent.",
            "JSON usage sums reported main-agent input_tokens and output_tokens, including with --no-save; unreported counts are null. cache_read_tokens and cache_write_tokens appear only when the provider reports them. Nested usage and dollar spend are excluded.",
            "--system replaces only the built-in base prompt for this request; tool, skill, project, and runtime context still apply.",
            "--system-prompt and --system-prompt-file do the same from text or a file, and --append-system-prompt and --append-system-prompt-file add to the prompt instead of replacing it.",
            "With --prompt-permissions, JSON and quiet requests may prompt on stderr only when stdin is a TTY.",
            "--output-format stream-json writes one JSON line per message on stdout: a system.version meta line, each assistant message with its tool calls, each tool result, a meta line for each retry, and a session.resume_hint meta line. FX_OUTPUT_FORMAT sets the default when no --output-format, --json or --quiet is given.",
            "fx -p <prompt> and fx --prompt <prompt> run the same request in auto mode; their errors start with error: and exit 1, and a session another fx holds exits 4.",
        },
    },
    .{
        .kind = .run_code,
        .token = "run-code",
        .usage = "run-code --file <path> [--deadline-ms <n>] [--format <esm|cjs>]",
        .summary = "Run a JavaScript body through the embedded txiki runtime",
        .options = &run_code_options,
        .details = &.{
            "The body receives gm (the leaf verbs, one per fx tool), require (relative files), and tjs as undefined.",
            "Prints one JSON line: {ok, value | error, console, console_dropped}. Exits 1 when the body fails.",
            "The same runner serves the run_code tool the model sees.",
        },
    },
    .{
        .kind = .superagent,
        .token = "superagent",
        .usage = "superagent <projects|status|start AGENT|stop AGENT|instruct AGENT PROMPT>",
        .summary = "Run the dispatch layer for independent root fx agents",
        .details = &.{
            "A superagent talks to the user and manages full root fx sessions in project folders.",
            "Managed peers receive each instruction as an ordinary user prompt and keep their own project context, tools, and subagents.",
            "Every managed peer is a root inside this fx process; the superagent starts no external process and reads no other orchestrator's files.",
        },
    },
    .{
        .kind = .acp,
        .token = "acp",
        .usage = acp_usage,
        .summary = "Start an ACP server over stdio",
        .options = &acp_options,
    },
    .{
        .kind = .pr,
        .token = "pr",
        .usage = "pr " ++ agent_run_usage ++ " [--create] [--] [context]",
        .summary = "Draft or publish a pull request",
        .options = &pr_options,
        .details = &.{
            "Must run inside a git repository. Without --create, the drafted PR is printed only.",
        },
    },
    .{
        .kind = .issue,
        .token = "issue",
        .usage = "issue " ++ agent_run_usage ++ " [--create] [--] [context]",
        .summary = "Draft or publish a GitHub issue",
        .options = &issue_options,
    },
    .{
        .kind = .login,
        .token = "login",
        .usage = "login [vercel|codex|grok] [--api-key]",
        .summary = "Sign in to Vercel or a selected provider",
        .subcommands = &login_providers,
        .options = &login_options,
    },
    .{
        .kind = .logout,
        .token = "logout",
        .usage = "logout [vercel|codex|grok]",
        .summary = "Sign out of Vercel or a selected provider session",
        .subcommands = &login_providers,
    },
    .{
        .kind = .setup,
        .token = "setup",
        .hidden_from_top_level_help = true,
        .replaced_by = "fx login vercel --api-key",
        .usage = "setup",
        .summary = "Paste an AI Gateway API key (deprecated: use fx login vercel --api-key)",
    },
    .{
        .kind = .status,
        .token = "status",
        .usage = "status [--json]",
        .summary = "Show configuration and runtime information",
        .options = &.{json_option},
    },
    .{
        .kind = .permissions,
        .token = "permissions",
        .usage = "permissions [--json]",
        .summary = "Show the permission mode and rules",
        .options = &.{json_option},
        .details = &.{
            "Modes:",
            "  ask          Prompt before sensitive tool calls",
            "  auto         Never ask: run every action that no deny rule blocks (default)",
            "  full-access  Ask only when needed: for dangerous commands, sensitive files, and ask rules",
            "  dontAsk      Deny anything that would prompt (set with --permission-mode dontAsk)",
            "",
            "Change the mode from the interactive shell with `/permissions [ask|auto|full-access|reset]`,",
            "and manage persistent allow rules with `/allowlist`.",
        },
    },
    .{
        .kind = .mcp,
        .token = "mcp",
        .usage = "mcp <command> ...",
        .summary = "Manage MCP servers without opening the interactive shell",
        .subcommands = &mcp_subcommands,
    },
    .{
        .kind = .models,
        .token = "models",
        .usage = "models [--json]",
        .summary = "List available models",
        .options = &.{json_option},
    },
    .{
        .kind = .provider,
        .token = "provider",
        .usage = "provider <name>",
        .summary = "Choose the model provider used by fx",
    },
    .{
        .kind = .doctor,
        .token = "doctor",
        .usage = "doctor [--json]",
        .summary = "Run local health and preflight checks",
        .options = &.{json_option},
    },
    .{
        .kind = .teams,
        .token = "teams",
        .usage = "teams",
        .summary = "Choose the Vercel team used by AI Gateway",
    },
    .{
        .kind = .session,
        .token = "session",
        .usage = "session <last|id>|--id <id> [--json] | session resume [last|<id>] | session recover <id>|--id <id> [--json]",
        .summary = "Inspect, resume, or recover saved sessions",
        .subcommands = &session_subcommands,
        .options = &session_options,
    },
    .{
        .kind = .sessions,
        .token = "sessions",
        .usage = "sessions [--all] [--cwd <path>] [--archived] [--limit <1-100>] [--cursor <cursor>] [--json] | sessions convert [--json] | sessions fork [id] [--cwd <path>] [-y] | sessions delete <id> [-y] | sessions purge [--cwd <path>] [--older-than <days>] [-y] | sessions archive <id> | sessions restore <id> | sessions export [id] [-o <path>] [-y] [--no-include-global-log] | sessions import [--days <1-365>]",
        .summary = "List saved sessions for the current workspace, most recently updated first",
        .subcommands = &.{
            .{ .usage = "convert", .description = "Convert every session saved in the previous format", .options = &sessions_convert_options },
            .{ .usage = "fork [id]", .description = "Copy a session into a new session and print the new id", .options = &sessions_fork_options },
            .{ .usage = "delete <id>", .description = "Delete a saved session and its files", .options = &sessions_delete_options },
            .{ .usage = "purge", .description = "Delete every saved session of a working directory and their files, or only those older than a number of days", .options = &sessions_purge_options },
            .{ .usage = "archive <id>", .description = "Hide a saved session from the list and the picker without deleting it" },
            .{ .usage = "restore <id>", .description = "Bring an archived session back into the list and the picker" },
            .{ .usage = "export [id]", .description = "Write a session, its files and the diagnostic log to a debug zip archive and print its path", .options = &sessions_export_options },
            .{ .usage = "import", .description = "Import recent Claude Code and Codex sessions as fx sessions", .options = &sessions_import_options },
        },
        .options = &sessions_options,
    },
    .{
        .kind = .@"resume",
        .token = "resume",
        .aliases = &.{ "--resume", "--continue", "-c", "-r", "-S", "--session" },
        .help_title = "--resume",
        .hidden_from_top_level_help = true,
        .usage = "session resume [last|<id>] | -S, --session [last|<id>] | -r, --resume [last|<id>] | --continue | -c",
        .summary = "Continue a saved interactive session",
        .options = &.{
            .{ .flag = "-S", .description = "Resume a session; with no value, choose a session from a picker" },
            .{ .flag = "-r", .description = "Short for --resume; with no value, choose a session from a picker" },
            .{ .flag = "last", .description = "Resume the most recent session" },
            .{ .flag = "<id>", .description = "Resume a session by id" },
        },
    },
    .{
        .kind = .credits,
        .token = "credits",
        .aliases = &.{"balance"},
        .usage = "credits [--json]",
        .summary = "Show the AI Gateway credit balance",
        .options = &.{json_option},
    },
    .{
        .kind = .usage,
        .token = "usage",
        .usage = "usage [--period <today|7d|month>] [--json]",
        .summary = "Show your provider's usage and spend",
        .options = &usage_options,
        .details = &.{
            "With AI Gateway, reads its usage reports: with fx login, your spend on the team and your budget; with an API key, that key's spend.",
            "With Codex, reads your ChatGPT plan's limits and activity; with Grok, your plan's allowance and credits.",
            "Finished days are cached under ~/.fx and fetched at most once a day.",
        },
    },
    .{
        .kind = .upgrade,
        .token = "upgrade",
        .aliases = &.{"update"},
        .usage = "upgrade [--channel <stable|dev>] [--json]",
        .summary = "Upgrade 𝒇x on the selected release channel",
        .options = &upgrade_options,
    },
    .{
        .kind = .replay,
        .token = "replay",
        .usage = "replay <tape> [--frames] [--json] [--golden <path>] [--frames-dir <path>]",
        .summary = "Replay a recorded terminal session",
        .hidden_from_top_level_help = true,
        .options = &replay_options,
        .details = &.{
            "Developer tool for reproducing terminal rendering bugs from FX_RECORD and FX_DEBUG_RECORD tapes. It is not listed in `fx help`.",
        },
    },
    .{
        .kind = .workspace,
        .token = "workspace",
        .usage = "workspace [list|add PATH|remove PATH|clear] [--json]",
        .summary = "Manage additional workspace directories",
        .subcommands = &workspace_subcommands,
        .options = &workspace_options,
        .details = &.{
            "Additional directories are stored for the current primary workspace.",
        },
    },
    .{
        .kind = .parity,
        .token = "parity",
        .usage = "parity <1-10> --json",
        .summary = "Run one local parity item and print its JSON report",
        .options = &json_only_options,
        .details = &.{
            "Items 1 through 10 map to local parity modules under src/core/parity.",
            "The command never opens a model session or a network connection.",
        },
    },
    .{
        .kind = .git_snapshot,
        .token = "git-snapshot",
        .usage = "git-snapshot --json",
        .summary = "Print the working directory's git state as JSON",
        .options = &json_only_options,
        .details = &.{
            "Reads branch, head, changes, recent commits and diff stats through the safe git runner.",
            "Only read-only git commands run. The command never opens a model session or a network connection.",
        },
    },
    .{
        .kind = .completion,
        .token = "completion",
        .usage = "completion bash|zsh|fish",
        .summary = "Print a shell completion script",
        .subcommands = &.{
            .{ .usage = "bash", .description = "Load it with: eval \"$(fx completion bash)\"" },
            .{ .usage = "zsh", .description = "Load it after compinit with: source <(fx completion zsh)" },
            .{ .usage = "fish", .description = "Load it with: fx completion fish | source" },
        },
        .details = &.{
            "Add the load line to ~/.bashrc, ~/.zshrc, or ~/.config/fish/config.fish to keep it in new shells.",
            "Tab completes commands, flags, setting keys after fx config get, set, and unset, and fixed flag values.",
        },
    },
    .{
        .kind = .config,
        .token = "config",
        .usage = "config [list|get <key>|set <key> <value>|unset <key>|schema [--project]] [--global|--workspace] [--show-origin] [--json]",
        .summary = "Show and change fx settings",
        .subcommands = &config_subcommands,
        .options = &config_options,
        .details = &.{
            "Values come from .fx.json, ~/.fx/settings.json, and this workspace's override in it. When a key repeats, the last line is the one fx uses.",
            "Keys are dotted, such as status_line.context. A flag or an FX_* variable can override a value for one run; fx status shows what a run uses.",
            "set and unset change plain preferences for every workspace, such as fast_mode, effort, theme, and status_line.context. Switches take true or false. Permission, model, provider, and account settings keep their own commands.",
            "schema prints a JSON Schema that editors use to complete and check ~/.fx/settings.json, and --project prints the one for .fx.json. A file whose \"$schema\" names https://fx.sh/schemas/settings.json or https://fx.sh/schemas/fx.json gets the same check.",
        },
    },
    command_specs.slack_install_spec,
};

pub const top_level_help_default_width = command_specs.top_level_help_default_width;
pub const top_level_help_fast_buffer_bytes: usize = 32 * 1024;

pub const top_level_help_groups = [_]TopLevelHelpGroup{
    .{ .entries = &.{
        .{ .kind = .ask, .usage = "ask <prompt>" },
    } },
    .{ .entries = &.{
        .{ .kind = .pr, .usage = "pr [context]" },
        .{ .kind = .issue, .usage = "issue [context]" },
    } },
    .{ .entries = &.{
        .{ .kind = .sessions, .usage = "sessions" },
        .{ .kind = .session, .usage = "session <last|id>" },
        .{ .usage = "session resume [last|id]", .summary = "Resume the latest workspace session or a session by id" },
        .{ .usage = "session recover <id>", .summary = "Copy a recoverable corrupt session" },
    } },
    .{ .entries = &.{
        .{ .kind = .login, .usage = "login [vercel|codex|grok] [--api-key]", .summary = "Sign in to a model provider" },
        .{ .kind = .logout, .usage = "logout [vercel|codex|grok]", .summary = "Sign out of a model provider" },
        .{ .kind = .provider, .usage = "provider <name>", .summary = "Choose the active model provider" },
        .{ .kind = .models, .usage = "models" },
    } },
    .{ .entries = &.{
        .{ .kind = .teams, .usage = "teams", .summary = "Choose a Vercel AI Gateway team" },
        .{ .kind = .credits, .usage = "credits|balance", .summary = "Show Vercel AI Gateway credits" },
    } },
    .{ .entries = &.{
        .{ .kind = .usage, .usage = "usage [--period <today|7d|month>]", .summary = "Show your provider's usage and spend" },
    } },
    .{ .entries = &.{
        .{ .kind = .status, .usage = "status" },
        .{ .kind = .doctor, .usage = "doctor" },
        .{ .kind = .mcp, .usage = "mcp <command> ..." },
        .{ .kind = .slack, .usage = "slack <install|status|refresh>" },
        .{ .kind = .permissions, .usage = "permissions" },
        .{ .kind = .workspace, .usage = "workspace" },
        .{ .kind = .config, .usage = "config" },
        .{ .kind = .parity, .usage = "parity <1-10> --json" },
        .{ .kind = .git_snapshot, .usage = "git-snapshot --json" },
        .{ .kind = .upgrade, .usage = "upgrade|update", .summary = "Upgrade fx on the selected release channel" },
        .{ .kind = .acp, .usage = "acp" },
        .{ .kind = .superagent, .usage = "superagent" },
        .{ .kind = .run_code, .usage = "run-code --file <path>" },
        .{ .kind = .completion, .usage = "completion <shell>" },
        .{ .kind = .help, .usage = "help" },
    } },
};

pub const launch_wide_options = [_]command_specs.OptionDoc{
    .{ .flag = "--context-limit <spec>", .description = "" },
    .{ .flag = "--add-dir <path>", .description = "" },
    .{ .flag = "--no-additional-dirs", .description = "" },
};

pub const launch_options = launch_wide_options ++ [_]command_specs.OptionDoc{
    .{ .flag = "--provider <name>", .description = "", .values = &builtin_providers },
    .{ .flag = "--provider-order <a,b,...>", .description = "" },
    .{ .flag = "--provider-strict", .description = "" },
    .{ .flag = "--no-provider-strict", .description = "" },
    .{ .flag = "--model <id>", .description = "" },
    .{ .flag = "--effort <level>", .description = "" },
    .{ .flag = "--fast", .description = "" },
    .{ .flag = "--no-fast", .description = "" },
    .{ .flag = "--ultrafast", .description = "" },
    .{ .flag = "--no-ultrafast", .description = "" },
    .{ .flag = "--permission-mode <mode>", .description = "", .values = &permission_modes },
    .{ .flag = "--ask", .description = "" },
    .{ .flag = "--auto", .description = "" },
    .{ .flag = "--full-access", .description = "" },
    .{ .flag = "--yolo", .description = "" },
    .{ .flag = "-y", .description = "", .hidden = true },
    .{ .flag = "--yes", .description = "", .hidden = true },
    .{ .flag = "--auto-approve", .description = "", .hidden = true },
    .{ .flag = "--plan", .description = "Start the session in plan mode" },
    .{ .flag = "--profile <name>", .description = "" },
    .{ .flag = "--instances <n>", .description = "" },
    .{ .flag = "--skills-dir <dir>", .description = "" },
};

pub const launch_usage: []const u8 = blk: {
    @setEvalBranchQuota(20_000);
    var out: []const u8 = "usage: fx";
    var i: usize = 0;
    while (i < launch_options.len) : (i += 1) {
        const doc = launch_options[i];
        if (doc.hidden or doc.replacement != null) continue;
        const name = doc.flag[0 .. std.mem.findScalar(u8, doc.flag, ' ') orelse doc.flag.len];
        if (i + 1 < launch_options.len and std.mem.eql(u8, launch_options[i + 1].flag, "--no-" ++ name[2..])) {
            out = out ++ " [" ++ doc.flag ++ "|" ++ launch_options[i + 1].flag ++ "]";
            i += 1;
            continue;
        }
        out = out ++ " [" ++ doc.flag ++ "]";
    }
    break :blk out ++ " <command>\n";
};

pub const top_level_flags = [_]TopLevelFlag{
    .{
        .usage = "--context-limit <spec>",
        .description = "Set name=bytes|off; repeatable",
    },
    .{
        .usage = "--add-dir <path>",
        .description = "Add a workspace directory; repeatable",
    },
    .{
        .usage = "--no-additional-dirs",
        .description = "Ignore saved additional directories",
    },
    .{
        .usage = "--skills-dir <dir>",
        .description = "Load skills from this directory instead of the user and project skill folders; repeatable",
    },
    .{
        .usage = "--plan",
        .description = "Start the session in plan mode",
    },
    .{
        .usage = "--provider <name>",
        .description = "Override the model provider for an interactive session (gateway, codex, grok, or a configured name)",
    },
    .{
        .usage = "--provider-order <a,b,...>",
        .description = "Prefer these gateway providers in order for an interactive session",
    },
    .{
        .usage = "--provider-strict, --no-provider-strict",
        .description = "Restrict an interactive session to the providers in --provider-order, or clear the restriction",
    },
    .{
        .usage = "--model <id>",
        .description = "Override the model for an interactive session",
    },
    .{
        .usage = "--effort <level>",
        .description = "Override the reasoning effort for an interactive session",
    },
    .{
        .usage = "--profile <name>",
        .description = "Run an interactive session in an agent profile from ~/.fx/agents or the repository's .fx/agents",
    },
    .{
        .usage = "--instances <n>",
        .description = "Start n fx instances in one interactive session, each with its own conversation; Down on an empty composer, Ctrl+X, or /agents lists them to switch",
    },
    .{
        .usage = "--fast, --no-fast",
        .description = "Turn Fast mode on or off for an interactive session",
    },
    .{
        .usage = "--ultrafast, --no-ultrafast",
        .description = "Request Ultrafast mode on or off for an interactive session",
    },
    .{
        .usage = "--permission-mode <mode>",
        .description = "Set the permission mode for an interactive session: ask, auto, yolo, dontAsk, or plan (plan starts in plan mode)",
    },
    .{
        .usage = "--ask, --auto, --full-access",
        .description = "Shortcuts for each permission mode; --yolo means --full-access",
    },
    .{
        .usage = "-c, --continue",
        .description = "Resume the remembered workspace session",
    },
    .{
        .usage = "-r, --resume [last|<id>]",
        .description = "Pick a saved session, or resume the latest or an exact ID",
    },
    .{
        .usage = "-h, --help",
        .description = "Display this help and exit",
    },
    .{
        .usage = "-v, --version",
        .description = "Print the fx version and exit",
    },
};

pub const top_level_examples = [_]TopLevelExample{
    .{ .command = "fx", .description = "Start a fresh interactive session" },
    .{ .command = "fx \"Fix the failing login test\"", .description = "Start a session with a first prompt" },
    .{ .command = "fx ask \"Explain the changes in this repository\"", .description = "Run one request and exit" },
    .{ .command = "fx session resume last", .description = "Continue the latest session for this workspace" },
    .{ .command = "fx status --json", .description = "Inspect the current configuration as JSON" },
};

pub const top_level_notes = [_][]const u8{
    "Run `fx <command> --help` for command-specific usage and options.",
    "Run `/help` inside an interactive session for slash commands.",
};

pub const top_level_resources = [_]TopLevelResource{
    .{ .label = "Learn more about fx:", .value = "https://fx.sh/docs", .link = true },
    .{ .label = "Report a problem:", .value = "run `/feedback` inside fx" },
};

pub const top_level_registry = TopLevelRegistry{
    .specs = top_level_specs[0..],
    .description = "Fast, native coding agent for the terminal.",
    .interactive_hint = "fx starts an interactive session by default. Use `fx ask` to run one noninteractive request.",
    .help_groups = top_level_help_groups[0..],
    .flags = top_level_flags[0..],
    .examples = top_level_examples[0..],
    .notes = top_level_notes[0..],
    .resources = top_level_resources[0..],
};

pub fn matchesTopLevel(token: []const u8, kind: TopLevelKind) bool {
    return command_specs.matchesTopLevel(top_level_registry, token, kind);
}

pub fn renderTopLevelHelp(alloc: Allocator, columns: usize, version: []const u8) ![]u8 {
    return command_specs.renderTopLevelHelp(alloc, top_level_registry, columns, version);
}

pub fn renderTopLevelHelpWithStyle(alloc: Allocator, columns: usize, version: []const u8, style: HelpStyle) ![]u8 {
    return command_specs.renderTopLevelHelpWithStyle(alloc, top_level_registry, columns, version, style);
}

pub fn renderTopLevelCommandHelp(alloc: Allocator, kind: TopLevelKind) ![]u8 {
    return command_specs.renderTopLevelCommandHelp(alloc, top_level_registry, kind);
}

pub fn topLevelKindFromToken(token: []const u8) ?TopLevelKind {
    return command_specs.topLevelKindFromToken(top_level_registry, token);
}

pub fn topLevelUsage(kind: TopLevelKind) []const u8 {
    return command_specs.topLevelUsage(top_level_registry, kind);
}

pub const slash_specs = [_]SlashSpec{
    .{ .kind = .help, .command = "/help", .aliases = &.{ "/h", "/?" }, .help_entry = "/help", .completion_description = "show available slash commands", .presentation_category = .general, .show_in_welcome = true },
    .{ .kind = .new_session, .command = "/new", .aliases = &.{"/clear"}, .help_entry = "/new [name] (/clear)", .completion_description = "start a fresh session", .presentation_category = .session, .show_in_welcome = true, .accepts_payload = true },
    .{ .kind = .reset_session, .command = "/reset", .help_entry = "/reset", .completion_description = "reset the current session context", .presentation_category = .session },
    .{ .kind = .resume_session, .command = "/resume", .aliases = &.{ "/sessions", "/continue" }, .help_entry = "/resume [id|name] (/sessions, /continue)", .completion_description = "resume a saved session", .presentation_category = .session, .accepts_payload = true },

    .{ .kind = .launch_instance, .command = "/launch", .help_entry = "/launch [profile]", .completion_description = "start another fx instance on this host", .presentation_category = .session, .has_args = true, .accepts_payload = true },
    .{ .kind = .close_instance, .command = "/close", .help_entry = "/close", .completion_description = "close the fx instance on screen", .presentation_category = .session },
    .{ .kind = .show_agents, .command = "/agents", .help_entry = "/agents", .completion_description = "list the open agents and switch to one", .presentation_category = .session },
    .{ .kind = .rename_session, .command = "/rename", .aliases = &.{"/title"}, .help_entry = "/rename [title] (/title)", .completion_description = "show or set the session title", .presentation_category = .session, .has_args = true, .accepts_payload = true },
    .{ .kind = .fork_session, .command = "/fork", .help_entry = "/fork [copy]", .completion_description = "fork the session before a prompt, or copy it whole without switching", .presentation_category = .session, .has_args = true, .accepts_payload = true },
    .{ .kind = .login, .command = "/login", .help_entry = "/login", .completion_description = "choose the model provider and how it signs in", .presentation_category = .account, .has_args = true },
    .{ .kind = .logout, .command = "/logout", .aliases = &.{"/disconnect"}, .help_entry = "/logout [vercel|codex|grok]", .completion_description = "sign out of a provider session; with several sign-ins and no name, pick one", .presentation_category = .account, .has_args = true, .accepts_payload = true },
    .{ .kind = .provider, .command = "/provider", .aliases = &.{ "/setup", "/providers" }, .show_aliases_in_completion = false, .help_entry = "/provider [refresh]", .completion_description = "choose the model provider and how it signs in, or refresh its model list", .presentation_category = .account, .has_args = true, .accepts_payload = true },
    .{ .kind = .stats, .command = "/stats", .help_entry = "/stats", .completion_description = "show terminal rendering counters", .presentation_category = .account },
    .{ .kind = .usage, .command = "/usage", .aliases = &.{"/cost"}, .help_entry = "/usage (/cost)", .completion_description = "show your provider's usage and spend", .presentation_category = .account },
    .{ .kind = .status, .command = "/status", .help_entry = "/status", .completion_description = "show runtime configuration, session tokens and the session ID", .presentation_category = .general, .show_in_welcome = true },
    .{ .kind = .image, .command = "/image", .aliases = &.{"/img"}, .help_entry = "/image <path> (/img)", .completion_description = "attach an image by path", .presentation_category = .media, .has_args = true, .requires_args = true, .accepts_payload = true },
    .{ .kind = .images, .command = "/images", .help_entry = "/images [clear]", .completion_description = "manage pending image attachments", .presentation_category = .media, .has_args = true, .accepts_payload = true },
    .{ .kind = .model, .command = "/model", .help_entry = "/model <id-or-query>", .completion_description = "choose what model and reasoning effort to use", .presentation_category = .model, .has_args = true, .accepts_payload = true },
    .{ .kind = .effort, .command = "/effort", .aliases = &.{"/thinking"}, .help_entry = "/effort [level]", .completion_description = "choose the reasoning effort for the current model", .presentation_category = .model, .has_args = true, .accepts_payload = true },
    .{ .kind = .permissions, .command = "/permissions", .aliases = &.{ "/permission", "/allowed-tools" }, .show_aliases_in_completion = false, .help_entry = "/permissions [ask|auto|full-access|reset] (/permission opens the mode picker)", .completion_description = "choose what fx is allowed to do", .presentation_category = .security, .show_in_welcome = true, .has_args = true, .accepts_payload = true },
    .{ .kind = .auto_mode, .command = "/auto", .help_entry = "/auto", .completion_description = "choose a permission mode, starting on Never Ask", .presentation_category = .security },
    .{ .kind = .yolo_mode, .command = "/yolo", .aliases = &.{"/yes"}, .show_aliases_in_completion = false, .help_entry = "/yolo", .completion_description = "choose a permission mode, starting on Ask When Needed", .presentation_category = .security },
    .{ .kind = .allowlist, .command = "/allowlist", .help_entry = "/allowlist [view [effective|workspace|global]|[workspace|global] add|remove|reset ...]", .completion_description = "manage trusted commands, tools, and URLs", .presentation_category = .security, .show_in_welcome = true, .has_args = true, .accepts_payload = true },
    .{ .kind = .undo, .command = "/undo", .help_entry = "/undo [count]", .completion_description = "undo the latest tracked file operation, or withdraw the last count prompts", .presentation_category = .session, .has_args = true, .accepts_payload = true },
    .{ .kind = .mcp, .command = "/mcp", .help_entry = "/mcp [list|show|add|remove|login|logout|approve|reject]", .completion_description = "manage MCP servers and their logins", .presentation_category = .extensions, .has_args = true, .accepts_payload = true },
    .{ .kind = .mcp_config, .command = "/mcp-config", .help_entry = "/mcp-config [login NAME|request]", .completion_description = "configure MCP servers and handle MCP OAuth login", .presentation_category = .extensions, .has_args = true, .accepts_payload = true },
    .{ .kind = .skills, .command = "/skills", .help_entry = "/skills [list|add|install|show|create|remove|path] [name|url|path] ($ opens skill search)", .completion_description = "browse and manage skills", .presentation_category = .extensions, .has_args = true, .accepts_payload = true },
    .{ .kind = .plugins, .command = "/plugins", .aliases = &.{"/plugin"}, .show_aliases_in_completion = false, .help_entry = "/plugins [list|reload|enable ID|disable ID|remove ID|mcp enable|disable ID SERVER|option ID KEY VALUE|validate PATH [strict]|dir PATH]", .completion_description = "list, enable, disable, remove, and reload plugins", .presentation_category = .extensions, .has_args = true, .accepts_payload = true },
    .{ .kind = .copy, .command = "/copy", .help_entry = "/copy [N]", .completion_description = "copy the last assistant response, or the N-th latest", .presentation_category = .session, .accepts_payload = true },
    .{ .kind = .feedback, .command = "/feedback", .aliases = &.{ "/bug", "/share" }, .help_entry = "/feedback", .completion_description = "open the fx feedback form", .presentation_category = .product, .show_in_welcome = true },
    .{ .kind = .trace, .command = "/trace", .help_entry = "/trace", .completion_description = "copy a private diagnostic trace", .presentation_category = .product },
    .{ .kind = .compact, .command = "/compact", .help_entry = "/compact [instruction]", .completion_description = "summarize context into a fresh window", .presentation_category = .session, .accepts_payload = true },
    .{ .kind = .export_md, .command = "/export-md", .aliases = &.{"/export"}, .help_entry = "/export-md [path] (/export)", .completion_description = "export this session as Markdown", .presentation_category = .session, .has_args = true, .accepts_payload = true },
    .{ .kind = .settings, .command = "/settings", .aliases = &.{"/config"}, .help_entry = "/settings [key=value ...|--help|startup-scrollback [on|off]] (/config)", .completion_description = "browse and update settings", .presentation_category = .appearance, .has_args = true, .accepts_payload = true },
    .{ .kind = .credits, .command = "/credits", .aliases = &.{"/balance"}, .help_entry = "/credits (/balance)", .completion_description = "show gateway credits balance", .presentation_category = .account, .requires_prompt_credential = true },
    .{ .kind = .paste, .command = "/paste", .help_entry = "/paste", .completion_description = "attach an image from the clipboard when supported", .presentation_category = .media },
    .{ .kind = .fast, .command = "/fast", .help_entry = "/fast [on|off]", .completion_description = "toggle Fast mode when supported", .presentation_category = .model, .has_args = true, .accepts_payload = true },
    .{ .kind = .ultrafast, .command = "/ultrafast", .help_entry = "/ultrafast [on|off|status]", .completion_description = "request Ultrafast mode when supported", .presentation_category = .model, .has_args = true, .accepts_payload = true },
    .{ .kind = .statusline, .command = "/statusline", .help_entry = "/statusline [context|session|workspace]", .completion_description = "toggle status line segments", .presentation_category = .appearance, .has_args = true, .accepts_payload = true },
    .{ .kind = .notifications, .command = "/sound", .help_entry = "/sound [on|off|max]", .completion_description = "toggle sounds and terminal bells", .presentation_category = .appearance, .has_args = true, .accepts_payload = true },
    .{ .kind = .workspace, .command = "/add-dir", .aliases = &.{"/workspace"}, .help_entry = "/add-dir [list|PATH|remove PATH|clear] (/workspace)", .completion_description = "manage additional workspace directories", .presentation_category = .workspace, .show_in_welcome = true, .has_args = true, .accepts_payload = true },
    .{ .kind = .shell, .command = "/shell", .help_entry = "/shell reload", .completion_description = "reload shell startup files for commands", .presentation_category = .workspace, .has_args = true, .requires_args = true, .accepts_payload = true },
    .{ .kind = .version, .command = "/version", .help_entry = "/version", .completion_description = "show the fx version", .presentation_category = .general },
    .{ .kind = .parity, .command = "/parity", .help_entry = "/parity <1-10> --json", .completion_description = "run one local parity item and print its JSON report", .presentation_category = .workspace, .has_args = true, .requires_args = true, .accepts_payload = true },
    .{ .kind = .tower, .command = "/tower", .help_entry = "/tower [status|teardown|on|off|BASE-BRANCH]", .completion_description = "report experimental Tower status, turn Tower mode on or off, tear it down, or turn it on with a base branch", .presentation_category = .workspace, .has_args = true, .accepts_payload = true },
    .{ .kind = .export_debug_zip, .command = "/export-debug-zip", .help_entry = "/export-debug-zip", .completion_description = "write this session and its logs to a debug zip archive", .presentation_category = .session },
    .{ .kind = .import_sessions, .command = "/import-sessions", .help_entry = "/import-sessions", .completion_description = "import recent Claude Code and Codex sessions", .presentation_category = .session },
    .{ .kind = .tasks, .command = "/tasks", .aliases = &.{ "/task", "/bashes" }, .help_entry = "/tasks [id] (/task, /bashes)", .completion_description = "list background tasks and their state, or show one task", .presentation_category = .session, .has_args = true, .accepts_payload = true },
    .{ .kind = .experiments, .command = "/experiments", .aliases = &.{"/experimental"}, .help_entry = "/experiments [flag on|off] (/experimental)", .completion_description = "pick an experimental feature flag to toggle, or turn one on or off by name", .presentation_category = .workspace, .has_args = true, .accepts_payload = true },
    .{ .kind = .theme, .command = "/theme", .help_entry = "/theme [name]", .completion_description = "show or set the terminal theme", .presentation_category = .appearance, .has_args = true, .accepts_payload = true },
    .{ .kind = .plan, .command = "/plan", .help_entry = "/plan [on|off|clear|description]", .completion_description = "toggle plan mode, set it with on, off or clear, or start it with a request", .presentation_category = .session, .has_args = true, .accepts_payload = true },
    .{ .kind = .rewind, .command = "/rewind", .aliases = &.{"/checkpoint"}, .help_entry = "/rewind [code|conversation] (/checkpoint)", .completion_description = "go back to before an earlier prompt: restore tracked file edits, the conversation, or both", .presentation_category = .session, .has_args = true, .accepts_payload = true },
    .{ .kind = .init, .command = "/init", .help_entry = "/init [focus]", .completion_description = "create or update this project's AGENTS.md", .presentation_category = .workspace, .accepts_payload = true },
    .{ .kind = .diff, .command = "/diff", .help_entry = "/diff", .completion_description = "show the uncommitted changes in the working tree", .presentation_category = .workspace },
    .{ .kind = .memory, .command = "/memory", .help_entry = "/memory", .completion_description = "list the instruction files fx loads for this workspace", .presentation_category = .workspace },
    .{ .kind = .hooks, .command = "/hooks", .help_entry = "/hooks", .completion_description = "list the configured hooks", .presentation_category = .extensions },
    .{ .kind = .doctor, .command = "/doctor", .aliases = &.{"/checkup"}, .help_entry = "/doctor (/checkup)", .completion_description = "run local health and preflight checks", .presentation_category = .product },
    .{ .kind = .loop, .command = "/loop", .aliases = &.{"/proactive"}, .help_entry = "/loop [interval] <prompt> (/proactive)", .completion_description = "run a prompt on a recurring interval while fx stays open", .presentation_category = .session, .has_args = true, .requires_args = true, .accepts_payload = true },
    .{ .kind = .branch, .command = "/branch", .help_entry = "/branch [name]", .completion_description = "copy this conversation into a new session and switch to it", .presentation_category = .session, .has_args = true, .accepts_payload = true },
    .{ .kind = .context, .command = "/context", .help_entry = "/context", .completion_description = "show how full the context window is, as a grid with a suggestion", .presentation_category = .session },
    .{ .kind = .autocompact, .command = "/autocompact", .help_entry = "/autocompact [percent]", .completion_description = "show or set how full the context gets before automatic compaction", .presentation_category = .session, .has_args = true, .accepts_payload = true },
    .{ .kind = .keybindings, .command = "/keybindings", .help_entry = "/keybindings", .completion_description = "create ~/.fx/keybindings.json if it is missing, apply it, and report its problems", .presentation_category = .appearance },
    .{ .kind = .output_style, .command = "/output-style", .help_entry = "/output-style [name]", .completion_description = "list the output styles or switch this session to one", .presentation_category = .appearance, .has_args = true, .accepts_payload = true },
    .{ .kind = .secondary_model, .command = "/secondary-model", .aliases = &.{"/subagent-model"}, .help_entry = "/secondary-model [MODEL|off] (/subagent-model)", .completion_description = "show or set the model new subagents use by default", .presentation_category = .model, .has_args = true, .accepts_payload = true },
    .{ .kind = .editor, .command = "/editor", .help_entry = "/editor [command]", .completion_description = "write the next message in an external editor, or name the editor to use", .presentation_category = .appearance, .has_args = true, .accepts_payload = true },
    .{ .kind = .reload, .command = "/reload", .help_entry = "/reload", .completion_description = "read settings again and apply UI preferences, the tower flag, the secondary model and skills", .presentation_category = .workspace },
    .{ .kind = .reload_tui, .command = "/reload-tui", .help_entry = "/reload-tui", .completion_description = "read settings again and apply only the UI preferences", .presentation_category = .appearance },
    .{ .kind = .side_question, .command = "/btw", .help_entry = "/btw <question>", .completion_description = "ask a side question about this session without adding it to the conversation", .presentation_category = .session, .has_args = true, .requires_args = true, .accepts_payload = true },
    .{ .kind = .swarm, .command = "/swarm", .help_entry = "/swarm [on|off|TASK]", .completion_description = "toggle swarm mode, or run one task in swarm mode", .presentation_category = .session, .has_args = true, .accepts_payload = true },
    .{ .kind = .quit, .command = "/exit", .aliases = &.{ "/quit", "/q" }, .help_entry = "/exit", .completion_description = "exit the interactive shell", .presentation_category = .general, .show_in_welcome = true },
};

pub const slash_registry = SlashRegistry{ .commands = slash_specs[0..] };

pub fn matchesSlashExact(cmd: []const u8, kind: SlashKind) bool {
    return command_specs.matchesSlashExact(slash_registry, cmd, kind);
}

pub fn isExactSlashCommand(cmd: []const u8) bool {
    return slash_registry.matchExact(cmd) != null;
}

pub fn matchedSlashPrefix(cmd: []const u8, kind: SlashKind) ?[]const u8 {
    return command_specs.matchedSlashPrefix(slash_registry, cmd, kind);
}

pub fn renderSlashHelp(alloc: Allocator) ![]u8 {
    return command_specs.renderSlashHelp(alloc, slash_registry);
}

pub fn firstSlashCompletion(prefix: []const u8) ?[]const u8 {
    return command_specs.firstSlashCompletion(slash_registry, prefix);
}

pub fn slashCompletionCount(prefix: []const u8) usize {
    return command_specs.slashCompletionCount(slash_registry, prefix);
}

pub fn nthSlashCompletion(prefix: []const u8, n: usize) ?[]const u8 {
    return command_specs.nthSlashCompletion(slash_registry, prefix, n);
}

pub fn nthSlashCompletionLabel(prefix: []const u8, n: usize) ?[]const u8 {
    return command_specs.nthSlashCompletionLabel(slash_registry, prefix, n);
}

pub fn nthSlashCompletionDescription(prefix: []const u8, n: usize) ?[]const u8 {
    return command_specs.nthSlashCompletionDescription(slash_registry, prefix, n);
}

pub fn nthSlashCompletionCategory(prefix: []const u8, n: usize) ?SlashPresentationCategory {
    return command_specs.nthSlashCompletionCategory(slash_registry, prefix, n);
}

pub fn slashCompletionHasArgs(command: []const u8) bool {
    return command_specs.slashCompletionHasArgs(slash_registry, command);
}

pub const argCompletionAnchor = command_specs.argCompletionAnchor;

test "fx config help names settings by their current keys" {
    const settings_keys = @import("../core/config/settings_keys.zig");
    const spec = for (top_level_specs) |spec| {
        if (spec.kind == .config) break spec;
    } else unreachable;
    var checked: usize = 0;
    for (spec.details) |line| {
        var words = std.mem.tokenizeAny(u8, line, " ,;:()");
        while (words.next()) |raw| {
            const word = std.mem.trimEnd(u8, raw, ".");
            const dot = std.mem.findScalar(u8, word, '.') orelse continue;
            const key = settings_keys.find(word[0..dot]) orelse continue;
            try std.testing.expectEqualStrings(settings_keys.currentPath(word), word);
            var known = false;
            for (key.children) |child| known = known or std.mem.eql(u8, child, word[dot + 1 ..]);
            try std.testing.expect(known);
            checked += 1;
        }
    }
    try std.testing.expect(checked > 0);
}

test "built-in slash commands register exact active order" {
    const expected_commands = [_][]const u8{
        "/help",
        "/new",
        "/reset",
        "/resume",
        "/launch",
        "/close",
        "/agents",
        "/rename",
        "/fork",
        "/login",
        "/logout",
        "/provider",
        "/stats",
        "/usage",
        "/status",
        "/image",
        "/images",
        "/model",
        "/effort",
        "/permissions",
        "/auto",
        "/yolo",
        "/allowlist",
        "/undo",
        "/mcp",
        "/mcp-config",
        "/skills",
        "/plugins",
        "/copy",
        "/feedback",
        "/trace",
        "/compact",
        "/export-md",
        "/settings",
        "/credits",
        "/paste",
        "/fast",
        "/ultrafast",
        "/statusline",
        "/sound",
        "/add-dir",
        "/shell",
        "/version",
        "/parity",
        "/tower",
        "/export-debug-zip",
        "/import-sessions",
        "/tasks",
        "/experiments",
        "/theme",
        "/plan",
        "/rewind",
        "/init",
        "/diff",
        "/memory",
        "/hooks",
        "/doctor",
        "/loop",
        "/branch",
        "/context",
        "/autocompact",
        "/keybindings",
        "/output-style",
        "/secondary-model",
        "/editor",
        "/reload",
        "/reload-tui",
        "/btw",
        "/swarm",
        "/exit",
    };

    try std.testing.expectEqual(expected_commands.len, slash_specs.len);
    for (expected_commands, slash_specs) |expected, spec| {
        try std.testing.expectEqualStrings(expected, spec.command);
    }
}

test "built-in slash registry resolves primary commands and aliases" {
    const image = slash_registry.lookup("/img") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(SlashKind.image, image.kind);

    const usage = slash_registry.lookup("/usage") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(SlashKind.usage, usage.kind);

    const quit = slash_registry.matchExact("/exit\t") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(SlashKind.quit, quit.command.kind);
    try std.testing.expectEqualStrings("/exit", quit.token);

    const model = command_specs.matchedSlashPrefix(slash_registry, "/model\tmodel-id", .model) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("/model", model);

    const credits = slash_registry.lookup("/credits") orelse return error.TestExpectedEqual;
    try std.testing.expect(credits.requires_prompt_credential);

    const model_command = slash_registry.lookup("/model") orelse return error.TestExpectedEqual;
    try std.testing.expect(!model_command.requires_prompt_credential);
    try std.testing.expect(slash_registry.lookup("/models") == null);

    try std.testing.expect(command_specs.matchedSlashPrefix(slash_registry, "/model\nmodel-id", .model) == null);

    const clear = slash_registry.lookup("/clear") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(SlashKind.new_session, clear.kind);
    const sessions = slash_registry.lookup("/sessions") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(SlashKind.resume_session, sessions.kind);
    const title = slash_registry.lookup("/title") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(SlashKind.rename_session, title.kind);
    const export_alias = slash_registry.lookup("/export") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(SlashKind.export_md, export_alias.kind);
}

test "/add-dir is the canonical workspace command and /workspace stays an alias" {
    const canonical = slash_registry.lookup("/add-dir") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(SlashKind.workspace, canonical.kind);
    try std.testing.expectEqualStrings("/add-dir", canonical.command);
    const alias = slash_registry.lookup("/workspace") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(SlashKind.workspace, alias.kind);
    try std.testing.expectEqualStrings("/add-dir", alias.command);
}

test "/plugins is registered as a payload command and /permission aliases /permissions" {
    const plugins = slash_registry.lookup("/plugins") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(SlashKind.plugins, plugins.kind);
    try std.testing.expect(plugins.accepts_payload);
    const permission = slash_registry.lookup("/permission") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(SlashKind.permissions, permission.kind);
    try std.testing.expectEqualStrings("/permissions", permission.command);
}

test "/mcp-config is its own payload command beside /mcp" {
    const mcp_config = slash_registry.lookup("/mcp-config") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(SlashKind.mcp_config, mcp_config.kind);
    try std.testing.expect(mcp_config.accepts_payload);
    try std.testing.expect(!mcp_config.requires_args);
    try std.testing.expectEqualStrings("/mcp-config", command_specs.matchedSlashPrefix(slash_registry, "/mcp-config login linear", .mcp_config).?);
    try std.testing.expect(command_specs.matchedSlashPrefix(slash_registry, "/mcp-config login linear", .mcp) == null);
    try std.testing.expectEqual(SlashKind.mcp, (slash_registry.lookup("/mcp") orelse return error.TestExpectedEqual).kind);
}

test "retired appearance slash commands are not registered" {
    try std.testing.expect(!isExactSlashCommand("/appearance"));
    try std.testing.expect(!isExactSlashCommand("/input"));
    try std.testing.expect(!isExactSlashCommand("/maxxing\t"));
    try std.testing.expect(!isExactSlashCommand("/input lines"));
    try std.testing.expect(!isExactSlashCommand("/unknown"));
}

test "built-in paste completion describes clipboard image attachment" {
    const completion = nthSlashCompletion("/pas", 0) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("/paste", completion);

    const description = nthSlashCompletionDescription("/pas", 0) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("attach an image from the clipboard when supported", description);
}

test "built-in statusline help and completion include workspace" {
    const help = try renderSlashHelp(std.testing.allocator);
    defer std.testing.allocator.free(help);
    try std.testing.expect(
        std.mem.find(u8, help, "/statusline [context|session|workspace]") != null,
    );

    try std.testing.expectEqualStrings(
        "/statusline workspace",
        nthSlashCompletion("/statusline w", 0).?,
    );
}

test "every launch flag appears in fx --help" {
    const cli_flags = @import("../core/cli/cli_flags.zig");
    outer: for (launch_options) |doc| {
        const name = cli_flags.flagName(doc);
        if (doc.hidden or std.mem.eql(u8, name, "--yolo")) continue;
        for (top_level_flags) |flag| {
            var parts = std.mem.splitSequence(u8, flag.usage, ", ");
            while (parts.next()) |part| {
                const end = std.mem.findScalar(u8, part, ' ') orelse part.len;
                if (std.mem.eql(u8, part[0..end], name)) continue :outer;
            }
        }
        std.debug.print("{s} is parsed but missing from top_level_flags\n", .{name});
        return error.TestExpectedEqual;
    }
    for (top_level_flags) |flag| {
        var parts = std.mem.splitSequence(u8, flag.usage, ", ");
        part: while (parts.next()) |part| {
            const name = part[0 .. std.mem.findScalar(u8, part, ' ') orelse part.len];
            for ([_][]const u8{ "-c", "--continue", "-r", "--resume", "-h", "--help", "-v", "--version" }) |early| {
                if (std.mem.eql(u8, name, early)) continue :part;
            }
            for (launch_options) |doc| {
                if (std.mem.eql(u8, cli_flags.flagName(doc), name)) continue :part;
            }
            std.debug.print("{s} is in top_level_flags but the launch parser doesn't read it\n", .{name});
            return error.TestExpectedEqual;
        }
    }
}

test "the launch usage line pairs each --no- spelling with its flag" {
    try std.testing.expect(std.mem.startsWith(u8, launch_usage, "usage: fx [--context-limit <spec>] [--add-dir <path>] [--no-additional-dirs] "));
    try std.testing.expect(std.mem.find(u8, launch_usage, " [--fast|--no-fast] ") != null);
    try std.testing.expect(std.mem.endsWith(u8, launch_usage, " <command>\n"));
}

test "Kimi slash aliases resolve to their fx commands" {
    const expected = [_]struct { alias: []const u8, kind: SlashKind }{
        .{ .alias = "/h", .kind = .help },
        .{ .alias = "/?", .kind = .help },
        .{ .alias = "/config", .kind = .settings },
        .{ .alias = "/thinking", .kind = .effort },
        .{ .alias = "/providers", .kind = .provider },
        .{ .alias = "/bug", .kind = .feedback },
        .{ .alias = "/disconnect", .kind = .logout },
        .{ .alias = "/quit", .kind = .quit },
        .{ .alias = "/q", .kind = .quit },
        .{ .alias = "/add-dir", .kind = .workspace },
    };
    for (expected) |want| {
        const spec = slash_registry.lookup(want.alias) orelse return error.TestExpectedEqual;
        try std.testing.expectEqual(want.kind, spec.kind);
    }
    const exit = slash_registry.lookup("/exit") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(SlashKind.quit, exit.kind);
    try std.testing.expectEqualStrings("/exit", exit.command);
}

test "Claude Code slash spellings resolve to their fx commands" {
    const expected = [_]struct { alias: []const u8, kind: SlashKind }{
        .{ .alias = "/cost", .kind = .usage },
        .{ .alias = "/continue", .kind = .resume_session },
        .{ .alias = "/allowed-tools", .kind = .permissions },
        .{ .alias = "/plugin", .kind = .plugins },
        .{ .alias = "/share", .kind = .feedback },
        .{ .alias = "/bashes", .kind = .tasks },
        .{ .alias = "/checkpoint", .kind = .rewind },
        .{ .alias = "/rewind", .kind = .rewind },
        .{ .alias = "/checkup", .kind = .doctor },
        .{ .alias = "/proactive", .kind = .loop },
        .{ .alias = "/init", .kind = .init },
        .{ .alias = "/diff", .kind = .diff },
        .{ .alias = "/memory", .kind = .memory },
        .{ .alias = "/hooks", .kind = .hooks },
        .{ .alias = "/branch", .kind = .branch },
    };
    for (expected) |want| {
        const spec = slash_registry.lookup(want.alias) orelse return error.TestExpectedEqual;
        try std.testing.expectEqual(want.kind, spec.kind);
    }
    try std.testing.expectEqualStrings("/resume", command_specs.matchedSlashPrefix(slash_registry, "/resume fix the uploader", .resume_session).?);
    try std.testing.expectEqualStrings("/continue", command_specs.matchedSlashPrefix(slash_registry, "/continue 01JABC", .resume_session).?);
    try std.testing.expectEqualStrings("/copy", command_specs.matchedSlashPrefix(slash_registry, "/copy 2", .copy).?);
    try std.testing.expectEqualStrings("/plugin", command_specs.matchedSlashPrefix(slash_registry, "/plugin list", .plugins).?);
    try std.testing.expect(!(slash_registry.lookup("/resume") orelse return error.TestExpectedEqual).has_args);
}

test "/auto is a registered command that opens the permission picker on Never Ask" {
    try std.testing.expect(matchesSlashExact("/auto", .auto_mode));
    try std.testing.expect(isExactSlashCommand("/auto"));
    try std.testing.expect(!matchesSlashExact("/auto", .permissions));
}

test "/yolo and its Kimi alias /yes are registered and open the permission picker on Ask When Needed" {
    try std.testing.expect(matchesSlashExact("/yolo", .yolo_mode));
    try std.testing.expect(isExactSlashCommand("/yolo"));
    const alias = slash_registry.lookup("/yes") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(SlashKind.yolo_mode, alias.kind);
    try std.testing.expectEqualStrings("/yolo", alias.command);
}

test "/swarm takes an optional mode word or task" {
    const swarm = slash_registry.lookup("/swarm") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(SlashKind.swarm, swarm.kind);
    try std.testing.expect(swarm.accepts_payload);
    try std.testing.expect(!swarm.requires_args);
}

pub const parity_command_name = "parity";
