const std = @import("std");
const builtin = @import("builtin");
const host_target = @import("../../core/hosts/target.zig");
const io_mod = @import("../../core/shared/io.zig");
const result_schema = @import("../../core/subagent/result_schema.zig");

const Allocator = std.mem.Allocator;

pub const default_max_running: usize = 8;
pub const max_max_running: usize = 16;
pub const default_max_results: usize = 200;
pub const max_max_results: usize = 1000;
pub const default_checkers: usize = 3;
pub const min_checkers: usize = 2;
pub const max_checkers: usize = 5;
pub const default_until_dry_rounds: usize = 5;
pub const max_until_dry_rounds: usize = 10;
pub const max_dropped_keys: usize = 50;
pub const max_seen_text_bytes: usize = 2000;
pub const max_result_text_bytes: usize = 4000;
pub const max_critic_summary_bytes: usize = 8000;
pub const refutations_to_kill: usize = 2;
pub const votes_to_verify: usize = 2;
pub const dry_rounds_to_stop: usize = 2;

pub const item_placeholder = "item";
pub const previous_placeholder = "previous";
pub const seen_placeholder = "seen";
pub const finding_placeholder = "finding";
pub const lens_placeholder = "lens";
pub const summary_placeholder = "summary";

const vote_schema_json =
    \\{"type":"object","required":["refuted"],"properties":{"refuted":{"type":"boolean"},"reason":{"type":"string"}}}
;

const default_checker_template =
    "Try to refute this finding. Check it yourself against the source and do not assume it is right. " ++
    "Say it is refuted only when you found evidence against it.\n\nFinding:\n{{finding}}";

const lens_line = "\n\nJudge it through this lens: {{lens}}.";

const default_critic_template =
    "You are the completeness critic for a fan-out over several subagents. Below is the merged result. " ++
    "Name what is missing: units that were not covered, checks that were not run, sources that were not read, " ++
    "and claims that carry no evidence. Be specific and brief.\n\n{{summary}}";

pub const Stage = struct {
    name: []const u8,
    prompt_template: []const u8,
};

pub const Verify = struct {
    checkers: usize = default_checkers,
    lenses: []const []const u8 = &.{},
    prompt_template: ?[]const u8 = null,
};

pub const Resume = struct {
    agent: []const u8,
    prompt: []const u8,
};

pub const Config = struct {
    call_id: []const u8 = "swarm",
    items: []const []const u8 = &.{},
    stages: []const Stage = &.{},
    resumed: []const Resume = &.{},
    profile: ?[]const u8 = null,
    model: ?[]const u8 = null,
    schema: ?std.json.Value = null,
    dedup_key: ?[]const u8 = null,
    max_results: usize = default_max_results,
    max_running: usize = default_max_running,
    verify: ?Verify = null,
    until_dry_max_rounds: ?usize = null,
    critic: bool = false,
};

pub const ChildOutcome = enum { completed, failed, cancelled, transport_error };

pub const ChildRequest = struct {
    agent: []const u8,
    prompt: []const u8,
    profile: ?[]const u8 = null,
    model: ?[]const u8 = null,
    invocation_id: []const u8,
    continues: bool = false,
};

pub const ChildResult = struct {
    outcome: ChildOutcome,
    text: []const u8,
    turn_cancelled: bool = false,
};

pub const Runner = struct {
    context: *anyopaque,
    run_fn: *const fn (*anyopaque, Allocator, ChildRequest) Allocator.Error!ChildResult,

    pub fn run(self: Runner, arena: Allocator, request: ChildRequest) Allocator.Error!ChildResult {
        return self.run_fn(self.context, arena, request);
    }
};

const JobKind = enum { unit, checker, critic };
const JobStatus = enum { queued, completed, invalid, failed, cancelled };

const Job = struct {
    arena_state: std.heap.ArenaAllocator,
    kind: JobKind,
    index: usize,
    round: usize = 1,
    item: []const u8 = "",
    resume_agent: ?[]const u8 = null,
    prompt: []const u8 = "",
    seen_text: []const u8 = "",
    finding_index: usize = 0,
    checker_index: usize = 0,
    waited: bool = false,
    status: JobStatus = .queued,
    agent: []const u8 = "",
    text: []const u8 = "",
    structured: ?std.json.Value = null,
    invalid_error: []const u8 = "",
    restarted: bool = false,
    failed_stage: ?usize = null,
};

const Verdict = enum { confirmed, unverified, killed };

const Finding = struct {
    value: std.json.Value,
    key: ?[]const u8,
    unit: usize,
    round: usize,
    verdict: ?Verdict = null,
    refuted: usize = 0,
    upheld: usize = 0,
    no_vote: usize = 0,
    reasons: std.ArrayList([]const u8) = .empty,
};

const Dropped = struct {
    duplicates: usize = 0,
    over_cap: usize = 0,
    keys: std.ArrayList([]const u8) = .empty,
    keys_omitted: usize = 0,
};

const Binding = struct {
    name: []const u8,
    value: []const u8,
};

const ChildRun = struct {
    result: ChildResult,
    agent: []const u8,
    restarted: bool,
};

const StructuredRun = struct {
    child: ChildRun,
    checked: ?result_schema.Checked,
};

const PoolState = struct {
    engine: *Engine,
    jobs: []Job,
    next: std.atomic.Value(usize) = .init(0),
};

