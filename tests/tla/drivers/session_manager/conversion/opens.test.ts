



import { expect } from "bun:test";
import assert from "node:assert/strict";
import { cpSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  compareContinuations, convertAll, crashAtRename, fakeGatewayFinalText, familyReplies, observer, openVia, plainReplies,
  rememberInV1, requireAccepted, scenario, VIAS, waitUntil, type Fixture,
} from "./driver";



scenario("control: an id neither store holds is reported missing", async f => {
  plainReplies(f);
  const o = observer(f, "neverCreated1");
  await o.observe("list");
  await o.observe("open", await openVia(f, "neverCreated1", "ask"));
  const result = await requireAccepted(o, "control");
  expect(result.matched).toBe(2);

  o.observations[1].ans = "opened";
  expect((await o.check("control-planted")).verdict).toBe("REJECTED");
});

scenario("control: the content oracle sees no difference between two v1 continuations", async f => {
  familyReplies(f);
  const id = (await f.v1Ask(["CONV_FAMILY"])).session_id;
  const snapshot = join(f.root, "snapshot");
  cpSync(f.home, snapshot, { recursive: true });
  const same = await compareContinuations(f, snapshot, id, true, false, false);
  expect(same).toEqual({ root: true, child: true });
});

for (const via of VIAS) {
  scenario(`an open through ${via} converts a plain v1 session`, async f => {
    plainReplies(f);
    const id = (await f.v1Ask(["CONV_FIRST"])).session_id;
    const o = observer(f, id);
    await o.observe("create");
    if (via === "continue") {

      await rememberInV1(f, id);
      await o.observe("write");
    }
    const snapshot = join(f.root, "snapshot");
    cpSync(f.home, snapshot, { recursive: true });
    await o.observe("list");
    plainReplies(f);
    await o.observe("open", await openVia(f, id, via));
    await o.observe("list");
    Object.assign(o.content, await compareContinuations(f, snapshot, id, false, false, true));
    await requireAccepted(o, `open-${via}`);
    if (via === "ask") {


      const before = JSON.stringify(o.observations);
      o.content.root = false;
      expect((await o.check("open-planted")).verdict).toBe("REJECTED");
      o.content.root = true;
      o.content.carried.planted = false;
      expect((await o.check("carried-planted")).verdict).toBe("REJECTED");
      expect(JSON.stringify(o.observations)).toBe(before);
    }
  });
}

scenario("a family converts together, and the model sees the same root and child", async f => {
  familyReplies(f);
  const id = (await f.v1Ask(["CONV_FAMILY"])).session_id;
  const o = observer(f, id);
  await o.observe("create");
  assert(o.childId, "the v1 family has no child to convert");
  const snapshot = join(f.root, "snapshot");
  cpSync(f.home, snapshot, { recursive: true });
  familyReplies(f);
  await o.observe("open", await openVia(f, id, "ask"));
  await o.observe("list");
  Object.assign(o.content, await compareContinuations(f, snapshot, id, true, false, true));
  await requireAccepted(o, "family");
});

scenario("busy while an older build holds the session, opened once it is gone", async f => {
  plainReplies(f);
  const id = (await f.v1Ask(["CONV_FIRST"])).session_id;
  const o = observer(f, id);
  await o.observe("create");
  f.setRespond(body => body.includes("CONV_HOLD")
    ? new Response(new ReadableStream({ start(c) { c.enqueue(new TextEncoder().encode(": held\n\n")); } }), { headers: { "content-type": "text/event-stream" } })
    : fakeGatewayFinalText("CONV_NEXT_ANSWER"));
  const holder = f.start(false, ["ask", "--json", "--auto", "--resume-id", id, "CONV_HOLD"], 120_000);
  assert(await waitUntil(() => f.gateway.requests.some((r: any) => r.body.includes("CONV_HOLD")), 15_000),
    "Owned fault boundary not reached: the older build never sent its held request");
  o.hold([id]);
  await o.observe("hold");
  await o.observe("open", await openVia(f, id, "ask"));
  holder.child.kill("SIGKILL");
  expect((await holder.finished).signal).toBe("SIGKILL");
  o.hold([]);
  await o.observe("release");
  await o.observe("open", await openVia(f, id, "ask"));
  await requireAccepted(o, "busy");
});

