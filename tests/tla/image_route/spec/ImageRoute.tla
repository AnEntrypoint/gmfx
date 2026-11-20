----------------------------- MODULE ImageRoute -----------------------------



























EXTENDS Naturals, Sequences

Supports == {"unknown", "non_native", "native"}
Routes == {"native", "fallback", "unavailable"}
Modes == {"unavailable", "optional", "required"}
ToolImages == {"none", "attached", "withheld_fallback", "withheld_dead_end", "withheld_unknown"}
Reasons == {"capability_unknown", "no_native_image"}

Views == [kind: {"listed"}, vision: BOOLEAN, file_input: BOOLEAN]
         \cup [kind: {"missing", "down"}, vision: {FALSE}, file_input: {FALSE}]

Requests == {r \in [user_images: BOOLEAN, earlier_images: BOOLEAN, pending_images: BOOLEAN,
                    tool_images: BOOLEAN, fallback: BOOLEAN, catalog_down: BOOLEAN] :
               r.pending_images => r.user_images}

Sends == [kind: {"send"}, route: Routes, mode: Modes, tool_images: ToolImages, earlier_images: ToolImages]
Effects == [kind: {"resolve", "notify"}] \cup Sends \cup [kind: {"fail"}, reason: Reasons]


Pending == {<<>>} \cup {<<r>> : r \in Requests}

Acts == [name: {"Init", "Crash"}]
        \cup [name: {"TurnStarted"}, view: Views]
        \cup [name: {"RequestReady"}, req: Requests]
        \cup [name: {"CapabilitiesResolved"}, view: Views, answered: Pending]

VARIABLES support, resolved, notified, pending, out, act

vars == <<support, resolved, notified, pending, out, act>>


Derive(v) == IF v.kind = "listed" THEN (IF v.vision THEN "native" ELSE "non_native") ELSE "unknown"



Held(s, route) == CASE s = "native" -> "attached"
                    [] s = "unknown" -> "withheld_unknown"
                    [] OTHER -> IF route = "fallback" THEN "withheld_fallback" ELSE "withheld_dead_end"


Decide(s, r) ==
    LET route == CASE s = "native" -> "native"
                   [] s = "unknown" -> "unavailable"
                   [] OTHER -> IF r.fallback THEN "fallback" ELSE "unavailable"
        mode == IF route # "fallback" THEN "unavailable"
                ELSE IF r.pending_images THEN "required" ELSE "optional"
        tool == IF ~r.tool_images THEN "none" ELSE Held(s, route)
        earlier == IF ~r.earlier_images THEN "none" ELSE Held(s, route)
    IN [kind |-> "send", route |-> route, mode |-> mode, tool_images |-> tool, earlier_images |-> earlier]


WithholdsUnknown(e) == e.tool_images = "withheld_unknown" \/ e.earlier_images = "withheld_unknown"

Unroutable(s, r) == r.user_images /\ Decide(s, r).route = "unavailable"
Notifies(s, r, n) == ~Unroutable(s, r) /\ WithholdsUnknown(Decide(s, r)) /\ r.catalog_down /\ ~n


DecideOut(s, r, n) ==
    IF Unroutable(s, r)
    THEN <<[kind |-> "fail", reason |-> IF s = "unknown" THEN "capability_unknown" ELSE "no_native_image"]>>
    ELSE IF Notifies(s, r, n) THEN <<[kind |-> "notify"], Decide(s, r)>>
    ELSE <<Decide(s, r)>>

DecideNotified(s, r, n) == n \/ Notifies(s, r, n)

HasImages(r) == r.user_images \/ r.earlier_images \/ r.tool_images

NeedsResolve(r) == support = "unknown" /\ ~resolved /\ HasImages(r)

Init ==
    /\ support = "unknown"
    /\ resolved = FALSE
    /\ notified = FALSE
    /\ pending = <<>>
    /\ out = <<>>
    /\ act = [name |-> "Init"]

TurnStarted(v) ==
    /\ act' = [name |-> "TurnStarted", view |-> v]
    /\ support' = Derive(v)
    /\ resolved' = FALSE
    /\ notified' = FALSE
    /\ pending' = <<>>
    /\ out' = <<>>

RequestReady(r) ==
    /\ act' = [name |-> "RequestReady", req |-> r]
    /\ IF pending # <<>>
       THEN pending' = <<r>> /\ out' = <<>> /\ UNCHANGED <<support, resolved, notified>>
       ELSE IF NeedsResolve(r)
       THEN /\ resolved' = TRUE
            /\ pending' = <<r>>
            /\ out' = <<[kind |-> "resolve"]>>
            /\ UNCHANGED <<support, notified>>
       ELSE /\ out' = DecideOut(support, r, notified)
            /\ notified' = DecideNotified(support, r, notified)
            /\ UNCHANGED <<support, resolved, pending>>

CapabilitiesResolved(v) ==
    /\ act' = [name |-> "CapabilitiesResolved", view |-> v, answered |-> pending]
    /\ IF pending = <<>>
       THEN out' = <<>> /\ UNCHANGED <<support, resolved, notified, pending>>
       ELSE LET s == Derive(v) IN
            /\ support' = s
            /\ pending' = <<>>
            /\ out' = DecideOut(s, Head(pending), notified)
            /\ notified' = DecideNotified(s, Head(pending), notified)
            /\ UNCHANGED resolved


