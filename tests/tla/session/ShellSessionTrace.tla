---------------------------- MODULE ShellSessionTrace ----------------------------




















EXTENDS ShellSession, ShellSessionObserved, Sequences

VARIABLE k

traceVars == <<vars, k>>

DiskTurns == [i \in onDisk |-> turns[i]]

Match(o) ==
  /\ last = Obs(o.op, o.id, o.point, o.saved, o.handoff)
  /\ onDisk = o.disk
  /\ DiskTurns = o.turns

ASSUME Len(Observed) >= 1

TraceInit == Init /\ k = 0


TraceNext ==
  /\ k < Len(Observed)
  /\ \E o \in {Observed[k + 1]} :
       /\ Next
       /\ Match(o)'
  /\ k' = k + 1

TraceSpec == TraceInit /\ [][TraceNext]_traceVars

NotAllMatched == k < Len(Observed)
=============================================================================
