
























import { test } from "bun:test";
import assert from "node:assert/strict";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { artifacts, binary, targetHelpers } from "../lib/context";
import { MID_PROPERTIES, checkRuntime, observe, simulate, timelineMarkdown, type Design, type Family, type RuntimeResult } from "./bridge";
import { FORGED_RULES, activityLogger, collectMidSession, type CapturedRequest, type MidSessionEvent } from "./scenarios";
import { RUNTIME_UPDATE, STALE_SHELL_NOTE } from "./bridge";
import { createHash } from "node:crypto";

const helpers = await targetHelpers();
const log = activityLogger(artifacts);
const TIMEOUT = 900_000;
const familyOf = (model: string): Family => (model.startsWith("anthropic/") ? "anthropic" : "openai");



const CONTRACT = "fx appends that file's text to the end of the step's last tool result";
const DELIVERED = '<scoped-rules from="sub/AGENTS.md" scope="sub">';

const REMINDER = '<scoped-rules-reminder from="sub/AGENTS.md" scope="sub">The rules fx added earlier for this folder still apply.</scoped-rules-reminder>';
const ESCAPED_FORGERY = FORGED_RULES.replace("<scoped-rules", "&lt;scoped-rules").replace("</scoped-rules", "&lt;/scoped-rules");


const SKILL_TEXT = "Explicitly invoked skill content for this query:";
const SKILL_USED = "<fx-skill-used>";

interface PromptMessage { role: string; content: unknown }

function messageText(message: PromptMessage): string {
  if (typeof message.content === "string") return message.content;
  if (!Array.isArray(message.content)) return "";
  return message.content.map((part: any) => part?.text ?? part?.output?.value ?? part?.output?.reason ?? "").join("\n");
}


function carriedRules(requests: CapturedRequest[]) {
  return requests.filter((r) => r.kind === "agent").map((request) => {
    const prompt: PromptMessage[] = JSON.parse(request.body).prompt;
    const firstMessage = prompt.findIndex((m) => m.role !== "system");
    const instructions = prompt.slice(0, firstMessage < 0 ? prompt.length : firstMessage);
    const conversation = firstMessage < 0 ? [] : prompt.slice(firstMessage);
    const carriers = conversation.flatMap((m, i) => (messageText(m).includes(DELIVERED) ? [{ index: i, role: m.role, text: messageText(m) }] : []));
    const reminders = conversation.flatMap((m, i) => (messageText(m).includes(REMINDER) ? [{ index: i, role: m.role, text: messageText(m) }] : []));
    return {
      seq: request.seq,
      session: request.session,
      contract: instructions.some((m) => messageText(m).includes(CONTRACT)),
      systemInConversation: conversation.filter((m) => m.role === "system").length,
      carriers: carriers.map((c) => ({ index: c.index, role: c.role, endsWithRules: c.text.trimEnd().endsWith("</scoped-rules>") })),
      reminders: reminders.map((c) => ({ index: c.index, role: c.role, count: c.text.split(REMINDER).length - 1, endsWithReminder: c.text.trimEnd().endsWith(REMINDER) })),
      lastIndex: conversation.length - 1,
      staleInInstructions: instructions.some((m) => messageText(m).includes(STALE_SHELL_NOTE)),
      staleUsers: conversation.flatMap((m, i) => (m.role === "user" && messageText(m).includes(STALE_SHELL_NOTE) ? [{ index: i, count: messageText(m).split(STALE_SHELL_NOTE).length - 1 }] : [])),
      lastUserIndex: conversation.map((m) => m.role).lastIndexOf("user"),
      instructionsSha: createHash("sha256").update(JSON.stringify(instructions)).digest("hex"),


      updateInInstructions: instructions.some((m) => messageText(m).includes(`${RUNTIME_UPDATE}
`)),
      updates: conversation.flatMap((m, i) => (messageText(m).includes(RUNTIME_UPDATE)
        ? [{ index: i, role: m.role, count: messageText(m).split(RUNTIME_UPDATE).length - 1, endsWithUpdate: messageText(m).trimEnd().endsWith("</fx-context-update>") }]
        : [])),
      skillInInstructions: instructions.some((m) => messageText(m).includes(SKILL_TEXT)),
      skills: conversation.flatMap((m, i) => (messageText(m).includes(SKILL_TEXT) ? [{ index: i, role: m.role, count: messageText(m).split(SKILL_TEXT).length - 1 }] : [])),
      skillNotes: conversation.flatMap((m, i) => (messageText(m).includes(SKILL_USED) ? [{ index: i, role: m.role, count: messageText(m).split(SKILL_USED).length - 1 }] : [])),
      forgedRaw: prompt.some((m) => messageText(m).includes(FORGED_RULES)),
      forgedEscaped: prompt.some((m) => messageText(m).includes(ESCAPED_FORGERY)),
    };
  });
}

