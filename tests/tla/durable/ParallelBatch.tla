---------------------------- MODULE ParallelBatch ----------------------------
















EXTENDS Naturals, Sequences

CONSTANTS N, Writes, MaxCrashes

ASSUME Writes \subseteq 1..N

Calls == 1..N

VARIABLES
    status,
    reported,
    crashes

vars == <<status, reported, crashes>>

TypeOK ==
    /\ status \in [Calls -> {"waiting", "running", "done"}]
    /\ reported \in Seq(Calls)
    /\ Len(reported) <= N
    /\ crashes \in 0..MaxCrashes

Init ==
    /\ status = [i \in Calls |-> "waiting"]
    /\ reported = <<>>
    /\ crashes = 0


CanStart(i) ==
    /\ \A j \in 1..(i - 1) : j \in Writes => status[j] = "done"
    /\ i \in Writes => \A j \in 1..(i - 1) : status[j] = "done"

Start(i) ==
    /\ status[i] = "waiting"
    /\ CanStart(i)
    /\ status' = [status EXCEPT ![i] = "running"]
    /\ UNCHANGED <<reported, crashes>>

Finish(i) ==
    /\ status[i] = "running"
    /\ status' = [status EXCEPT ![i] = "done"]
    /\ UNCHANGED <<reported, crashes>>


Report ==
    /\ Len(reported) < N
    /\ status[Len(reported) + 1] = "done"
    /\ reported' = Append(reported, Len(reported) + 1)
    /\ UNCHANGED <<status, crashes>>


Crash ==
    /\ crashes < MaxCrashes
    /\ \E i \in Calls : status[i] = "running"
    /\ status' = [i \in Calls |-> IF status[i] = "done" THEN "done" ELSE "waiting"]
    /\ crashes' = crashes + 1
    /\ UNCHANGED reported

Next ==
    \/ \E i \in Calls : Start(i) \/ Finish(i)
    \/ Report
    \/ Crash

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------



WriterRunsAlone ==
    \A i \in Writes :
        status[i] = "running" => \A j \in Calls \ {i} : status[j] # "running"


NothingPassesWriter ==
    \A i \in Writes, j \in Calls :
        j > i /\ status[j] # "waiting" => status[i] = "done"


WriterAfterEarlier ==
    \A i \in Writes, j \in Calls :
        j < i /\ status[i] # "waiting" => status[j] = "done"


ResultsInModelOrder ==
    \A k \in 1..Len(reported) : reported[k] = k /\ status[k] = "done"

-----------------------------------------------------------------------------



NoReaderOverlap ==
    ~\E i, j \in Calls \ Writes :
        i # j /\ status[i] = "running" /\ status[j] = "running"

=============================================================================
