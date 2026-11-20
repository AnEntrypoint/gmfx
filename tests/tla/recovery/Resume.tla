------------------------------- MODULE Resume -------------------------------















































EXTENDS Naturals, FiniteSets

CONSTANTS
    Policy,
    MaxReq,
    MaxFaults,
    Bug

Bugs == {"none", "no_closing", "no_clear", "send_before_save",
         "reset_on_resume", "resume_answered", "resume_cancelled",
         "ignore_age", "no_lock"}

Procs == {1, 2}
Reqs  == 1..MaxReq

ASSUME /\ Policy \in {"today", "proposed"}
       /\ MaxReq \in Nat \ {0} /\ MaxFaults \in Nat
       /\ Bug \in Bugs
       /\ Bug # "none" => Policy = "proposed"

CrashLoopAfter == 2

Min(a, b) == IF a < b THEN a ELSE b



Days == 0..1




RecPhases == {"none", "sending", "waiting", "need"}
Needs     == {"none", "crash", "old", "other"}
Records   == [ph: RecPhases, clean: BOOLEAN, deaths: 0..CrashLoopAfter,
              need: Needs]
NoRec == [ph |-> "none", clean |-> FALSE, deaths |-> 0, need |-> "none"]


TurnEnds == {"open", "done", "cancel", "crash"}



Works == {"none", "tools", "final"}
Turns == [req: 0..MaxReq, st: TurnEnds, rec: Records, work: Works, at: Days]
NoTurn == [req |-> 0, st |-> "done", rec |-> NoRec, work |-> "none", at |-> 0]






PCs == {"off", "idle", "ask", "save", "flight", "late", "wait", "need",
        "tools", "final"}
Questions == {"none", "crash", "old", "other"}

ProcStates == [pc: PCs, req: 0..MaxReq, cont: BOOLEAN, md: 0..CrashLoopAfter,
               q: Questions, auto: BOOLEAN, old: BOOLEAN, fresh: BOOLEAN]
OffProc == [pc |-> "off", req |-> 0, cont |-> FALSE, md |-> 0, q |-> "none",
            auto |-> FALSE, old |-> FALSE, fresh |-> FALSE]
Idle(r) == [OffProc EXCEPT !.pc = "idle", !.req = r]

VARIABLES
    turn,
    lock,
    wall,






    ps,

    faults,
    fate,
    answered,
    seen,
    stranded

vars == <<turn, lock, wall, ps, faults, fate, answered, seen, stranded>>

TypeOK ==
    /\ turn \in Turns /\ lock \subseteq Procs /\ wall \in Days
    /\ ps \in [Procs -> ProcStates]
    /\ faults \in 0..MaxFaults
    /\ fate \in [Reqs -> {"none", "open", "ok", "cancel"}]
    /\ answered \in [Reqs -> BOOLEAN]
    /\ seen \in 0..CrashLoopAfter
    /\ stranded \in BOOLEAN

-----------------------------------------------------------------------------


Today    == Policy = "today"
Proposed == Policy = "proposed"
CanFault == faults < MaxFaults
Holds(p) == p \in lock
Cur      == turn.req


Written(p, r) ==
    IF ps[p].cont
       THEN [req |-> ps[p].req, st |-> "open", rec |-> r, work |-> "none", at |-> wall]
       ELSE [turn EXCEPT !.rec = r, !.at = wall]


ModuleActive(p) == ps[p].pc \in {"ask", "save", "flight", "late", "wait", "need"}
OnWire(p) == ps[p].pc \in {"flight", "late"}



SendRec(p) == [ph |-> "sending", clean |-> FALSE, need |-> "none",
               deaths |-> IF Bug = "reset_on_resume" THEN 0 ELSE ps[p].md]


Count(r) == Min(r.deaths + (IF r.ph = "sending" /\ ~r.clean THEN 1 ELSE 0),
                CrashLoopAfter)


Cleared == IF Bug = "no_clear" THEN turn.rec ELSE NoRec

