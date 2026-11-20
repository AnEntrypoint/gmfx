--------------------------- MODULE TurnLifecycle ---------------------------













EXTENDS Naturals, Sequences, FiniteSets

CONSTANT MaxLen

HostKinds == {"start", "item", "compacted", "commit", "interrupt", "set"}
Kinds == HostKinds \cup {"created", "closed"}

VARIABLES
    log,
    status,
    fresh

vars == <<log, status, fresh>>

Count(l, k) == Cardinality({i \in 1..Len(l) : l[i] = k})
Ends(l) == Count(l, "commit") + Count(l, "interrupt")
IsOpen(l) == Count(l, "start") > Ends(l)

Prefix(a, b) == Len(a) <= Len(b) /\ SubSeq(b, 1, Len(a)) = a


Valid(l, k) ==
    CASE k = "start"     -> ~IsOpen(l)
      [] k = "item"      -> IsOpen(l)
      [] k = "commit"    -> IsOpen(l)
      [] k = "interrupt" -> IsOpen(l)
      [] k = "compacted" -> TRUE
      [] k = "set"       -> TRUE

TypeOK ==
    /\ log \in Seq(Kinds)
    /\ status \in {"new", "open", "closed", "down"}
    /\ fresh \in BOOLEAN

Init ==
    /\ log = <<>>
    /\ status = "new"
    /\ fresh = FALSE


Create ==
    /\ status = "new"
    /\ log' = <<"created">>
    /\ status' = "open"
    /\ UNCHANGED fresh


Write(k) ==
    /\ status = "open"
    /\ Len(log) < MaxLen
    /\ Valid(log, k)
    /\ log' = Append(log, k)
    /\ fresh' = (fresh /\ k # "start")
    /\ UNCHANGED status


Close ==
    /\ status = "open"
    /\ Len(log) + 2 <= MaxLen
    /\ log' = IF IsOpen(log)
                 THEN log \o <<"interrupt", "closed">>
                 ELSE Append(log, "closed")
    /\ status' = "closed"
    /\ fresh' = FALSE


Crash ==
    /\ status = "open"
    /\ status' = "down"
    /\ UNCHANGED <<log, fresh>>


Reopen ==
    /\ status \in {"closed", "down"}
    /\ Len(log) < MaxLen
    /\ log' = IF IsOpen(log) THEN Append(log, "interrupt") ELSE log
    /\ status' = "open"
    /\ fresh' = TRUE

Next ==
    \/ Create
    \/ \E k \in HostKinds : Write(k)
    \/ Close
    \/ Crash
    \/ Reopen

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------


StartsWithCreated == Len(log) > 0 => log[1] = "created"

AtMostOneOpenTurn == Count(log, "start") - Ends(log) \in {0, 1}

ItemsInsideTurns ==
    \A i \in 1..Len(log) :
        log[i] = "item" => IsOpen(SubSeq(log, 1, i - 1))

EndsCloseATurn ==
    \A i \in 1..Len(log) :
        log[i] \in {"commit", "interrupt"} => IsOpen(SubSeq(log, 1, i - 1))

ClosedOnlyBetweenTurns ==
    \A i \in 1..Len(log) :
        log[i] = "closed" => ~IsOpen(SubSeq(log, 1, i - 1))


NoStaleTurnAfterReopen == fresh => ~IsOpen(log)


AppendOnly == [][Prefix(log, log')]_vars
=============================================================================
