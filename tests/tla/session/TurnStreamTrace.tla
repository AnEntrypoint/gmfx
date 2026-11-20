--------------------------- MODULE TurnStreamTrace ---------------------------





























EXTENDS TurnStream, TurnStreamObserved, Sequences

VARIABLE k

traceVars == <<vars, k>>

Decided(o) ==
  /\ last.phase = o.phase
  /\ last.stood = o.stood
  /\ last.results = o.results
  /\ last.reparsed = o.reparsed

OnDisk(o) ==
  /\ committed
  /\ LiveCalls = o.calls
  /\ supersedes = o.superseded

ASSUME Len(Observed) >= 1

TraceInit == Init /\ k = 0



Arrive(o) ==
  /\ o.phase \in {"stream", "commit"}
  /\ Len(done) - cut < o.results \/ ~o.stood
  /\ Len(done) < o.arrived
  /\ Len(done) < Len(TOrder)
  /\ RunTool(TOrder[Len(done) + 1], TRUE)
  /\ UNCHANGED k


Cut(o) ==
  /\ o.phase \in {"stream", "commit"}
  /\ ~o.stood
  /\ \E n \in 1..Len(TOrder) : Compact(n)
  /\ UNCHANGED k


Follow(o) ==
  /\ o.phase \in {"stream", "commit"}
  /\ Len(done) >= o.least
  /\ IF o.phase = "stream" THEN Stream ELSE Commit
  /\ Decided(o)'
  /\ k' = k + 1

Check(o) ==
  /\ o.phase = "disk"
  /\ OnDisk(o)
  /\ UNCHANGED vars
  /\ k' = k + 1

TraceNext ==
  /\ k < Len(Observed)
  /\ \E o \in {Observed[k + 1]} : Arrive(o) \/ Cut(o) \/ Follow(o) \/ Check(o)

TraceSpec == TraceInit /\ [][TraceNext]_traceVars

NotAllMatched == k < Len(Observed)
=============================================================================