NextReq == Cardinality({r \in Reqs : fate[r] # "none"}) + 1

-----------------------------------------------------------------------------


Init ==
    /\ turn = NoTurn /\ lock = {} /\ wall = 0
    /\ ps = [p \in Procs |-> OffProc]
    /\ faults = 0 /\ fate = [r \in Reqs |-> "none"]
    /\ answered = [r \in Reqs |-> FALSE] /\ seen = 0 /\ stranded = FALSE




Launch(p) ==
    LET t == [turn EXCEPT !.st = IF @ = "open" THEN "crash" ELSE @]
        resumable ==
            /\ t.req > 0
            /\ \/ t.st = "crash"


               \/ Bug = "resume_cancelled" /\ t.st = "cancel"


            /\ t.work # "final" \/ Bug = "resume_answered"
        isOld == t.at # wall
        asksOld == isOld /\ Bug # "ignore_age"
        c == Count(t.rec)



        ask(q) == /\ turn' = [req |-> t.req, st |-> "open", work |-> "none", at |-> wall,
                              rec |-> [ph |-> "need", clean |-> FALSE, deaths |-> c, need |-> q]]
                  /\ ps' = [ps EXCEPT ![p] = [pc |-> "ask", req |-> t.req, cont |-> FALSE,
                                              md |-> c, q |-> q, auto |-> FALSE, old |-> isOld,
                                              fresh |-> FALSE]]
    IN
    /\ ps[p].pc = "off"
    /\ lock = {} \/ Bug = "no_lock"
    /\ lock' = lock \cup {p}
    /\ IF ~resumable \/ Today
          THEN /\ turn' = t
               /\ ps' = [ps EXCEPT ![p] = Idle(t.req)]
               /\ stranded' = (stranded \/ (resumable /\ ~isOld))
          ELSE /\ UNCHANGED stranded
               /\ CASE asksOld                   -> ask("old")
                    [] c >= CrashLoopAfter       -> ask("crash")
                    [] t.rec.ph = "need"         -> ask(t.rec.need)
                    [] OTHER ->
                         /\ turn' = t
                         /\ ps' = [ps EXCEPT ![p] = [pc |-> "save", req |-> t.req,
                                       cont |-> TRUE, md |-> c, q |-> "none",
                                       auto |-> TRUE, old |-> isOld, fresh |-> FALSE]]
    /\ UNCHANGED <<wall, faults, fate, answered, seen>>

-----------------------------------------------------------------------------




Prompt(p) ==
    LET r == NextReq IN
    /\ ps[p].pc = "idle" /\ Holds(p) /\ r <= MaxReq
    /\ fate' = [fate EXCEPT ![r] = "open",
                            ![Cur] = IF Cur > 0 /\ @ = "open" THEN "cancel" ELSE @]
    /\ ps' = [ps EXCEPT ![p] = [OffProc EXCEPT !.pc = "save", !.req = r, !.cont = TRUE]]
    /\ seen' = 0
    /\ UNCHANGED <<turn, lock, wall, faults, answered, stranded>>



UserContinue(p) ==
    /\ ps[p].pc = "idle" /\ Holds(p)
    /\ Cur > 0 /\ turn.st = "crash" /\ fate[Cur] = "open"
    /\ ps' = [ps EXCEPT ![p] = [OffProc EXCEPT !.pc = "save", !.req = Cur,
                                               !.cont = TRUE, !.md = Count(turn.rec)]]
    /\ answered' = [answered EXCEPT ![Cur] = FALSE]
    /\ UNCHANGED <<turn, lock, wall, faults, fate, seen, stranded>>




Enter(p) ==
    LET loop == ps[p].q = "crash" IN
    /\ ps[p].pc \in {"ask", "need"}
    /\ ps' = [ps EXCEPT ![p].pc = "save", ![p].q = "none", ![p].auto = FALSE,
                        ![p].md = IF loop THEN 0 ELSE @, ![p].fresh = loop]
    /\ UNCHANGED <<turn, lock, wall, faults, fate, answered, seen, stranded>>