pub const Engine = struct {
    work_alloc: Allocator,
    main_state: std.heap.ArenaAllocator,
    config: Config,
    runner: Runner,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    name_prefix: [9]u8,
    started: std.atomic.Value(usize) = .init(0),
    errored: std.atomic.Value(usize) = .init(0),
    restarted: std.atomic.Value(usize) = .init(0),
    repaired: std.atomic.Value(usize) = .init(0),
    invalid: std.atomic.Value(usize) = .init(0),
    turn_cancelled: std.atomic.Value(bool) = .init(false),
    queued_peak: usize = 0,
    rounds: usize = 0,
    verified: bool = false,
    job_sets: std.ArrayList([]Job) = .empty,
    findings: std.ArrayList(Finding) = .empty,
    seen_order: std.ArrayList([]const u8) = .empty,
    dropped: Dropped = .{},
    critic_text: ?[]const u8 = null,

    pub fn init(
        work_alloc: Allocator,
        config: Config,
        runner: Runner,
        cancel_flag: ?*std.atomic.Value(bool),
    ) Engine {
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(config.call_id, &digest, .{});
        const hex = std.fmt.bytesToHex(digest[0..4].*, .lower);
        var prefix: [9]u8 = undefined;
        prefix[0] = 's';
        @memcpy(prefix[1..], &hex);
        return .{
            .work_alloc = work_alloc,
            .main_state = std.heap.ArenaAllocator.init(work_alloc),
            .config = config,
            .runner = runner,
            .cancel_flag = cancel_flag,
            .name_prefix = prefix,
        };
    }

    pub fn deinit(self: *Engine) void {
        for (self.job_sets.items) |jobs| {
            for (jobs) |*job| job.arena_state.deinit();
        }
        self.main_state.deinit();
        self.* = undefined;
    }

    pub fn effectiveCap(self: *const Engine, job_count: usize) usize {
        if (comptime (builtin.single_threaded or host_target.is_wasm)) return 1;
        return @max(1, @min(self.config.max_running, job_count));
    }

    pub fn anyUnitCompleted(self: *const Engine) bool {
        for (self.job_sets.items) |jobs| {
            for (jobs) |job| {
                if (job.kind == .unit and job.status == .completed) return true;
            }
        }
        return false;
    }

    pub fn run(self: *Engine) Allocator.Error!void {
        const main = self.main_state.allocator();
        var seen = std.StringHashMap(void).init(main);
        var round: usize = 1;
        var dry_rounds: usize = 0;
        while (true) : (round += 1) {
            self.rounds = round;
            const jobs = try self.newUnitJobs(main, round);
            self.runPool(jobs);
            const added = try self.merge(main, jobs, &seen);
            const max_rounds = self.config.until_dry_max_rounds orelse break;
            dry_rounds = if (added == 0) dry_rounds + 1 else 0;
            if (dry_rounds >= dry_rounds_to_stop or round >= max_rounds or self.cancelled()) break;
        }
        if (self.config.verify) |verify| {
            if (!self.cancelled() and self.findings.items.len > 0) try self.runVerify(main, verify);
        }
        if (self.config.critic and !self.cancelled()) try self.runCritic(main);
    }

    fn cancelled(self: *const Engine) bool {
        if (self.turn_cancelled.load(.seq_cst)) return true;
        return if (self.cancel_flag) |flag| flag.load(.seq_cst) else false;
    }

    fn newJobs(self: *Engine, main: Allocator, kind: JobKind, count: usize) Allocator.Error![]Job {
        try self.job_sets.ensureUnusedCapacity(main, 1);
        const jobs = try main.alloc(Job, count);
        for (jobs, 0..) |*job, index| {
            job.* = .{
                .arena_state = std.heap.ArenaAllocator.init(self.work_alloc),
                .kind = kind,
                .index = index,
            };
        }
        self.job_sets.appendAssumeCapacity(jobs);
        return jobs;
    }

    fn newUnitJobs(self: *Engine, main: Allocator, round: usize) Allocator.Error![]Job {
        const resume_count = if (round == 1) self.config.resumed.len else 0;
        const jobs = try self.newJobs(main, .unit, self.config.items.len + resume_count);
        const seen_text = if (round > 1) try self.seenText(main) else "";
        for (self.config.items, 0..) |item, index| {
            jobs[index].round = round;
            jobs[index].item = item;
            jobs[index].seen_text = seen_text;
        }
        for (0..resume_count) |offset| {
            const job = &jobs[self.config.items.len + offset];
            const entry = self.config.resumed[offset];
            job.round = round;
            job.item = entry.agent;
            job.resume_agent = entry.agent;
            job.prompt = entry.prompt;
        }
        return jobs;
    }

    fn seenText(self: *Engine, main: Allocator) Allocator.Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(main);
        var listed: usize = 0;
        for (self.seen_order.items) |key| {
            if (out.written().len + key.len + 2 > max_seen_text_bytes) break;
            if (listed > 0) try writeText(&out.writer, ", ");
            try writeText(&out.writer, key);
            listed += 1;
        }
        if (listed < self.seen_order.items.len) {
            out.writer.print(" (+{d} more)", .{self.seen_order.items.len - listed}) catch return error.OutOfMemory;
        }
        return out.written();
    }

    fn runPool(self: *Engine, jobs: []Job) void {
        if (jobs.len == 0) return;
        const cap = self.effectiveCap(jobs.len);
        for (jobs, 0..) |*job, index| job.waited = index >= cap;
        self.queued_peak = @max(self.queued_peak, jobs.len - cap);
        var state = PoolState{ .engine = self, .jobs = jobs };
        if (comptime (builtin.single_threaded or host_target.is_wasm)) {
            poolWorker(&state);
        } else {
            if (cap == 1) {
                poolWorker(&state);
                return;
            }
            var threads: [max_max_running]std.Thread = undefined;
            var spawned: usize = 0;
            while (spawned < cap) : (spawned += 1) {
                threads[spawned] = std.Thread.spawn(.{}, poolWorker, .{&state}) catch break;
            }
            if (spawned == 0) poolWorker(&state);
            for (threads[0..spawned]) |thread| thread.join();
        }
    }

    fn poolWorker(state: *PoolState) void {
        while (true) {
            const index = state.next.fetchAdd(1, .seq_cst);
            if (index >= state.jobs.len) return;
            state.engine.runJob(&state.jobs[index]);
        }
    }

    fn runJob(self: *Engine, job: *Job) void {
        if (self.cancelled()) {
            job.status = .cancelled;
            return;
        }
        const outcome = switch (job.kind) {
            .unit => self.runUnit(job),
            .checker => self.runChecker(job),
            .critic => self.runCriticJob(job),
        };
        outcome catch {
            job.status = .failed;
            job.text = "out of memory";
        };
    }

    fn runChild(
        self: *Engine,
        arena: Allocator,
        tag: []const u8,
        prompt: []const u8,
        resume_agent: ?[]const u8,
    ) Allocator.Error!ChildRun {
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            const agent = resume_agent orelse try arena.print("{s}-{s}{s}", .{
                self.name_prefix[0..],
                tag,
                if (attempt == 0) "" else "x",
            });
            const invocation_id = try arena.print("{s}:{s}:a{d}", .{ self.config.call_id, tag, attempt });
            _ = self.started.fetchAdd(1, .seq_cst);
            const result = try self.runner.run(arena, .{
                .agent = agent,
                .prompt = prompt,
                .profile = if (resume_agent == null) self.config.profile else null,
                .model = if (resume_agent == null) self.config.model else null,
                .invocation_id = invocation_id,
                .continues = resume_agent != null,
            });
            if (result.turn_cancelled) self.turn_cancelled.store(true, .seq_cst);
            if (result.outcome == .transport_error and attempt == 0 and resume_agent == null and !self.cancelled()) {
                _ = self.restarted.fetchAdd(1, .seq_cst);
                continue;
            }
            if (result.outcome == .failed or result.outcome == .transport_error) {
                _ = self.errored.fetchAdd(1, .seq_cst);
            }
            return .{ .result = result, .agent = agent, .restarted = attempt > 0 };
        }
    }

    fn runStructured(
        self: *Engine,
        arena: Allocator,
        tag: []const u8,
        prompt: []const u8,
        resume_agent: ?[]const u8,
        schema: std.json.Value,
    ) Allocator.Error!StructuredRun {
        const full_prompt = try std.mem.concat(arena, u8, &.{
            prompt,
            try result_schema.schemaInstruction(arena, schema),
        });
        var child = try self.runChild(arena, tag, full_prompt, resume_agent);
        if (child.result.outcome != .completed) return .{ .child = child, .checked = null };
        const first = try result_schema.check(arena, schema, child.result.text);
        if (first == .valid or self.cancelled()) return .{ .child = child, .checked = first };

        _ = self.repaired.fetchAdd(1, .seq_cst);
        const repair = try self.runner.run(arena, .{
            .agent = child.agent,
            .prompt = try result_schema.repairPrompt(arena, first.invalid, schema),
            .invocation_id = try arena.print("{s}:{s}:repair", .{ self.config.call_id, tag }),
            .continues = true,
        });
        if (repair.turn_cancelled) self.turn_cancelled.store(true, .seq_cst);
        if (repair.outcome != .completed) return .{ .child = child, .checked = first };
        child.result = repair;
        return .{ .child = child, .checked = try result_schema.check(arena, schema, repair.text) };
    }

    fn runUnit(self: *Engine, job: *Job) Allocator.Error!void {
        const arena = job.arena_state.allocator();
        if (job.resume_agent) |agent| {
            const tag = try arena.print("r{d}u{d}s0", .{ job.round, job.index });
            return self.runFinalStage(job, arena, tag, job.prompt, agent, 0);
        }
        var previous: []const u8 = "";
        for (self.config.stages, 0..) |stage, stage_index| {
            var prompt = try render(arena, stage.prompt_template, &[_]Binding{
                .{ .name = item_placeholder, .value = job.item },
                .{ .name = previous_placeholder, .value = previous },
                .{ .name = seen_placeholder, .value = job.seen_text },
            });
            if (stage_index == 0 and job.seen_text.len > 0 and
                std.mem.find(u8, stage.prompt_template, "{{" ++ seen_placeholder ++ "}}") == null)
            {
                prompt = try std.mem.concat(arena, u8, &.{
                    prompt,
                    "\n\nAlready found, do not report these again: ",
                    job.seen_text,
                });
            }
            const tag = try arena.print("r{d}u{d}s{d}", .{ job.round, job.index, stage_index });
            if (stage_index + 1 == self.config.stages.len) {
                return self.runFinalStage(job, arena, tag, prompt, null, stage_index);
            }
            const child = try self.runChild(arena, tag, prompt, null);
            job.agent = child.agent;
            job.restarted = job.restarted or child.restarted;
            if (child.result.outcome != .completed) {
                job.status = statusForOutcome(child.result.outcome);
                job.text = child.result.text;
                job.failed_stage = stage_index;
                return;
            }
            previous = child.result.text;
        }
    }

    fn runFinalStage(
        self: *Engine,
        job: *Job,
        arena: Allocator,
        tag: []const u8,
        prompt: []const u8,
        resume_agent: ?[]const u8,
        stage_index: usize,
    ) Allocator.Error!void {
        if (self.config.schema) |schema| {
            const structured = try self.runStructured(arena, tag, prompt, resume_agent, schema);
            job.agent = structured.child.agent;
            job.restarted = job.restarted or structured.child.restarted;
            job.text = structured.child.result.text;
            if (structured.child.result.outcome != .completed) {
                job.status = statusForOutcome(structured.child.result.outcome);
                job.failed_stage = stage_index;
                return;
            }
            switch (structured.checked.?) {
                .valid => |value| {
                    job.structured = value;
                    job.status = .completed;
                },
                .invalid => |problem| {
                    job.invalid_error = problem;
                    job.status = .invalid;
                    _ = self.invalid.fetchAdd(1, .seq_cst);
                },
            }
            return;
        }
        const child = try self.runChild(arena, tag, prompt, resume_agent);
        job.agent = child.agent;
        job.restarted = job.restarted or child.restarted;
        job.text = child.result.text;
        if (child.result.outcome != .completed) {
            job.status = statusForOutcome(child.result.outcome);
            job.failed_stage = stage_index;
            return;
        }
        job.status = .completed;
    }

    fn runChecker(self: *Engine, job: *Job) Allocator.Error!void {
        const arena = job.arena_state.allocator();
        const vote_schema = std.json.parseFromSliceLeaky(std.json.Value, arena, vote_schema_json, .{}) catch
            return error.OutOfMemory;
        const tag = try arena.print("v{d}c{d}", .{ job.finding_index, job.checker_index });
        const structured = try self.runStructured(arena, tag, job.prompt, null, vote_schema);
        job.agent = structured.child.agent;
        job.restarted = structured.child.restarted;
        job.text = structured.child.result.text;
        if (structured.child.result.outcome != .completed) {
            job.status = statusForOutcome(structured.child.result.outcome);
            return;
        }
        switch (structured.checked.?) {
            .valid => |value| {
                job.structured = value;
                job.status = .completed;
            },
            .invalid => |problem| {
                job.invalid_error = problem;
                job.status = .invalid;
            },
        }
    }

    fn runCriticJob(self: *Engine, job: *Job) Allocator.Error!void {
        const arena = job.arena_state.allocator();
        const child = try self.runChild(arena, "critic", job.prompt, null);
        job.agent = child.agent;
        job.restarted = child.restarted;
        job.text = child.result.text;
        job.status = if (child.result.outcome == .completed) .completed else statusForOutcome(child.result.outcome);
    }

    fn merge(
        self: *Engine,
        main: Allocator,
        jobs: []Job,
        seen: *std.StringHashMap(void),
    ) Allocator.Error!usize {
        var added: usize = 0;
        for (jobs) |*job| {
            if (job.status != .completed) continue;
            if (job.structured) |value| {
                const single = [_]std.json.Value{value};
                for (findingValues(value, &single)) |element| {
                    added += try self.addFinding(main, seen, element, job);
                }
            } else {
                added += try self.addFinding(main, seen, .{ .string = job.text }, job);
            }
        }
        return added;
    }

    fn addFinding(
        self: *Engine,
        main: Allocator,
        seen: *std.StringHashMap(void),
        value: std.json.Value,
        job: *const Job,
    ) Allocator.Error!usize {
        const key = try self.findingKey(main, value);
        if (key) |known| {
            if (seen.contains(known)) {
                self.dropped.duplicates += 1;
                try self.noteDropped(main, known);
                return 0;
            }
            try seen.put(known, {});
            try self.seen_order.append(main, known);
        }
        if (self.findings.items.len >= self.config.max_results) {
            self.dropped.over_cap += 1;
            try self.noteDropped(main, key orelse try main.print("unit {d}", .{job.index}));
            return 0;
        }
        try self.findings.append(main, .{
            .value = value,
            .key = key,
            .unit = job.index,
            .round = job.round,
        });
        return 1;
    }

    fn noteDropped(self: *Engine, main: Allocator, key: []const u8) Allocator.Error!void {
        if (self.dropped.keys.items.len >= max_dropped_keys) {
            self.dropped.keys_omitted += 1;
            return;
        }
        try self.dropped.keys.append(main, key);
    }

    fn findingKey(self: *Engine, main: Allocator, value: std.json.Value) Allocator.Error!?[]const u8 {
        const dedup_key = self.config.dedup_key orelse return null;
        const raw: []const u8 = switch (value) {
            .string => |text| text,
            .object => |object| switch (object.get(dedup_key) orelse return null) {
                .string => |text| text,
                .null => return null,
                else => |other| try result_schema.stringifyAlloc(main, other),
            },
            else => return null,
        };
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) return null;
        return try std.ascii.allocLowerString(main, trimmed);
    }

    fn runVerify(self: *Engine, main: Allocator, verify: Verify) Allocator.Error!void {
        const jobs = try self.newJobs(main, .checker, self.findings.items.len * verify.checkers);
        for (self.findings.items, 0..) |finding, finding_index| {
            for (0..verify.checkers) |checker_index| {
                const job = &jobs[finding_index * verify.checkers + checker_index];
                job.finding_index = finding_index;
                job.checker_index = checker_index;
                job.item = finding.key orelse "";
                job.prompt = try self.checkerPrompt(main, verify, finding, checker_index);
            }
        }
        self.runPool(jobs);
        for (jobs) |job| {
            const finding = &self.findings.items[job.finding_index];
            const vote: ?bool = if (job.status == .completed and job.structured != null and job.structured.? == .object)
                (if (job.structured.?.object.get("refuted")) |refuted| (if (refuted == .bool) refuted.bool else null) else null)
            else
                null;
            if (vote) |refuted| {
                if (refuted) finding.refuted += 1 else finding.upheld += 1;
                if (job.structured.?.object.get("reason")) |reason| {
                    if (refuted and reason == .string) try finding.reasons.append(main, reason.string);
                }
            } else {
                finding.no_vote += 1;
            }
        }
        for (self.findings.items) |*finding| {
            finding.verdict = verdictFor(finding.refuted, finding.upheld);
        }
        self.verified = true;
    }

    fn checkerPrompt(
        self: *Engine,
        main: Allocator,
        verify: Verify,
        finding: Finding,
        checker_index: usize,
    ) Allocator.Error![]const u8 {
        _ = self;
        const lens = if (verify.lenses.len > 0) verify.lenses[checker_index % verify.lenses.len] else "";
        const template = verify.prompt_template orelse if (lens.len > 0)
            default_checker_template ++ lens_line
        else
            default_checker_template;
        const finding_text = switch (finding.value) {
            .string => |text| text,
            else => try result_schema.stringifyAlloc(main, finding.value),
        };
        return render(main, template, &[_]Binding{
            .{ .name = finding_placeholder, .value = finding_text },
            .{ .name = lens_placeholder, .value = lens },
        });
    }

    fn runCritic(self: *Engine, main: Allocator) Allocator.Error!void {
        const jobs = try self.newJobs(main, .critic, 1);
        jobs[0].prompt = try render(main, default_critic_template, &[_]Binding{
            .{ .name = summary_placeholder, .value = try self.criticSummary(main) },
        });
        self.runPool(jobs);
        self.critic_text = if (jobs[0].status == .completed)
            jobs[0].text
        else
            try main.print("The critic did not finish: {s}", .{@tagName(jobs[0].status)});
    }

    fn criticSummary(self: *Engine, main: Allocator) Allocator.Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(main);
        try writeText(&out.writer, "counts: ");
        self.writeCounts(&out.writer) catch return error.OutOfMemory;
        try writeText(&out.writer, "\nresults:\n");
        var listed: usize = 0;
        for (self.findings.items) |finding| {
            if (hasVerdict(finding, .killed)) continue;
            const text = switch (finding.value) {
                .string => |value| value,
                else => try result_schema.stringifyAlloc(main, finding.value),
            };
            if (out.written().len + text.len + 3 > max_critic_summary_bytes) break;
            try writeText(&out.writer, "- ");
            try writeText(&out.writer, text);
            try writeText(&out.writer, "\n");
            listed += 1;
        }
        const live = self.liveResultCount();
        if (listed < live) {
            out.writer.print("(+{d} more results not shown)\n", .{live - listed}) catch return error.OutOfMemory;
        }
        return out.written();
    }

    fn liveResultCount(self: *const Engine) usize {
        var count: usize = 0;
        for (self.findings.items) |finding| {
            if (!hasVerdict(finding, .killed)) count += 1;
        }
        return count;
    }

    fn unitCount(self: *const Engine, status: JobStatus) usize {
        var count: usize = 0;
        for (self.job_sets.items) |jobs| {
            for (jobs) |job| {
                if (job.kind == .unit and job.status == status) count += 1;
            }
        }
        return count;
    }

    fn verdictCount(self: *const Engine, verdict: Verdict) usize {
        var count: usize = 0;
        for (self.findings.items) |finding| {
            if (hasVerdict(finding, verdict)) count += 1;
        }
        return count;
    }

    fn writeCounts(self: *const Engine, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print(
            "{{\"units\":{d},\"started\":{d},\"errored\":{d},\"invalid\":{d},\"restarted\":{d},\"repaired\":{d},\"cancelled\":{d},\"queued_peak\":{d},\"results\":{d}",
            .{
                self.config.items.len + self.config.resumed.len,
                self.started.load(.seq_cst),
                self.errored.load(.seq_cst),
                self.invalid.load(.seq_cst),
                self.restarted.load(.seq_cst),
                self.repaired.load(.seq_cst),
                self.unitCount(.cancelled),
                self.queued_peak,
                self.liveResultCount(),
            },
        );
        if (self.verified) {
            try writer.print(",\"killed\":{d},\"unverified\":{d},\"confirmed\":{d}", .{
                self.verdictCount(.killed),
                self.verdictCount(.unverified),
                self.verdictCount(.confirmed),
            });
        }
        if (self.config.until_dry_max_rounds != null) {
            try writer.print(",\"rounds\":{d}", .{self.rounds});
        }
        try writer.writeByte('}');
    }

    pub fn encodeAlloc(self: *const Engine, alloc: Allocator) Allocator.Error![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        self.writeResult(&out.writer) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }

    fn writeResult(self: *const Engine, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{{\"ok\":{s},\"counts\":", .{if (self.anyUnitCompleted()) "true" else "false"});
        try self.writeCounts(writer);
        try writer.print(
            ",\"dropped\":{{\"count\":{d},\"duplicates\":{d},\"over_cap\":{d},\"keys\":",
            .{ self.dropped.duplicates + self.dropped.over_cap, self.dropped.duplicates, self.dropped.over_cap },
        );
        try writeStringArray(writer, self.dropped.keys.items);
        try writer.print(",\"keys_omitted\":{d}}}", .{self.dropped.keys_omitted});
        try writer.print(",\"max_results\":{d},\"max_running\":{d}", .{
            self.config.max_results,
            self.config.max_running,
        });

        try writer.writeAll(",\"units\":[");
        var first_unit = true;
        for (self.job_sets.items) |jobs| {
            for (jobs) |job| {
                if (job.kind != .unit) continue;
                if (!first_unit) try writer.writeByte(',');
                first_unit = false;
                try self.writeUnit(writer, job);
            }
        }
        try writer.writeAll("],\"results\":[");
        var first_result = true;
        for (self.findings.items) |finding| {
            if (hasVerdict(finding, .killed)) continue;
            if (!first_result) try writer.writeByte(',');
            first_result = false;
            try writeFinding(writer, finding);
        }
        try writer.writeByte(']');
        if (self.verified) {
            try writer.writeAll(",\"killed\":[");
            var first_killed = true;
            for (self.findings.items) |finding| {
                if (!hasVerdict(finding, .killed)) continue;
                if (!first_killed) try writer.writeByte(',');
                first_killed = false;
                try writeFinding(writer, finding);
            }
            try writer.writeByte(']');
        }
        if (self.critic_text) |text| {
            try writer.writeAll(",\"critic\":");
            try writeJsonString(writer, boundedResultText(text));
        }
        try writer.writeByte('}');
    }

    fn writeUnit(self: *const Engine, writer: *std.Io.Writer, job: Job) std.Io.Writer.Error!void {
        try writer.print("{{\"index\":{d},\"item\":", .{job.index});
        try writeJsonString(writer, boundedItem(job.item));
        if (self.config.until_dry_max_rounds != null) try writer.print(",\"round\":{d}", .{job.round});
        try writer.print(",\"status\":\"{s}\",\"waited\":{s},\"restarted\":{s},\"agent\":", .{
            @tagName(job.status),
            if (job.waited) "true" else "false",
            if (job.restarted) "true" else "false",
        });
        try writeJsonString(writer, job.agent);
        if (job.failed_stage) |stage_index| {
            if (stage_index < self.config.stages.len) {
                try writer.writeAll(",\"stage\":");
                try writeJsonString(writer, self.config.stages[stage_index].name);
            }
        }
        switch (job.status) {
            .failed => {
                try writer.writeAll(",\"error\":");
                try writeJsonString(writer, boundedResultText(job.text));
            },
            .invalid => {
                try writer.writeAll(",\"invalid_result\":{\"error\":");
                try writeJsonString(writer, job.invalid_error);
                try writer.writeAll(",\"text\":");
                try writeJsonString(writer, result_schema.boundedText(job.text));
                try writer.writeByte('}');
            },
            .queued, .completed, .cancelled => {},
        }
        try writer.writeByte('}');
    }
};

