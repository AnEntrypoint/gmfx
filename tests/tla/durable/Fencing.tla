------------------------------ MODULE Fencing ------------------------------














EXTENDS Naturals, Sequences

CONSTANTS Procs, MaxLen, MaxCrashes

VARIABLES
    log,
    status,
    view,
    pc,
    runs,
    actedFenced,
    crashes

vars == <<log, status, view, pc, runs, actedFenced, crashes>>

Kinds == {"step", "intent", "result", "interrupted"}

Entry == [by : Procs, kind : Kinds]

HasKind(s, k) == \E i \in 1..Len(s) : s[i].kind = k

Resolved(s) == HasKind(s, "result") \/ HasKind(s, "interrupted")


Known(p) == SubSeq(log, 1, view[p])

CountKind(k) == Len(SelectSeq(log, LAMBDA e : e.kind = k))

TypeOK ==
    /\ log \in Seq(Entry)
    /\ Len(log) <= MaxLen
    /\ status \in [Procs -> {"down", "active", "fenced"}]
    /\ view \in [Procs -> 0..MaxLen]
    /\ pc \in [Procs -> {"idle", "may_run", "ran"}]
    /\ runs \in 0..2
    /\ actedFenced \in BOOLEAN
    /\ crashes \in 0..MaxCrashes

Init ==
    /\ log = <<>>
    /\ status = [p \in Procs |-> "down"]
    /\ view = [p \in Procs |-> 0]
    /\ pc = [p \in Procs |-> "idle"]
    /\ runs = 0
    /\ actedFenced = FALSE
    /\ crashes = 0



CasAppend(p, k, next) ==
    IF Len(log) = view[p]
    THEN /\ log' = Append(log, [by |-> p, kind |-> k])
         /\ view' = [view EXCEPT ![p] = @ + 1]
         /\ pc' = [pc EXCEPT ![p] = next]
         /\ UNCHANGED status
    ELSE /\ status' = [status EXCEPT ![p] = "fenced"]
         /\ UNCHANGED <<log, view, pc>>


Load(p) ==
    /\ status[p] \in {"down", "fenced"}
    /\ status' = [status EXCEPT ![p] = "active"]
    /\ view' = [view EXCEPT ![p] = Len(log)]
    /\ pc' = [pc EXCEPT ![p] = "idle"]
    /\ UNCHANGED <<log, runs, actedFenced, crashes>>


Step(p) ==
    /\ status[p] = "active"
    /\ Len(log) < MaxLen
    /\ CasAppend(p, "step", pc[p])
    /\ UNCHANGED <<runs, actedFenced, crashes>>


Intent(p) ==
    /\ status[p] = "active"
    /\ pc[p] = "idle"
    /\ ~HasKind(Known(p), "intent")
    /\ Len(log) < MaxLen
    /\ CasAppend(p, "intent", "may_run")
    /\ UNCHANGED <<runs, actedFenced, crashes>>


Run(p) ==
    /\ status[p] = "active"
    /\ pc[p] = "may_run"
    /\ runs < 2
    /\ runs' = runs + 1
    /\ actedFenced' = (actedFenced \/ status[p] # "active")
    /\ pc' = [pc EXCEPT ![p] = "ran"]
    /\ UNCHANGED <<log, status, view, crashes>>


Result(p) ==
    /\ status[p] = "active"
    /\ pc[p] = "ran"
    /\ Len(log) < MaxLen
    /\ CasAppend(p, "result", "idle")
    /\ UNCHANGED <<runs, actedFenced, crashes>>


Recover(p) ==
    /\ status[p] = "active"
    /\ pc[p] = "idle"
    /\ HasKind(Known(p), "intent")
    /\ ~Resolved(Known(p))
    /\ Len(log) < MaxLen
    /\ CasAppend(p, "interrupted", "idle")
    /\ UNCHANGED <<runs, actedFenced, crashes>>


Crash(p) ==
    /\ status[p] # "down"
    /\ crashes < MaxCrashes
    /\ status' = [status EXCEPT ![p] = "down"]
    /\ pc' = [pc EXCEPT ![p] = "idle"]
    /\ crashes' = crashes + 1
    /\ UNCHANGED <<log, view, runs, actedFenced>>

Next ==
    \E p \in Procs :
        \/ Load(p)
        \/ Step(p)
        \/ Intent(p)
        \/ Run(p)
        \/ Result(p)
        \/ Recover(p)
        \/ Crash(p)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------



AtMostOneRun == runs <= 1


RunHasDurableIntent == runs > 0 => HasKind(log, "intent")


OneIntent == CountKind("intent") <= 1
OneOutcome == CountKind("result") + CountKind("interrupted") <= 1


OutcomeFollowsIntent ==
    \A i \in 1..Len(log) :
        log[i].kind \in {"result", "interrupted"} =>
            \E j \in 1..(i - 1) : log[j].kind = "intent"


ResultByRunner ==
    \A i, j \in 1..Len(log) :
        log[i].kind = "intent" /\ log[j].kind = "result" => log[i].by = log[j].by


FencedNeverActs == ~actedFenced

=============================================================================
