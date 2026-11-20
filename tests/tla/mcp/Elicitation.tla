---- MODULE Elicitation ----



















EXTENDS Naturals, FiniteSets

CONSTANTS Reqs, MaxPending

ASSUME Reqs \subseteq Nat /\ MaxPending \in Nat \ {0}

Modes == {"form", "url"}
Origins == {"request", "required"}
Actions == {"accept", "decline", "cancel"}
Phases == {"idle", "shown", "waiting", "done"}

Answers == {"none", "error", "content", "accept", "decline", "cancel"}

VARIABLES
    phase,
    origin,
    mode,
    eid,
    sent,
    declared,
    early,

    sends,
    shownEver,
    decided,
    withdrawn,
    told,
    invalidSent

vars == <<phase, origin, mode, eid, sent, declared, early, sends, shownEver, decided, withdrawn, told, invalidSent>>

Pending == {r \in Reqs: phase[r] \in {"shown", "waiting"}}

TypeOK ==
    /\ phase \in [Reqs -> Phases]
    /\ origin \in [Reqs -> Origins]
    /\ mode \in [Reqs -> Modes]
    /\ eid \in [Reqs -> BOOLEAN]
    /\ sent \in [Reqs -> Answers]
    /\ declared \in SUBSET Modes
    /\ early \in [Reqs -> BOOLEAN]
    /\ sends \in [Reqs -> 0..2]
    /\ shownEver \in [Reqs -> BOOLEAN]
    /\ decided \in [Reqs -> Actions \cup {"none"}]
    /\ withdrawn \in [Reqs -> BOOLEAN]
    /\ told \in [Reqs -> 0..2]
    /\ invalidSent \in BOOLEAN

Init ==
    /\ phase = [r \in Reqs |-> "idle"]
    /\ origin = [r \in Reqs |-> "request"]
    /\ mode = [r \in Reqs |-> "form"]
    /\ eid = [r \in Reqs |-> FALSE]
    /\ sent = [r \in Reqs |-> "none"]
    /\ declared \in SUBSET Modes
    /\ early = [r \in Reqs |-> FALSE]
    /\ sends = [r \in Reqs |-> 0]
    /\ shownEver = [r \in Reqs |-> FALSE]
    /\ decided = [r \in Reqs |-> "none"]
    /\ withdrawn = [r \in Reqs |-> FALSE]
    /\ told = [r \in Reqs |-> 0]
    /\ invalidSent = FALSE



Ask(r, o, m, e, readable) ==
    /\ phase[r] = "idle"
    /\ o = "required" => m = "url" /\ e
    /\ m = "form" => ~e
    /\ origin' = [origin EXCEPT ![r] = o]
    /\ mode' = [mode EXCEPT ![r] = m]
    /\ eid' = [eid EXCEPT ![r] = e]
    /\ IF readable /\ m \in declared /\ Cardinality(Pending) < MaxPending
         THEN /\ phase' = [phase EXCEPT ![r] = "shown"]
              /\ shownEver' = [shownEver EXCEPT ![r] = TRUE]
              /\ UNCHANGED <<sent, sends>>
         ELSE /\ phase' = [phase EXCEPT ![r] = "done"]
              /\ UNCHANGED shownEver
              /\ IF o = "request"
                   THEN /\ sent' = [sent EXCEPT ![r] = "error"]
                        /\ sends' = [sends EXCEPT ![r] = @ + 1]
                   ELSE UNCHANGED <<sent, sends>>
    /\ UNCHANGED <<declared, early, decided, withdrawn, told, invalidSent>>