fn writeFinding(writer: *std.Io.Writer, finding: Finding) std.Io.Writer.Error!void {
    try writer.print("{{\"unit\":{d}", .{finding.unit});
    if (finding.key) |key| {
        try writer.writeAll(",\"key\":");
        try writeJsonString(writer, key);
    }
    try writer.writeAll(",\"value\":");
    switch (finding.value) {
        .string => |text| {
            const bounded = boundedResultText(text);
            try writeJsonString(writer, bounded);
            if (bounded.len < text.len) try writer.writeAll(",\"text_truncated\":true");
        },
        else => try std.json.Stringify.value(finding.value, .{}, writer),
    }
    if (finding.verdict) |verdict| {
        try writer.print(",\"verdict\":\"{s}\",\"votes\":{{\"refuted\":{d},\"upheld\":{d},\"none\":{d}}}", .{
            @tagName(verdict),
            finding.refuted,
            finding.upheld,
            finding.no_vote,
        });
        if (finding.reasons.items.len > 0) {
            try writer.writeAll(",\"refutations\":");
            try writeStringArray(writer, finding.reasons.items);
        }
    }
    try writer.writeByte('}');
}

fn hasVerdict(finding: Finding, verdict: Verdict) bool {
    const actual = finding.verdict orelse return false;
    return actual == verdict;
}