Cancelled(p) ==
    IF ps[p].cont
       THEN [req |-> ps[p].req, st |-> "cancel", rec |-> NoRec, work |-> "none", at |-> wall]
       ELSE [turn EXCEPT !.st = "cancel", !.rec = NoRec]


Esc(p) ==
    /\ ps[p].pc \in {"ask", "save", "flight", "late", "wait", "need"}
    /\ turn' = Cancelled(p)
    /\ fate' = [fate EXCEPT ![ps[p].req] = "cancel"]
    /\ ps' = [ps EXCEPT ![p] = Idle(ps[p].req)]
    /\ seen' = 0
    /\ UNCHANGED <<lock, wall, faults, answered, stranded>>



Quit(p) ==
    LET pc == ps[p].pc IN
    /\ pc # "off"
    /\ CASE pc = "final" ->
              /\ turn' = [turn EXCEPT !.st = "done", !.rec = NoRec]
              /\ fate' = [fate EXCEPT ![Cur] = "ok"]
         [] pc \in {"ask", "save", "flight", "late", "wait", "need", "tools"} ->
              /\ turn' = Cancelled(p)
              /\ fate' = [fate EXCEPT ![ps[p].req] = "cancel"]
         [] OTHER -> UNCHANGED <<turn, fate>>
    /\ ps' = [ps EXCEPT ![p] = OffProc]
    /\ lock' = lock \ {p}
    /\ seen' = IF pc \in {"idle", "off"} THEN seen ELSE 0
    /\ UNCHANGED <<wall, faults, answered, stranded>>

-----------------------------------------------------------------------------




Save(p) ==
    /\ ps[p].pc = "save" /\ Holds(p)
    /\ IF Bug = "send_before_save"
          THEN /\ ps' = [ps EXCEPT ![p].pc = "late"]
               /\ UNCHANGED turn
          ELSE /\ ps' = [ps EXCEPT ![p].pc = "flight", ![p].cont = FALSE, ![p].fresh = FALSE]
               /\ turn' = Written(p, IF Today THEN NoRec ELSE SendRec(p))
    /\ seen' = IF ps[p].fresh /\ Bug # "send_before_save" THEN 0 ELSE seen
    /\ UNCHANGED <<lock, wall, faults, fate, answered, stranded>>

LateSave(p) ==
    /\ ps[p].pc = "late"
    /\ turn' = Written(p, SendRec(p))
    /\ ps' = [ps EXCEPT ![p].pc = "flight", ![p].cont = FALSE, ![p].fresh = FALSE]
    /\ seen' = IF ps[p].fresh THEN 0 ELSE seen
    /\ UNCHANGED <<lock, wall, faults, fate, answered, stranded>>




Respond(p) ==
    /\ ps[p].pc = "flight"
    /\ \/ /\ turn' = [turn EXCEPT !.work = "tools", !.rec = Cleared]
          /\ ps' = [ps EXCEPT ![p] = [@ EXCEPT !.pc = "tools", !.md = 0,
                                               !.auto = FALSE]]
          /\ UNCHANGED answered
       \/ /\ turn' = [turn EXCEPT !.work = "final", !.rec = Cleared]
          /\ answered' = [answered EXCEPT ![Cur] = TRUE]
          /\ ps' = [ps EXCEPT ![p] = [@ EXCEPT !.pc = "final", !.auto = FALSE]]

    /\ seen' = 0
    /\ UNCHANGED <<lock, wall, faults, fate, stranded>>


Finish(p) ==
    /\ ps[p].pc = "final"
    /\ turn' = [turn EXCEPT !.st = "done"]
    /\ fate' = [fate EXCEPT ![Cur] = "ok"]
    /\ ps' = [ps EXCEPT ![p] = Idle(Cur)]
    /\ seen' = 0
    /\ UNCHANGED <<lock, wall, faults, answered, stranded>>


ToolsDone(p) ==
    /\ ps[p].pc = "tools"
    /\ ps' = [ps EXCEPT ![p].pc = "save"]
    /\ UNCHANGED <<turn, lock, wall, faults, fate, answered, seen, stranded>>