Answer(r, a, valid) ==
    /\ phase[r] = "shown"
    /\ IF a = "accept" /\ mode[r] = "form" /\ ~valid
         THEN UNCHANGED vars
         ELSE /\ decided' = [decided EXCEPT ![r] = a]
              /\ IF origin[r] = "request"
                   THEN /\ sent' = [sent EXCEPT ![r] = IF a = "accept" /\ mode[r] = "form" THEN "content" ELSE a]
                        /\ sends' = [sends EXCEPT ![r] = @ + 1]
                   ELSE UNCHANGED <<sent, sends>>
              /\ phase' = [phase EXCEPT ![r] = IF a = "accept" /\ mode[r] = "url" /\ eid[r] /\ ~early[r] THEN "waiting" ELSE "done"]
              /\ told' = [told EXCEPT ![r] = IF a = "accept" /\ mode[r] = "url" /\ eid[r] /\ early[r] THEN @ + 1 ELSE @]
              /\ invalidSent' = (invalidSent \/ (a = "accept" /\ mode[r] = "form" /\ ~valid))
              /\ UNCHANGED <<origin, mode, eid, declared, early, shownEver, withdrawn>>



ServerCancel(r) ==
    IF phase[r] = "shown" /\ origin[r] = "request"
      THEN /\ phase' = [phase EXCEPT ![r] = "done"]
           /\ withdrawn' = [withdrawn EXCEPT ![r] = TRUE]
           /\ UNCHANGED <<origin, mode, eid, sent, declared, early, sends, shownEver, decided, told, invalidSent>>
      ELSE UNCHANGED vars




SessionEnd ==
    /\ Pending # {}
    /\ phase' = [r \in Reqs |-> IF r \in Pending THEN "done" ELSE phase[r]]
    /\ withdrawn' = [r \in Reqs |-> withdrawn[r] \/ phase[r] = "shown"]
    /\ UNCHANGED <<origin, mode, eid, sent, declared, early, sends, shownEver, decided, told, invalidSent>>





Complete(r) ==
    CASE phase[r] = "waiting" ->
           /\ phase' = [phase EXCEPT ![r] = "done"]
           /\ told' = [told EXCEPT ![r] = @ + 1]
           /\ UNCHANGED <<origin, mode, eid, sent, declared, early, sends, shownEver, decided, withdrawn, invalidSent>>
      [] phase[r] = "shown" /\ mode[r] = "url" /\ eid[r] ->
           /\ early' = [early EXCEPT ![r] = TRUE]
           /\ UNCHANGED <<phase, origin, mode, eid, sent, declared, sends, shownEver, decided, withdrawn, told, invalidSent>>
      [] OTHER -> UNCHANGED vars

Next ==
    \E r \in Reqs:
        \/ \E o \in Origins, m \in Modes, e, readable \in BOOLEAN: Ask(r, o, m, e, readable)
        \/ \E a \in Actions, valid \in BOOLEAN: Answer(r, a, valid)
        \/ ServerCancel(r)
        \/ Complete(r)
        \/ SessionEnd


Spec == Init /\ [][Next]_vars /\ \A r \in Reqs: WF_vars(\E a \in Actions: Answer(r, a, TRUE))




AnsweredOnce == \A r \in Reqs: sends[r] <= 1



ModeGate ==
    \A r \in Reqs:
        /\ shownEver[r] => mode[r] \in declared
        /\ (phase[r] = "done" /\ origin[r] = "request" /\ mode[r] \notin declared) => sent[r] = "error"


HostDecides ==
    \A r \in Reqs: sent[r] \in Actions \cup {"content"} => decided[r] = IF sent[r] = "content" THEN "accept" ELSE sent[r]


ContentGate ==
    \A r \in Reqs:
        /\ sent[r] = "content" => mode[r] = "form"
        /\ sent[r] = "accept" => mode[r] = "url"


ValidOnly == ~invalidSent


NothingAfterWithdraw == \A r \in Reqs: withdrawn[r] => sent[r] = "none" /\ decided[r] = "none"


CompleteOnce == \A r \in Reqs: told[r] <= 1
CompleteOnlyAccepted == \A r \in Reqs: told[r] = 1 => decided[r] = "accept" /\ mode[r] = "url" /\ eid[r]

EarlyCompletionTold == \A r \in Reqs: early[r] /\ decided[r] = "accept" => told[r] = 1


RequiredUnanswered == \A r \in Reqs: origin[r] = "required" => sends[r] = 0


Bounded == Cardinality(Pending) <= MaxPending


EveryElicitationEnds == \A r \in Reqs: phase[r] = "shown" ~> phase[r] \in {"waiting", "done"}
====