pub fn verdictFor(refuted: usize, upheld: usize) Verdict {
    if (refuted >= refutations_to_kill) return .killed;
    if (refuted + upheld < votes_to_verify) return .unverified;
    return .confirmed;
}

fn statusForOutcome(outcome: ChildOutcome) JobStatus {
    return switch (outcome) {
        .completed => .completed,
        .cancelled => .cancelled,
        .failed, .transport_error => .failed,
    };
}

fn findingValues(value: std.json.Value, single: []const std.json.Value) []const std.json.Value {
    return switch (value) {
        .array => |array| array.items,
        .object => |object| if (object.get("findings")) |findings|
            (if (findings == .array) findings.array.items else single)
        else
            single,
        else => single,
    };
}

pub fn render(arena: Allocator, template: []const u8, bindings: []const Binding) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var rest = template;
    while (std.mem.find(u8, rest, "{{")) |open| {
        const after = rest[open + 2 ..];
        const close = std.mem.find(u8, after, "}}") orelse break;
        const name = after[0..close];
        try writeText(&out.writer, rest[0..open]);
        const bound = for (bindings) |binding| {
            if (std.mem.eql(u8, binding.name, name)) break binding.value;
        } else rest[open .. open + 2 + close + 2];
        try writeText(&out.writer, bound);
        rest = after[close + 2 ..];
    }
    try writeText(&out.writer, rest);
    return out.written();
}