Fail(p) ==
    /\ ps[p].pc = "flight" /\ CanFault
    /\ turn' = IF Today THEN turn
               ELSE [turn EXCEPT !.rec = [SendRec(p) EXCEPT !.ph = "waiting"],
                                 !.at = wall]
    /\ ps' = [ps EXCEPT ![p].pc = "wait"]
    /\ faults' = faults + 1
    /\ UNCHANGED <<lock, wall, fate, answered, seen, stranded>>

Retry(p) ==
    /\ ps[p].pc = "wait"
    /\ ps' = [ps EXCEPT ![p].pc = "save"]
    /\ UNCHANGED <<turn, lock, wall, faults, fate, answered, seen, stranded>>


NeedFail(p) ==
    /\ ps[p].pc = "flight" /\ CanFault
    /\ turn' = IF Today THEN turn
               ELSE [turn EXCEPT !.rec = [SendRec(p) EXCEPT !.ph = "need",
                                                          !.need = "other"],
                                 !.at = wall]
    /\ ps' = [ps EXCEPT ![p].pc = "need", ![p].q = "other"]
    /\ faults' = faults + 1
    /\ UNCHANGED <<lock, wall, fate, answered, seen, stranded>>

-----------------------------------------------------------------------------



Kill(p) ==
    /\ ps[p].pc # "off" /\ CanFault
    /\ seen' = IF OnWire(p) THEN Min(seen + 1, CrashLoopAfter) ELSE seen
    /\ ps' = [ps EXCEPT ![p] = OffProc]
    /\ lock' = lock \ {p}
    /\ faults' = faults + 1
    /\ UNCHANGED <<turn, wall, fate, answered, stranded>>






Close(p) ==
    LET saves == Proposed /\ Bug # "no_closing" /\ ModuleActive(p) /\ ~ps[p].cont IN
    /\ ps[p].pc # "off" /\ CanFault
    /\ turn' = IF saves
                  THEN [turn EXCEPT
                          !.rec = IF ps[p].pc \in {"save", "late"}
                                     THEN [SendRec(p) EXCEPT !.clean = TRUE]
                                     ELSE [@ EXCEPT !.clean = TRUE],
                          !.at = wall]
                  ELSE turn

    /\ seen' = IF saves /\ ps[p].fresh THEN 0 ELSE seen
    /\ ps' = [ps EXCEPT ![p] = OffProc]
    /\ lock' = lock \ {p}
    /\ faults' = faults + 1
    /\ UNCHANGED <<wall, fate, answered, stranded>>


Day ==
    /\ wall = 0 /\ CanFault
    /\ wall' = 1
    /\ faults' = faults + 1
    /\ UNCHANGED <<turn, lock, ps, fate, answered, seen, stranded>>

Next ==
    \/ \E p \in Procs :
          \/ Launch(p) \/ Prompt(p) \/ UserContinue(p) \/ Enter(p) \/ Esc(p)
          \/ Quit(p) \/ Save(p) \/ LateSave(p) \/ Respond(p) \/ Finish(p)
          \/ ToolsDone(p) \/ Fail(p) \/ Retry(p) \/ NeedFail(p)
          \/ Kill(p) \/ Close(p)
    \/ Day

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------



AutoSend(p) == ps[p].auto /\ ps[p].pc \in {"save", "flight", "late"}



AutoResumes == ~stranded



NoFalseCrashQuestion == \A p \in Procs : ps[p].q = "crash" => seen >= CrashLoopAfter



CrashLoopAsks == \A p \in Procs : AutoSend(p) => seen < CrashLoopAfter


DoneNeverResent == \A p \in Procs : AutoSend(p) => ~answered[ps[p].req]


CancelNeverResumes == \A p \in Procs : AutoSend(p) => fate[ps[p].req] # "cancel"


OldAsks == \A p \in Procs : AutoSend(p) => ~ps[p].old


Working(p) == ps[p].pc \in {"ask", "save", "flight", "late", "wait", "need",
                             "tools", "final"}
OneWorker == Cardinality({p \in Procs : Working(p)}) <= 1

=============================================================================
