---------------------------- MODULE ShellSession ----------------------------


















EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
  Ids,
  MaxTurns,
  Mutant

None == "none"

Mutants == {
  "none",
  "saved_by_turns",
  "saved_on_open",
  "exit_by_turns",
  "status_launch_id",
  "keep_pristine",
  "reuse_id",
  "fork_held",
  "drop_on_switch"
}

ASSUME None \notin Ids
ASSUME MaxTurns \in Nat \ {0}
ASSUME Mutant \in Mutants

VARIABLES
  running,
  durable,
  cur,
  turnOpen,
  onDisk,
  turns,
  used,
  discarded,
  first,
  ended,
  last

vars == <<running, durable, cur, turnOpen, onDisk, turns, used, discarded, first, ended, last>>

Ops == {"start", "launch", "launch_resume", "launch_no_store", "begin", "end",
        "status", "new", "clear", "resume", "fork", "quit", "crash"}

Obs(op, id, point, saved, handoff) ==
  [op |-> op, id |-> id, point |-> point, saved |-> saved, handoff |-> handoff]

Quiet(op) == Obs(op, None, 0, FALSE, None)

Saved(i) == i # None /\ i \in onDisk




Report ==
  [ id    |-> IF Mutant = "status_launch_id" THEN first ELSE cur,
    saved |-> CASE Mutant = "saved_by_turns" -> cur # None /\ turns[cur] > 0
                [] Mutant = "saved_on_open"  -> cur # None
                [] OTHER                     -> Saved(cur) ]


Handoff ==
  IF IF Mutant = "exit_by_turns" THEN cur # None /\ turns[cur] > 0 ELSE Saved(cur)
    THEN cur
    ELSE None


FreshIds == IF Mutant = "reuse_id" THEN Ids \ {cur} ELSE Ids \ used



OnDiskAfterLeave ==
  CASE cur # None /\ Mutant = "keep_pristine"  -> onDisk \cup {cur}
    [] cur # None /\ Mutant = "drop_on_switch" -> onDisk \ {cur}
    [] OTHER                                   -> onDisk

DiscardedAfterLeave ==
  IF cur # None /\ cur \notin onDisk THEN discarded \cup {cur} ELSE discarded



Init ==
  /\ running = FALSE
  /\ durable = TRUE
  /\ cur = None
  /\ turnOpen = FALSE
  /\ onDisk = {}
  /\ turns = [i \in Ids |-> 0]
  /\ used = {}
  /\ discarded = {}
  /\ first = None
  /\ ended = "none"
  /\ last = Quiet("start")




Launch(i) ==
  /\ ~running
  /\ i \in FreshIds
  /\ running' = TRUE
  /\ durable' = TRUE
  /\ cur' = i
  /\ used' = used \cup {i}
  /\ first' = i
  /\ last' = Obs("launch", i, 0, FALSE, None)
  /\ UNCHANGED <<turnOpen, onDisk, turns, discarded, ended>>


LaunchResume(i) ==
  /\ ~running
  /\ i \in onDisk
  /\ running' = TRUE
  /\ durable' = TRUE
  /\ cur' = i
  /\ first' = i
  /\ last' = Obs("launch_resume", i, 0, FALSE, None)
  /\ UNCHANGED <<turnOpen, onDisk, turns, used, discarded, ended>>


LaunchNoStore ==
  /\ ~running
  /\ running' = TRUE
  /\ durable' = FALSE
  /\ cur' = None
  /\ first' = None
  /\ last' = Quiet("launch_no_store")
  /\ UNCHANGED <<turnOpen, onDisk, turns, used, discarded, ended>>




Begin ==
  /\ running
  /\ ~turnOpen
  /\ cur # None => turns[cur] < MaxTurns
  /\ turnOpen' = TRUE
  /\ IF cur = None
       THEN UNCHANGED <<onDisk, turns>>
       ELSE /\ onDisk' = onDisk \cup {cur}
            /\ turns' = [turns EXCEPT ![cur] = @ + 1]
  /\ last' = Quiet("begin")
  /\ UNCHANGED <<running, durable, cur, used, discarded, first, ended>>

End ==
  /\ running
  /\ turnOpen
  /\ turnOpen' = FALSE
  /\ last' = Quiet("end")
  /\ UNCHANGED <<running, durable, cur, onDisk, turns, used, discarded, first, ended>>


Status ==
  /\ running
  /\ last' = Obs("status", Report.id, 0, Report.saved, None)
  /\ UNCHANGED <<running, durable, cur, turnOpen, onDisk, turns, used, discarded, first, ended>>




NewSession(op, i) ==
  /\ running
  /\ ~turnOpen
  /\ IF durable
       THEN /\ i \in FreshIds
            /\ cur' = i
            /\ used' = used \cup {i}
            /\ onDisk' = OnDiskAfterLeave
            /\ discarded' = DiscardedAfterLeave
       ELSE /\ i = None
            /\ UNCHANGED <<cur, used, onDisk, discarded>>
  /\ last' = Obs(op, i, 0, FALSE, None)
  /\ UNCHANGED <<running, durable, turnOpen, turns, first, ended>>