scenario("an unreadable v1 session is refused, converted nowhere and left as it was", async f => {
  plainReplies(f);
  const id = (await f.v1Ask(["CONV_FIRST"])).session_id;
  const o = observer(f, id);
  await o.observe("create");
  writeFileSync(join(f.v1Root, id, "session.json"), "{ not json");
  await o.damage(id);
  const before = readFileSync(join(f.v1Root, id, "session.json"));
  await o.observe("damage");
  await o.observe("open", await openVia(f, id, "ask"));
  expect(readFileSync(join(f.v1Root, id, "session.json")).equals(before)).toBe(true);
  expect(existsSync(join(f.v2Root, id))).toBe(false);
  await requireAccepted(o, "unreadable");
});


async function openRefusingDeletes(f: Fixture, o: ReturnType<typeof observer>, id: string, members: string[]) {
  const fault = f.faultPaths("refuse", members.map(f.v1Path));
  let answer;
  try { answer = await openVia(f, id, "ask"); } finally { fault.stop(); }
  writeFileSync(join(f.root, "fault-boundary.json"), JSON.stringify({ reached: fault.reached(), answer }, null, 2));
  assert(fault.reached(), `Owned fault boundary not reached: the open (${answer}) never tried to delete a v1 folder`);
  await o.observe("open", answer, true);
}

scenario("a refused delete leaves the family's v1 folders, and the next open deletes them", async f => {
  familyReplies(f);
  const id = (await f.v1Ask(["CONV_FAMILY"])).session_id;
  const o = observer(f, id);
  await o.observe("create");
  assert(o.childId, "the v1 family has no child to convert");
  await openRefusingDeletes(f, o, id, o.members());
  await o.observe("open", await openVia(f, id, "ask"));
  await requireAccepted(o, "refused-delete");
});

scenario("a leftover an older build changed is kept, and never reaches the v2 copy", async f => {
  plainReplies(f);
  const id = (await f.v1Ask(["CONV_FIRST"])).session_id;
  const o = observer(f, id);
  await o.observe("create");
  await openRefusingDeletes(f, o, id, [id]);
  await f.v1Ask(["--resume-id", id, "CONV_MORE"]);
  await o.observe("write");
  await o.observe("open", await openVia(f, id, "ask"));
  await requireAccepted(o, "changed-leftover");
});

scenario("a crash after the children land and before the root leaves orphans the next open sweeps", async f => {
  familyReplies(f);
  const id = (await f.v1Ask(["CONV_FAMILY"])).session_id;
  const o = observer(f, id);
  await o.observe("create");
  assert(o.childId, "the v1 family has no child to convert");
  await crashAtRename(f, o, id, f.stagingPath(id));
  familyReplies(f);
  await o.observe("open", await openVia(f, id, "ask"));
  await requireAccepted(o, "crash-before-root");
});

scenario("a crash after publishing and before the v1 delete leaves a leftover the next open deletes", async f => {
  familyReplies(f);
  const id = (await f.v1Ask(["CONV_FAMILY"])).session_id;
  const o = observer(f, id);
  await o.observe("create");
  assert(o.childId, "the v1 family has no child to convert");
  await crashAtRename(f, o, id, f.v1Path(id));
  familyReplies(f);
  await o.observe("open", await openVia(f, id, "ask"));
  await requireAccepted(o, "crash-before-delete");
});

scenario("a crash mid-conversion leaves only leftovers, swept by the next open", async f => {
  plainReplies(f);
  const id = (await f.v1Ask(["CONV_FIRST"])).session_id;
  const o = observer(f, id);
  await o.observe("create");

  await crashAtRename(f, o, id, f.stagingPath(id));
  await o.observe("open", await openVia(f, id, "ask"));
  await requireAccepted(o, "crash");
});

scenario("fx sessions convert converts what was never opened", async f => {
  plainReplies(f);
  const id = (await f.v1Ask(["CONV_FIRST"])).session_id;
  const o = observer(f, id);
  await o.observe("create");
  await o.observe("all", (await convertAll(f)).answer(id));
  await o.observe("open", await openVia(f, id, "ask"));
  await o.observe("list");
  await requireAccepted(o, "convert-all");
});