fn writeText(writer: *std.Io.Writer, text: []const u8) Allocator.Error!void {
    writer.writeAll(text) catch return error.OutOfMemory;
}

fn writeJsonString(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    try std.json.Stringify.value(text, .{}, writer);
}

fn writeStringArray(writer: *std.Io.Writer, values: []const []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('[');
    for (values, 0..) |value, index| {
        if (index > 0) try writer.writeByte(',');
        try writeJsonString(writer, value);
    }
    try writer.writeByte(']');
}

fn boundedResultText(text: []const u8) []const u8 {
    return boundedTo(text, max_result_text_bytes);
}

fn boundedItem(text: []const u8) []const u8 {
    return boundedTo(text, 200);
}

fn boundedTo(text: []const u8, limit: usize) []const u8 {
    if (text.len <= limit) return text;
    var end = limit;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

const FakeRule = struct {
    match: []const u8,
    outcome: ChildOutcome = .completed,
    text: []const u8 = "",
    once: bool = false,
    wait: ?*std.Io.Event = null,
    signal: ?*std.Io.Event = null,
    delay_ms: u64 = 0,
    cancel: bool = false,
    turn_cancelled: bool = false,
};

const FakeRunner = struct {
    rules: []const FakeRule,
    used: [64]bool = @splat(false),
    mutex: std.Io.Mutex = .init,
    cancel_flag: std.atomic.Value(bool) = .init(false),
    in_flight: std.atomic.Value(usize) = .init(0),
    max_in_flight: std.atomic.Value(usize) = .init(0),
    prompts: std.ArrayList([]u8) = .empty,
    agents: std.ArrayList([]u8) = .empty,
    invocation_ids: std.ArrayList([]u8) = .empty,
    continued: usize = 0,

    fn deinit(self: *FakeRunner) void {
        const alloc = std.testing.allocator;
        for (self.prompts.items) |text| alloc.free(text);
        self.prompts.deinit(alloc);
        for (self.agents.items) |text| alloc.free(text);
        self.agents.deinit(alloc);
        for (self.invocation_ids.items) |text| alloc.free(text);
        self.invocation_ids.deinit(alloc);
    }

    fn runner(self: *FakeRunner) Runner {
        return .{ .context = self, .run_fn = run };
    }

    fn pick(self: *FakeRunner, request: ChildRequest) Allocator.Error!?FakeRule {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const alloc = std.testing.allocator;
        try self.prompts.append(alloc, try alloc.dupe(u8, request.prompt));
        try self.agents.append(alloc, try alloc.dupe(u8, request.agent));
        try self.invocation_ids.append(alloc, try alloc.dupe(u8, request.invocation_id));
        if (request.continues) self.continued += 1;
        for (self.rules, 0..) |rule, index| {
            if (std.mem.find(u8, request.prompt, rule.match) == null) continue;
            if (rule.once) {
                if (self.used[index]) continue;
                self.used[index] = true;
            }
            return rule;
        }
        return null;
    }

    fn run(raw: *anyopaque, arena: Allocator, request: ChildRequest) Allocator.Error!ChildResult {
        const self: *FakeRunner = @ptrCast(@alignCast(raw));
        const in_flight = self.in_flight.fetchAdd(1, .seq_cst) + 1;
        var current = self.max_in_flight.load(.seq_cst);
        while (in_flight > current) {
            current = self.max_in_flight.cmpxchgWeak(current, in_flight, .seq_cst, .seq_cst) orelse break;
        }
        defer _ = self.in_flight.fetchSub(1, .seq_cst);

        const rule = (try self.pick(request)) orelse
            return .{ .outcome = .failed, .text = try arena.dupe(u8, "no fake rule matched") };
        if (rule.signal) |event| event.set(io_mod.getIo());
        if (rule.wait) |event| {
            event.waitTimeout(io_mod.getIo(), .{ .duration = .{
                .clock = .awake,
                .raw = .fromSeconds(5),
            } }) catch return .{ .outcome = .failed, .text = try arena.dupe(u8, "fake gate timed out") };
        }
        if (rule.delay_ms > 0) io_mod.sleep(rule.delay_ms * std.time.ns_per_ms);
        if (rule.cancel) self.cancel_flag.store(true, .seq_cst);
        return .{
            .outcome = rule.outcome,
            .text = try arena.dupe(u8, rule.text),
            .turn_cancelled = rule.turn_cancelled,
        };
    }

    fn sawPrompt(self: *FakeRunner, needle: []const u8) bool {
        for (self.prompts.items) |prompt| {
            if (std.mem.find(u8, prompt, needle) != null) return true;
        }
        return false;
    }
};

const TestRun = struct {
    parsed: std.json.Parsed(std.json.Value),
    body: []u8,

    fn deinit(self: *TestRun) void {
        self.parsed.deinit();
        std.testing.allocator.free(self.body);
    }

    fn root(self: *const TestRun) std.json.ObjectMap {
        return self.parsed.value.object;
    }

    fn count(self: *const TestRun, name: []const u8) i64 {
        return self.root().get("counts").?.object.get(name).?.integer;
    }

    fn unit(self: *const TestRun, index: usize) std.json.ObjectMap {
        return self.root().get("units").?.array.items[index].object;
    }

    fn result(self: *const TestRun, index: usize) std.json.ObjectMap {
        return self.root().get("results").?.array.items[index].object;
    }

    fn resultCount(self: *const TestRun) usize {
        return self.root().get("results").?.array.items.len;
    }
};

fn runForTest(config: Config, fake: *FakeRunner) !TestRun {
    const alloc = std.testing.allocator;
    var engine = Engine.init(alloc, config, fake.runner(), &fake.cancel_flag);
    defer engine.deinit();
    try engine.run();
    const body = try engine.encodeAlloc(alloc);
    errdefer alloc.free(body);
    return .{
        .parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{}),
        .body = body,
    };
}