Resume(i) ==
  /\ running
  /\ ~turnOpen
  /\ durable
  /\ cur # None
  /\ i \in onDisk
  /\ i # cur
  /\ cur' = i
  /\ onDisk' = OnDiskAfterLeave
  /\ discarded' = DiscardedAfterLeave
  /\ last' = Obs("resume", i, 0, FALSE, None)
  /\ UNCHANGED <<running, durable, turnOpen, turns, used, first, ended>>



Fork(p, i) ==
  /\ running
  /\ ~turnOpen
  /\ durable
  /\ cur \in onDisk
  /\ p \in 1..turns[cur]
  /\ i \in FreshIds
  /\ cur' = i
  /\ used' = used \cup {i}
  /\ turns' = [turns EXCEPT ![i] = p - 1]
  /\ onDisk' = IF Mutant = "fork_held" /\ p = 1 THEN OnDiskAfterLeave ELSE OnDiskAfterLeave \cup {i}
  /\ discarded' = DiscardedAfterLeave
  /\ last' = Obs("fork", i, p, FALSE, None)
  /\ UNCHANGED <<running, durable, turnOpen, first, ended>>





Quit ==
  /\ running
  /\ running' = FALSE
  /\ turnOpen' = FALSE
  /\ onDisk' = OnDiskAfterLeave
  /\ discarded' = DiscardedAfterLeave
  /\ ended' = "quit"
  /\ last' = Obs("quit", None, 0, FALSE, Handoff)
  /\ UNCHANGED <<durable, cur, turns, used, first>>



Crash ==
  /\ running
  /\ running' = FALSE
  /\ turnOpen' = FALSE
  /\ discarded' = DiscardedAfterLeave
  /\ ended' = "crash"
  /\ last' = Quiet("crash")
  /\ UNCHANGED <<durable, cur, onDisk, turns, used, first>>

Next ==
  \/ \E i \in Ids : Launch(i) \/ LaunchResume(i)
  \/ LaunchNoStore
  \/ Begin
  \/ End
  \/ Status
  \/ \E i \in Ids \cup {None} : NewSession("new", i) \/ NewSession("clear", i)
  \/ \E i \in Ids : Resume(i)
  \/ \E p \in 1..MaxTurns, i \in Ids : Fork(p, i)
  \/ Quit
  \/ Crash

Spec == Init /\ [][Next]_vars



TypeOK ==
  /\ running \in BOOLEAN
  /\ durable \in BOOLEAN
  /\ cur \in Ids \cup {None}
  /\ turnOpen \in BOOLEAN
  /\ onDisk \subseteq Ids
  /\ turns \in [Ids -> 0..MaxTurns]
  /\ used \subseteq Ids
  /\ discarded \subseteq Ids
  /\ first \in Ids \cup {None}
  /\ ended \in {"none", "quit", "crash"}
  /\ last \in [op: Ops, id: Ids \cup {None}, point: 0..MaxTurns, saved: BOOLEAN, handoff: Ids \cup {None}]


StatusNamesOpenSession == last.op = "status" => last.id = cur


StatusSavedIsOnDisk == last.op = "status" /\ last.saved => last.id \in onDisk



StatusUnsavedIsAbsent == last.op = "status" /\ ~last.saved => last.id \notin onDisk


DiscardedNeverSaved == discarded \cap onDisk = {}


NewSessionUnsaved ==
  last.op \in {"launch", "new", "clear"} /\ last.id # None => last.id \notin onDisk


ResumeOpensSaved ==
  last.op \in {"launch_resume", "resume"} => last.id = cur /\ cur \in onDisk


ForkOnDisk == last.op = "fork" => last.id = cur /\ cur \in onDisk /\ turns[cur] = last.point - 1


ExitNamesSaved == last.op = "quit" /\ last.handoff # None => last.handoff \in onDisk


ExitAgreesWithStatus ==
  [][last'.op = "quit" => last'.handoff = IF Saved(cur) THEN cur ELSE None]_vars


NewIdsAreFresh ==
  [][last'.op \in {"launch", "new", "clear", "fork"} /\ last'.id # None => last'.id \notin used]_vars


SavedStaysSaved == [][onDisk \subseteq onDisk']_vars







NoSavedEmptyStatus == ~(last.op = "status" /\ last.saved /\ turns[cur] = 0)


NoUnsavedStatus == ~(last.op = "status" /\ ~last.saved /\ last.id # None)


NoStorelessStatus == ~(last.op = "status" /\ last.id = None)


NoEmptyExitLine == ~(last.op = "quit" /\ last.handoff # None /\ turns[last.handoff] = 0)


NoResumeAfterCrash == ~(last.op = "launch_resume" /\ ended = "crash")
=============================================================================