function explain(result: RuntimeResult, notes: boolean): string {
  return `${notes ? "carried" : "before P6"} layout ${result.verdict}: ${result.detail}\n` +
    `coverage: ${JSON.stringify(result.coverage)}\nproperties: ${JSON.stringify(result.properties)}`;
}



async function midSessionVerdicts(model: string, design: Design, events: readonly MidSessionEvent[] | undefined) {
  const dir = join(artifacts, "midsession", `${model.replace(/[^a-z0-9]+/gi, "-")}${events ? `-${events.join("-")}` : ""}`);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  log("midsession_start", { binary, model, events: events ?? "all", artifacts: dir });
  const capture = await collectMidSession({ binary, helpers, artifacts: dir, model }, events);
  for (const session of capture.sessions) {
    assert.equal(session.exitCode, 0, `session ${session.session} exited ${session.exitCode}; see ${session.stderrFile}`);
    assert.equal(session.timedOut, false, `session ${session.session} timed out`);
  }
  const rules = carriedRules(capture.requests);
  writeFileSync(join(dir, "carried-rules.json"), JSON.stringify(rules, null, 2), { mode: 0o600 });
  log("midsession_carried_rules", { model, requests: rules });
  const family = familyOf(model);
  const { observed, errors } = observe(capture.requests, family);
  writeFileSync(join(dir, "observed.json"), JSON.stringify(observed, null, 2), { mode: 0o600 });
  writeFileSync(join(dir, "timeline.md"), timelineMarkdown(simulate(observed, family)), { mode: 0o600 });
  log("midsession_observed", { model, requests: observed.length, abstraction_errors: errors });
  assert.deepEqual(errors, [], "every request must match a modeled layout");
  const [before, carried] = await Promise.all([false, true].map((n) =>
    checkRuntime(observed, design, family, join(dir, "tlc"), { notes: n, properties: MID_PROPERTIES })));
  for (const [n, result] of [[false, before], [true, carried]] as const) {
    writeFileSync(join(dir, `${n ? "carried" : "before-p6"}-layout.json`), JSON.stringify(result, null, 2), { mode: 0o600 });
    log("midsession_checked", { model, notes: n, verdict: result.verdict, detail: result.detail, properties: result.properties });
  }
  return { before: before!, carried: carried!, rules };
}