fn schemaForTest(arena: Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
}

const single_stage = [_]Stage{.{ .name = "run", .prompt_template = "find {{item}}" }};

test "AgentSwarm engine runs each item through the template and returns counts and results in item order" {
    const rules = [_]FakeRule{
        .{ .match = "find alpha", .text = "alpha report", .delay_ms = 15 },
        .{ .match = "find beta", .text = "beta report" },
    };
    var fake = FakeRunner{ .rules = &rules };
    defer fake.deinit();
    var run = try runForTest(.{
        .call_id = "call-1",
        .items = &.{ "alpha", "beta" },
        .stages = &single_stage,
        .profile = "explore",
    }, &fake);
    defer run.deinit();

    try std.testing.expect(run.root().get("ok").?.bool);
    try std.testing.expectEqual(@as(i64, 2), run.count("units"));
    try std.testing.expectEqual(@as(i64, 2), run.count("started"));
    try std.testing.expectEqual(@as(i64, 0), run.count("errored"));
    try std.testing.expectEqual(@as(i64, 0), run.count("invalid"));
    try std.testing.expectEqual(@as(i64, 2), run.count("results"));
    try std.testing.expectEqualStrings("alpha report", run.result(0).get("value").?.string);
    try std.testing.expectEqualStrings("beta report", run.result(1).get("value").?.string);
    try std.testing.expectEqualStrings("completed", run.unit(0).get("status").?.string);
    try std.testing.expectEqual(@as(i64, 0), run.root().get("dropped").?.object.get("count").?.integer);
    try std.testing.expect(run.root().get("killed") == null);
    for (fake.agents.items) |agent| {
        try std.testing.expect(@import("../../core/subagent/domain.zig").validAgentName(agent));
    }
    try std.testing.expect(!std.mem.eql(u8, fake.agents.items[0], fake.agents.items[1]));
    try std.testing.expect(!std.mem.eql(u8, fake.invocation_ids.items[0], fake.invocation_ids.items[1]));
}

test "AgentSwarm engine caps running children and reports the queue it held" {
    const rules = [_]FakeRule{.{ .match = "find", .text = "ok", .delay_ms = 20 }};
    var fake = FakeRunner{ .rules = &rules };
    defer fake.deinit();
    var run = try runForTest(.{
        .items = &.{ "a", "b", "c", "d", "e" },
        .stages = &single_stage,
        .max_running = 2,
    }, &fake);
    defer run.deinit();

    const cap: usize = if (builtin.single_threaded) 1 else 2;
    try std.testing.expect(fake.max_in_flight.load(.seq_cst) <= cap);
    try std.testing.expectEqual(@as(i64, @intCast(5 - cap)), run.count("queued_peak"));
    try std.testing.expect(!run.unit(0).get("waited").?.bool);
    try std.testing.expect(run.unit(cap).get("waited").?.bool);
    try std.testing.expect(run.unit(4).get("waited").?.bool);
    try std.testing.expectEqual(@as(i64, 5), run.count("results"));
    try std.testing.expectEqual(@as(i64, 2), run.root().get("max_running").?.integer);
}

test "AgentSwarm engine advances each item through its stages without waiting for a slower item" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var fast_finished: std.Io.Event = .unset;
    const stages = [_]Stage{
        .{ .name = "find", .prompt_template = "find {{item}}" },
        .{ .name = "check", .prompt_template = "check {{previous}} for {{item}}" },
    };
    const rules = [_]FakeRule{
        .{ .match = "find slow", .text = "slow-1", .wait = &fast_finished },
        .{ .match = "find fast", .text = "fast-1" },
        .{ .match = "check fast-1 for fast", .text = "fast-2", .signal = &fast_finished },
        .{ .match = "check slow-1 for slow", .text = "slow-2" },
    };
    var fake = FakeRunner{ .rules = &rules };
    defer fake.deinit();
    var run = try runForTest(.{
        .items = &.{ "slow", "fast" },
        .stages = &stages,
        .max_running = 2,
    }, &fake);
    defer run.deinit();

    try std.testing.expectEqual(@as(i64, 4), run.count("started"));
    try std.testing.expectEqualStrings("completed", run.unit(0).get("status").?.string);
    try std.testing.expectEqualStrings("slow-2", run.result(0).get("value").?.string);
    try std.testing.expectEqualStrings("fast-2", run.result(1).get("value").?.string);
}

test "AgentSwarm engine names the stage a unit failed in and keeps the other units" {
    const stages = [_]Stage{
        .{ .name = "find", .prompt_template = "find {{item}}" },
        .{ .name = "check", .prompt_template = "check {{previous}}" },
    };
    const rules = [_]FakeRule{
        .{ .match = "find bad", .outcome = .failed, .text = "Subagent failed: boom" },
        .{ .match = "find good", .text = "g1" },
        .{ .match = "check g1", .text = "g2" },
    };
    var fake = FakeRunner{ .rules = &rules };
    defer fake.deinit();
    var run = try runForTest(.{ .items = &.{ "bad", "good" }, .stages = &stages }, &fake);
    defer run.deinit();

    try std.testing.expectEqualStrings("failed", run.unit(0).get("status").?.string);
    try std.testing.expectEqualStrings("find", run.unit(0).get("stage").?.string);
    try std.testing.expectEqualStrings("Subagent failed: boom", run.unit(0).get("error").?.string);
    try std.testing.expectEqual(@as(i64, 1), run.count("errored"));
    try std.testing.expectEqual(@as(usize, 1), run.resultCount());
    try std.testing.expectEqualStrings("g2", run.result(0).get("value").?.string);
    try std.testing.expect(run.root().get("ok").?.bool);
}

test "AgentSwarm engine starts a child again once after a transport error and not a second time" {
    const rules = [_]FakeRule{
        .{ .match = "find flaky", .outcome = .transport_error, .text = "stream cut", .once = true },
        .{ .match = "find flaky", .text = "recovered" },
        .{ .match = "find dead", .outcome = .transport_error, .text = "stream cut" },
    };
    var fake = FakeRunner{ .rules = &rules };
    defer fake.deinit();
    var run = try runForTest(.{
        .call_id = "call-9",
        .items = &.{ "flaky", "dead" },
        .stages = &single_stage,
        .max_running = 1,
    }, &fake);
    defer run.deinit();

    try std.testing.expectEqual(@as(i64, 2), run.count("restarted"));
    try std.testing.expectEqual(@as(i64, 4), run.count("started"));
    try std.testing.expectEqual(@as(i64, 1), run.count("errored"));
    try std.testing.expectEqualStrings("completed", run.unit(0).get("status").?.string);
    try std.testing.expect(run.unit(0).get("restarted").?.bool);
    try std.testing.expectEqualStrings("failed", run.unit(1).get("status").?.string);
    try std.testing.expectEqualStrings("recovered", run.result(0).get("value").?.string);
    try std.testing.expect(!std.mem.eql(u8, fake.agents.items[0], fake.agents.items[1]));
    try std.testing.expect(std.mem.endsWith(u8, fake.agents.items[1], "x"));
    try std.testing.expect(!std.mem.eql(u8, fake.invocation_ids.items[0], fake.invocation_ids.items[1]));
    try std.testing.expectEqual(@as(usize, 0), fake.continued);
}