Crash ==
    /\ act' = [name |-> "Crash"]
    /\ support' = "unknown"
    /\ resolved' = FALSE
    /\ notified' = FALSE
    /\ pending' = <<>>
    /\ out' = <<>>

Reply == pending # <<>> /\ \E v \in Views : CapabilitiesResolved(v)

Next ==
    \/ \E v \in Views : TurnStarted(v)
    \/ \E r \in Requests : RequestReady(r)
    \/ \E v \in Views : CapabilitiesResolved(v)
    \/ Crash


Spec == Init /\ [][Next]_vars /\ WF_vars(Reply)

-----------------------------------------------------------------------------


HasKind(k) == \E i \in 1..Len(out) : out[i].kind = k
SendsOut == {out[i] : i \in {j \in 1..Len(out) : out[j].kind = "send"}}
FailsOut == {out[i] : i \in {j \in 1..Len(out) : out[j].kind = "fail"}}

Decided == IF act.name = "RequestReady" THEN <<act.req>>
           ELSE IF act.name = "CapabilitiesResolved" THEN act.answered
           ELSE <<>>

TypeOK ==
    /\ support \in Supports
    /\ resolved \in BOOLEAN
    /\ notified \in BOOLEAN
    /\ pending \in Pending
    /\ Len(out) <= 2 /\ \A i \in 1..Len(out) : out[i] \in Effects
    /\ act \in Acts


Bounded ==
    /\ Len(pending) <= 1
    /\ Len(out) <= 2
    /\ Len(out) = 2 => (out[1].kind = "notify" /\ out[2].kind = "send")




VisionImpliesNative ==
    (act.name = "TurnStarted" \/ (act.name = "CapabilitiesResolved" /\ act.answered # <<>>)) =>
        /\ (act.view.kind = "listed" /\ act.view.vision) => support = "native"
        /\ (act.view.kind = "listed" /\ ~act.view.vision) => support = "non_native"
        /\ act.view.kind # "listed" => support = "unknown"


UnknownNeverInline ==
    \A e \in SendsOut : (e.tool_images = "attached" \/ e.earlier_images = "attached") => support = "native"



OneSnapshot ==
    \A e \in SendsOut :
        /\ (e.route = "native") <=> (support = "native")
        /\ \A h \in {e.tool_images, e.earlier_images} :
              /\ h = "withheld_unknown" => support = "unknown"
              /\ h = "withheld_fallback" => (support = "non_native" /\ e.route = "fallback")
              /\ h = "withheld_dead_end" => (support = "non_native" /\ e.route = "unavailable")


RouteModeCoherent == \A e \in SendsOut : (e.route = "fallback") <=> (e.mode # "unavailable")


NativeExcludesFallback == \A e \in SendsOut : support = "native" => (e.route = "native" /\ e.mode = "unavailable")



NoSilentWithhold ==
    \A e \in SendsOut :
        /\ Decided # <<>>
        /\ Head(Decided).tool_images <=> e.tool_images # "none"
        /\ Head(Decided).earlier_images <=> e.earlier_images # "none"


RequiredWhenPending ==
    \A e \in SendsOut : e.route = "fallback" => ((e.mode = "required") <=> Head(Decided).pending_images)



FailExactlyWhenUnroutable ==
    /\ \A e \in FailsOut :
          /\ Decided # <<>>
          /\ Head(Decided).user_images
          /\ (support = "unknown" \/ (support = "non_native" /\ ~Head(Decided).fallback))
          /\ e.reason = IF support = "unknown" THEN "capability_unknown" ELSE "no_native_image"
    /\ \A e \in SendsOut : Head(Decided).user_images => e.route # "unavailable"


ResolveOnlyWhenNeeded ==
    HasKind("resolve") =>
        /\ act.name = "RequestReady"
        /\ support = "unknown"
        /\ HasImages(act.req)
        /\ pending = <<act.req>>



AskedBeforeUnknown ==
    /\ \A e \in SendsOut : WithholdsUnknown(e) => resolved
    /\ \A e \in FailsOut : e.reason = "capability_unknown" => resolved


NotifyOnlyWhenDown ==
    HasKind("notify") =>
        /\ \E e \in SendsOut : WithholdsUnknown(e)
        /\ Head(Decided).catalog_down


DecideOnlyWhenReady ==
    (HasKind("send") \/ HasKind("fail")) =>
        /\ pending = <<>>
        /\ (act.name = "RequestReady" \/ (act.name = "CapabilitiesResolved" /\ act.answered # <<>>))


TurnResets ==
    act.name \in {"TurnStarted", "Crash"} => (~resolved /\ ~notified /\ pending = <<>> /\ out = <<>>)


PendingWaitsForReply ==
    pending # <<>> => (resolved /\ support = "unknown" /\ (out = <<>> \/ out = <<[kind |-> "resolve"]>>))


ResolveOncePerTurn == [][(\E i \in 1..Len(out') : out'[i].kind = "resolve") => ~resolved]_vars


NotifyOncePerTurn == [][(\E i \in 1..Len(out') : out'[i].kind = "notify") => ~notified]_vars


DuplicateRequestIsQuiet == [][(act'.name = "RequestReady" /\ pending # <<>>) => out' = <<>>]_vars


StaleReplyIsQuiet ==
    [][(act'.name = "CapabilitiesResolved" /\ pending = <<>>) =>
          (out' = <<>> /\ UNCHANGED <<support, resolved, notified, pending>>)]_vars


Answered == (pending # <<>>) ~> (pending = <<>>)
=============================================================================