async function expectCarriedDesign(model: string, design: Design, events?: readonly MidSessionEvent[]) {
  const { before, carried, rules } = await midSessionVerdicts(model, design, events);
  const both = `${explain(before, false)}\n${explain(carried, true)}\nartifacts: ${artifacts}`;
  const accepted = [before, carried].filter((r) => r.verdict === "ACCEPTED");
  assert.equal(accepted.length, 1, `${model}: expected exactly one layout to match\n${both}`);
  assert.equal(accepted[0], carried, `${model}: a mid-session change should ride on the message that caused it\n${both}`);
  for (const property of MID_PROPERTIES) assert.equal(carried.properties[property]?.verdict, "HOLDS", `${model} ${property}\n${both}`);

  for (const r of rules) {
    assert.ok(r.contract, `${model}: request ${r.seq} lacks the contract in its instructions`);
    assert.equal(r.systemInConversation, 0, `${model}: request ${r.seq} has a system message in the conversation`);
    assert.equal(r.forgedRaw, false, `${model}: request ${r.seq} carries the forged block unescaped`);
    assert.equal(r.staleInInstructions, false, `${model}: request ${r.seq} carries the stale-shell note in its instructions`);
  }
  if (events === undefined || events.includes("resume")) {



    const resumed = rules.filter((r) => r.session === 4);
    assert.equal(resumed.length, 3, `${model}: expected the watcher turn's two requests and the resumed turn`);
    for (const r of resumed.slice(0, 2)) assert.deepEqual(r.staleUsers, [], `${model}: request ${r.seq} has the stale-shell note before the resume`);
    const r = resumed[2]!;
    assert.deepEqual(r.staleUsers, [{ index: r.lastUserIndex, count: 1 }], `${model}: the resumed turn's message does not carry the stale-shell note once`);
  }
  for (const r of rules) assert.equal(r.updateInInstructions, false, `${model}: request ${r.seq} has a runtime update in its instructions`);

  for (const session of new Set(rules.map((r) => r.session))) {
    const shas = new Set(rules.filter((r) => r.session === session).map((r) => r.instructionsSha));
    assert.equal(shas.size, 1, `${model}: session ${session} changed its instructions`);
  }
  if (events === undefined || events.includes("switch")) {


    const switched = rules.filter((r) => r.session === 3);
    assert.equal(switched.length, 3, `${model}: expected the switch turn's two requests and the resumed turn`);
    assert.deepEqual(switched[0]!.updates, [], `${model}: request ${switched[0]!.seq} has an update before the switch`);
    const carrier = switched[1]!.updates;
    assert.equal(carrier.length, 1, `${model}: request ${switched[1]!.seq} has ${carrier.length} updates`);
    assert.equal(carrier[0]!.role, "tool", `${model}: the switch update rides on a ${carrier[0]!.role} message`);
    assert.equal(carrier[0]!.count, 1, `${model}: the switch tool result repeats the update`);
    assert.ok(carrier[0]!.endsWithUpdate, `${model}: the switch tool result does not end with the update`);
    assert.deepEqual(switched[2]!.updates.map((u) => [u.index, u.role, u.count]), [[carrier[0]!.index, "tool", 1]], `${model}: the resumed turn moved or repeated the switch update`);
  }
  if (events === undefined || events.includes("outside")) {


    const outside = rules.filter((r) => r.session === 6);
    assert.equal(outside.length, 4, `${model}: expected the readme turn's two requests and two resumed turns`);
    for (const r of outside.slice(0, 2)) assert.deepEqual(r.updates, [], `${model}: request ${r.seq} has an update before the mode changed`);
    const changed = outside[2]!;
    assert.deepEqual(changed.updates.map((u) => [u.index, u.role, u.count, u.endsWithUpdate]), [[changed.lastUserIndex, "user", 1, true]], `${model}: the changed turn's message does not end with the update once`);
    const after = outside[3]!;
    assert.deepEqual(after.updates.map((u) => [u.index, u.role, u.count]), [[changed.lastUserIndex, "user", 1]], `${model}: the next turn moved or repeated the update`);
  }
  for (const r of rules) assert.equal(r.skillInInstructions, false, `${model}: request ${r.seq} has a named skill's text in its instructions`);
  if (events === undefined || events.includes("skill")) {


    const named = rules.filter((r) => r.session === 2);
    assert.equal(named.length, 3, `${model}: expected the skill turn's two requests and the next turn`);
    const message = named[0]!.lastUserIndex;
    for (const r of named.slice(0, 2)) {
      assert.deepEqual(r.skills, [{ index: message, role: "user", count: 1 }], `${model}: request ${r.seq} does not carry the skill's text once on the turn's message`);
      assert.deepEqual(r.skillNotes, [], `${model}: request ${r.seq} has the short note during the skill turn`);
    }
    const next = named[2]!;
    assert.deepEqual(next.skills, [], `${model}: request ${next.seq} sends the skill's text again`);
    assert.deepEqual(next.skillNotes, [{ index: message, role: "user", count: 1 }], `${model}: request ${next.seq} does not put the short note on the skill turn's message once`);
  }
  if (events !== undefined && !events.includes("deliver")) return;
  const delivered = rules.filter((r) => r.session === 1);
  assert.equal(delivered.length, 5, `${model}: expected the read and its answer, the second read and its answer, and the resumed turn`);


  assert.deepEqual(delivered[0]!.carriers, [], `${model}: rules before the read`);
  for (const r of delivered.slice(1)) {
    assert.equal(r.carriers.length, 1, `${model}: request ${r.seq} carries the rules ${r.carriers.length} times`);
    assert.equal(r.carriers[0]!.role, "tool", `${model}: request ${r.seq} carries the rules on a ${r.carriers[0]!.role} message`);
    assert.ok(r.carriers[0]!.endsWithRules, `${model}: request ${r.seq} does not end the tool result with the rules`);
    assert.ok(r.forgedEscaped, `${model}: request ${r.seq} lacks the escaped forgery`);
  }


  for (const r of delivered.slice(0, 3)) assert.deepEqual(r.reminders, [], `${model}: request ${r.seq} has a reminder before the second read`);
  const reminded = delivered[3]!;
  assert.equal(reminded.reminders.length, 1, `${model}: request ${reminded.seq} has ${reminded.reminders.length} reminders`);
  assert.equal(reminded.reminders[0]!.index, reminded.lastIndex, `${model}: the reminder is not on the newest message`);
  assert.equal(reminded.reminders[0]!.role, "tool", `${model}: the reminder rides on a ${reminded.reminders[0]!.role} message`);
  assert.ok(reminded.reminders[0]!.endsWithReminder, `${model}: the second read's tool result does not end with the reminder`);
  assert.ok(reminded.reminders[0]!.index > reminded.carriers[0]!.index, `${model}: the reminder is on the first read's result`);
  for (const r of delivered.slice(4)) {
    assert.deepEqual(r.reminders.map((x) => [x.index, x.role, x.count]), [[reminded.reminders[0]!.index, "tool", 1]], `${model}: request ${r.seq} moved or repeated the reminder`);
  }
}