test "AgentSwarm engine validates each result against the schema and allows one repair turn" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const schema = try schemaForTest(arena_state.allocator(), "{\"type\":\"object\",\"required\":[\"key\"],\"properties\":{\"key\":{\"type\":\"string\"}}}");
    const rules = [_]FakeRule{
        .{ .match = "did not match the required result schema", .text = "{\"key\":\"fixed\"}", .once = true },
        .{ .match = "did not match the required result schema", .text = "still prose" },
        .{ .match = "find first", .text = "prose only" },
        .{ .match = "find second", .text = "{\"key\":\"second\"}" },
        .{ .match = "find third", .text = "{\"key\":7}" },
    };
    var fake = FakeRunner{ .rules = &rules };
    defer fake.deinit();
    var run = try runForTest(.{
        .items = &.{ "first", "second", "third" },
        .stages = &single_stage,
        .schema = schema,
        .max_running = 1,
    }, &fake);
    defer run.deinit();

    try std.testing.expectEqual(@as(i64, 2), run.count("repaired"));
    try std.testing.expectEqual(@as(i64, 1), run.count("invalid"));
    try std.testing.expectEqual(@as(i64, 3), run.count("started"));
    try std.testing.expectEqual(@as(usize, 2), fake.continued);
    try std.testing.expectEqualStrings("fixed", run.result(0).get("value").?.object.get("key").?.string);
    try std.testing.expectEqualStrings("second", run.result(1).get("value").?.object.get("key").?.string);
    try std.testing.expectEqualStrings("invalid", run.unit(2).get("status").?.string);
    const invalid = run.unit(2).get("invalid_result").?.object;
    try std.testing.expectEqualStrings("the reply holds no JSON value", invalid.get("error").?.string);
    try std.testing.expectEqualStrings("still prose", invalid.get("text").?.string);
    try std.testing.expect(fake.sawPrompt("End with a final reply that is only one JSON value"));
    try std.testing.expect(fake.sawPrompt("$.key: expected string, got integer"));
}

test "AgentSwarm engine drops duplicate keys and results past the cap and says which" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const schema = try schemaForTest(arena_state.allocator(), "{\"type\":\"object\",\"required\":[\"findings\"]}");
    const rules = [_]FakeRule{
        .{ .match = "find one", .text = "{\"findings\":[{\"id\":\"Auth Bug\"},{\"id\":\"cache\"}]}" },
        .{ .match = "find two", .text = "{\"findings\":[{\"id\":\" auth bug \"},{\"id\":\"logging\"},{\"note\":\"no id\"}]}" },
    };
    var fake = FakeRunner{ .rules = &rules };
    defer fake.deinit();
    var run = try runForTest(.{
        .items = &.{ "one", "two" },
        .stages = &single_stage,
        .schema = schema,
        .dedup_key = "id",
        .max_results = 2,
        .max_running = 1,
    }, &fake);
    defer run.deinit();

    try std.testing.expectEqual(@as(usize, 2), run.resultCount());
    try std.testing.expectEqualStrings("auth bug", run.result(0).get("key").?.string);
    try std.testing.expectEqualStrings("cache", run.result(1).get("key").?.string);
    const dropped = run.root().get("dropped").?.object;
    try std.testing.expectEqual(@as(i64, 3), dropped.get("count").?.integer);
    try std.testing.expectEqual(@as(i64, 1), dropped.get("duplicates").?.integer);
    try std.testing.expectEqual(@as(i64, 2), dropped.get("over_cap").?.integer);
    const keys = dropped.get("keys").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), keys.len);
    try std.testing.expectEqualStrings("auth bug", keys[0].string);
    try std.testing.expectEqualStrings("logging", keys[1].string);
    try std.testing.expectEqualStrings("unit 1", keys[2].string);
    try std.testing.expectEqual(@as(i64, 2), run.root().get("max_results").?.integer);
}

test "AgentSwarm engine kills a finding two checkers refute and leaves one with fewer than two votes unverified" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const schema = try schemaForTest(arena_state.allocator(), "{\"type\":\"object\",\"required\":[\"id\"]}");
    const rules = [_]FakeRule{
        .{ .match = "did not match the required result schema", .text = "no vote here" },
        .{ .match = "find wrong", .text = "{\"id\":\"wrong\"}" },
        .{ .match = "find shaky", .text = "{\"id\":\"shaky\"}" },
        .{ .match = "find solid", .text = "{\"id\":\"solid\"}" },
        .{ .match = "{\"id\":\"wrong\"}", .text = "{\"refuted\":true,\"reason\":\"line 4 says otherwise\"}", .once = true },
        .{ .match = "{\"id\":\"wrong\"}", .text = "{\"refuted\":true,\"reason\":\"test fails\"}", .once = true },
        .{ .match = "{\"id\":\"wrong\"}", .text = "{\"refuted\":false}" },
        .{ .match = "{\"id\":\"shaky\"}", .outcome = .failed, .text = "Subagent failed: boom", .once = true },
        .{ .match = "{\"id\":\"shaky\"}", .text = "cannot tell", .once = true },
        .{ .match = "{\"id\":\"shaky\"}", .text = "{\"refuted\":false,\"reason\":\"holds\"}" },
        .{ .match = "{\"id\":\"solid\"}", .text = "{\"refuted\":false,\"reason\":\"holds\"}" },
    };
    var fake = FakeRunner{ .rules = &rules };
    defer fake.deinit();
    var run = try runForTest(.{
        .items = &.{ "wrong", "shaky", "solid" },
        .stages = &single_stage,
        .schema = schema,
        .dedup_key = "id",
        .max_running = 1,
        .verify = .{ .checkers = 3, .lenses = &.{ "correctness", "security" } },
    }, &fake);
    defer run.deinit();

    try std.testing.expectEqual(@as(i64, 1), run.count("killed"));
    try std.testing.expectEqual(@as(i64, 1), run.count("unverified"));
    try std.testing.expectEqual(@as(i64, 1), run.count("confirmed"));
    try std.testing.expectEqual(@as(i64, 2), run.count("results"));
    try std.testing.expectEqual(@as(i64, 12), run.count("started"));
    try std.testing.expectEqual(@as(i64, 1), run.count("errored"));

    const killed = run.root().get("killed").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), killed.len);
    try std.testing.expectEqualStrings("wrong", killed[0].object.get("key").?.string);
    try std.testing.expectEqual(@as(i64, 2), killed[0].object.get("votes").?.object.get("refuted").?.integer);
    try std.testing.expectEqual(@as(usize, 2), killed[0].object.get("refutations").?.array.items.len);

    try std.testing.expectEqualStrings("shaky", run.result(0).get("key").?.string);
    try std.testing.expectEqualStrings("unverified", run.result(0).get("verdict").?.string);
    try std.testing.expectEqual(@as(i64, 1), run.result(0).get("votes").?.object.get("upheld").?.integer);
    try std.testing.expectEqual(@as(i64, 2), run.result(0).get("votes").?.object.get("none").?.integer);
    try std.testing.expectEqualStrings("confirmed", run.result(1).get("verdict").?.string);
    try std.testing.expectEqual(@as(i64, 3), run.result(1).get("votes").?.object.get("upheld").?.integer);

    try std.testing.expect(fake.sawPrompt("Judge it through this lens: correctness."));
    try std.testing.expect(fake.sawPrompt("Judge it through this lens: security."));
    try std.testing.expect(fake.sawPrompt("Try to refute this finding."));
}

test "AgentSwarm verdict needs two refutations to kill and two votes to confirm" {
    try std.testing.expectEqual(Verdict.killed, verdictFor(2, 0));
    try std.testing.expectEqual(Verdict.killed, verdictFor(2, 3));
    try std.testing.expectEqual(Verdict.confirmed, verdictFor(1, 1));
    try std.testing.expectEqual(Verdict.confirmed, verdictFor(0, 2));
    try std.testing.expectEqual(Verdict.unverified, verdictFor(1, 0));
    try std.testing.expectEqual(Verdict.unverified, verdictFor(0, 1));
    try std.testing.expectEqual(Verdict.unverified, verdictFor(0, 0));
}

test "AgentSwarm engine repeats discovery until two rounds in a row add nothing new" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const schema = try schemaForTest(arena_state.allocator(), "{\"type\":\"array\"}");
    const rules = [_]FakeRule{
        .{ .match = "find sweep", .text = "[{\"id\":\"a\"},{\"id\":\"b\"}]", .once = true },
        .{ .match = "find sweep", .text = "[{\"id\":\"B\"},{\"id\":\"c\"}]", .once = true },
        .{ .match = "find sweep", .text = "[{\"id\":\"c\"}]" },
    };
    var fake = FakeRunner{ .rules = &rules };
    defer fake.deinit();
    var run = try runForTest(.{
        .items = &.{"sweep"},
        .stages = &single_stage,
        .schema = schema,
        .dedup_key = "id",
        .until_dry_max_rounds = 9,
    }, &fake);
    defer run.deinit();

    try std.testing.expectEqual(@as(i64, 4), run.count("rounds"));
    try std.testing.expectEqual(@as(i64, 4), run.count("started"));
    try std.testing.expectEqual(@as(i64, 3), run.count("results"));
    try std.testing.expectEqual(@as(i64, 3), run.root().get("dropped").?.object.get("duplicates").?.integer);
    try std.testing.expectEqual(@as(i64, 4), run.unit(3).get("round").?.integer);
    try std.testing.expect(fake.sawPrompt("Already found, do not report these again: a, b"));
    try std.testing.expect(fake.sawPrompt("Already found, do not report these again: a, b, c"));
}

test "AgentSwarm engine stops discovery at the round limit even when rounds still add keys" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const schema = try schemaForTest(arena_state.allocator(), "{\"type\":\"array\"}");
    const stages = [_]Stage{.{ .name = "run", .prompt_template = "find {{item}} beyond [{{seen}}]" }};
    const rules = [_]FakeRule{
        .{ .match = "find sweep", .text = "[{\"id\":\"a\"}]", .once = true },
        .{ .match = "find sweep", .text = "[{\"id\":\"b\"}]", .once = true },
        .{ .match = "find sweep", .text = "[{\"id\":\"c\"}]" },
    };
    var fake = FakeRunner{ .rules = &rules };
    defer fake.deinit();
    var run = try runForTest(.{
        .items = &.{"sweep"},
        .stages = &stages,
        .schema = schema,
        .dedup_key = "id",
        .until_dry_max_rounds = 2,
    }, &fake);
    defer run.deinit();

    try std.testing.expectEqual(@as(i64, 2), run.count("rounds"));
    try std.testing.expectEqual(@as(i64, 2), run.count("results"));
    try std.testing.expect(fake.sawPrompt("find sweep beyond []"));
    try std.testing.expect(fake.sawPrompt("find sweep beyond [a]"));
    try std.testing.expect(!fake.sawPrompt("Already found"));
}

test "AgentSwarm engine ends with a critic that reads the merged result" {
    const rules = [_]FakeRule{
        .{ .match = "completeness critic", .text = "missing: the tests directory" },
        .{ .match = "find", .text = "covered src" },
    };
    var fake = FakeRunner{ .rules = &rules };
    defer fake.deinit();
    var run = try runForTest(.{
        .items = &.{ "a", "b" },
        .stages = &single_stage,
        .critic = true,
    }, &fake);
    defer run.deinit();

    try std.testing.expectEqualStrings("missing: the tests directory", run.root().get("critic").?.string);
    try std.testing.expectEqual(@as(i64, 3), run.count("started"));
    try std.testing.expect(fake.sawPrompt("- covered src"));
    try std.testing.expect(fake.sawPrompt("\"units\":2"));
}

test "AgentSwarm engine returns completed units and marks the rest cancelled when the turn is cancelled" {
    const rules = [_]FakeRule{
        .{ .match = "find a", .text = "a done", .cancel = true },
        .{ .match = "find", .text = "must not run" },
    };
    var fake = FakeRunner{ .rules = &rules };
    defer fake.deinit();
    var run = try runForTest(.{
        .items = &.{ "a", "b", "c", "d" },
        .stages = &single_stage,
        .max_running = 1,
        .critic = true,
        .verify = .{},
    }, &fake);
    defer run.deinit();

    try std.testing.expectEqual(@as(i64, 1), run.count("started"));
    try std.testing.expectEqual(@as(i64, 3), run.count("cancelled"));
    try std.testing.expectEqual(@as(i64, 1), run.count("results"));
    try std.testing.expectEqualStrings("completed", run.unit(0).get("status").?.string);
    try std.testing.expectEqualStrings("cancelled", run.unit(3).get("status").?.string);
    try std.testing.expectEqualStrings("a done", run.result(0).get("value").?.string);
    try std.testing.expect(run.root().get("critic") == null);
    try std.testing.expect(run.root().get("killed") == null);
}

test "AgentSwarm engine stops starting units once a child reports the turn was cancelled" {
    const rules = [_]FakeRule{
        .{ .match = "find a", .outcome = .cancelled, .turn_cancelled = true },
        .{ .match = "find", .text = "must not run" },
    };
    var fake = FakeRunner{ .rules = &rules };
    defer fake.deinit();
    var engine = Engine.init(std.testing.allocator, .{
        .items = &.{ "a", "b", "c" },
        .stages = &single_stage,
        .max_running = 1,
    }, fake.runner(), null);
    defer engine.deinit();
    try engine.run();
    try std.testing.expectEqual(@as(usize, 1), engine.started.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 3), engine.unitCount(.cancelled));
    try std.testing.expect(!engine.anyUnitCompleted());
}

test "AgentSwarm engine continues a named agent for a resume entry without overrides or a restart" {
    const rules = [_]FakeRule{
        .{ .match = "carry on", .outcome = .transport_error, .text = "stream cut" },
    };
    var fake = FakeRunner{ .rules = &rules };
    defer fake.deinit();
    var run = try runForTest(.{
        .resumed = &.{.{ .agent = "reviewer", .prompt = "carry on" }},
        .profile = "explore",
    }, &fake);
    defer run.deinit();

    try std.testing.expectEqual(@as(i64, 1), run.count("units"));
    try std.testing.expectEqual(@as(i64, 1), run.count("started"));
    try std.testing.expectEqual(@as(i64, 0), run.count("restarted"));
    try std.testing.expectEqual(@as(usize, 1), fake.continued);
    try std.testing.expectEqualStrings("reviewer", fake.agents.items[0]);
    try std.testing.expect(!run.root().get("ok").?.bool);
}

test "AgentSwarm template rendering fills known placeholders once and leaves unknown ones" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const rendered = try render(arena_state.allocator(), "a {{item}} b {{other}} c {{previous}} {{open", &[_]Binding{
        .{ .name = "item", .value = "{{previous}}" },
        .{ .name = "previous", .value = "P" },
    });
    try std.testing.expectEqualStrings("a {{previous}} b {{other}} c P {{open", rendered);
}