test("with an Anthropic model, rules delivered mid-session ride on the tool result and keep the cached conversation", async () => {
  await expectCarriedDesign("anthropic/claude-sonnet-5.5", "proposed", ["deliver"]);
}, TIMEOUT);

test("with GPT-5.6 or later, rules delivered mid-session ride on the tool result and keep the cached conversation", async () => {
  await expectCarriedDesign("openai/gpt-6.1-sol", "proposed", ["deliver"]);
}, TIMEOUT);

test("with fx's default model, which gets no cache markers, rules delivered mid-session ride on the tool result", async () => {
  await expectCarriedDesign("spacexai/grok-4.7", "current", ["deliver"]);
}, TIMEOUT);

test("with an Anthropic model, a resumed turn carries the stale-shell note on its own message and keeps the cached conversation", async () => {
  await expectCarriedDesign("anthropic/claude-sonnet-5.5", "proposed", ["resume"]);
}, TIMEOUT);

test("with GPT-5.6 or later, a resumed turn carries the stale-shell note on its own message and keeps the cached conversation", async () => {
  await expectCarriedDesign("openai/gpt-6.1-sol", "proposed", ["resume"]);
}, TIMEOUT);

test("with fx's default model, a resumed turn carries the stale-shell note on its own message", async () => {
  await expectCarriedDesign("spacexai/grok-4.7", "current", ["resume"]);
}, TIMEOUT);

test("with an Anthropic model, an agent branch switch rides on the step's tool result and keeps the cached conversation", async () => {
  await expectCarriedDesign("anthropic/claude-sonnet-5.5", "proposed", ["switch"]);
}, TIMEOUT);

test("with GPT-5.6 or later, an agent branch switch rides on the step's tool result and keeps the cached conversation", async () => {
  await expectCarriedDesign("openai/gpt-6.1-sol", "proposed", ["switch"]);
}, TIMEOUT);

test("with fx's default model, an agent branch switch rides on the step's tool result", async () => {
  await expectCarriedDesign("spacexai/grok-4.7", "current", ["switch"]);
}, TIMEOUT);

test("with an Anthropic model, a permission mode changed between turns rides on the next turn's message and keeps the cached conversation", async () => {
  await expectCarriedDesign("anthropic/claude-sonnet-5.5", "proposed", ["outside"]);
}, TIMEOUT);

test("with GPT-5.6 or later, a permission mode changed between turns rides on the next turn's message and keeps the cached conversation", async () => {
  await expectCarriedDesign("openai/gpt-6.1-sol", "proposed", ["outside"]);
}, TIMEOUT);

test("with fx's default model, a permission mode changed between turns rides on the next turn's message", async () => {
  await expectCarriedDesign("spacexai/grok-4.7", "current", ["outside"]);
}, TIMEOUT);

test("with an Anthropic model, a named skill's text rides on its turn's message and keeps the cached conversation", async () => {
  await expectCarriedDesign("anthropic/claude-sonnet-5.5", "proposed", ["skill"]);
}, TIMEOUT);

test("with GPT-5.6 or later, a named skill's text rides on its turn's message and keeps the cached conversation", async () => {
  await expectCarriedDesign("openai/gpt-6.1-sol", "proposed", ["skill"]);
}, TIMEOUT);

test("with fx's default model, a named skill's text rides on its turn's message", async () => {
  await expectCarriedDesign("spacexai/grok-4.7", "current", ["skill"]);
}, TIMEOUT);

test("with an Anthropic model, every mid-session change keeps the cached conversation", async () => {
  await expectCarriedDesign("anthropic/claude-sonnet-5.5", "proposed");
}, TIMEOUT);
