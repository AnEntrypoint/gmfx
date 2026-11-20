---------------------------- MODULE ShellTrace ----------------------------
















EXTENDS ShellContract, ShellObserved

VARIABLE turn
traceVars == <<phase, pending, calls, lastRejected, turn>>

Active == turn <= Len(Observed)
T == Observed[turn]

ObsMatches(rec, o) ==
  /\ rec.e = o.e
  /\ rec.accepted = o.accepted
  /\ rec.decoded = o.decoded
  /\ rec.outcome = o.outcome
  /\ (o.history = "unobserved" \/ rec.history = o.history)

GuardTripped ==
  /\ Len(calls) >= 2
  /\ ~calls[Len(calls)].accepted
  /\ ~calls[Len(calls) - 1].accepted
  /\ calls[Len(calls)].e = calls[Len(calls) - 1].e

TurnMatched ==
  /\ Active
  /\ phase = "done"
  /\ Len(calls) = Len(T.calls)
  /\ (GuardTripped <=> T.ended = "guard")

TraceInit == Init /\ turn = 1

EmitStep ==
  /\ Active
  /\ Len(calls) < Len(T.calls)
  /\ ModelEmit
  /\ pending' = T.calls[Len(calls) + 1].e
  /\ UNCHANGED turn

ProcessStep ==
  /\ Active
  /\ Process
  /\ ObsMatches(calls'[Len(calls')], T.calls[Len(calls')])
  /\ UNCHANGED turn

FinishStep ==
  /\ Active
  /\ Len(calls) = Len(T.calls)
  /\ T.ended = "final"
  /\ ModelFinish
  /\ UNCHANGED turn

NextTurn ==
  /\ TurnMatched
  /\ PrintT(<<"FXT_MATCHED", turn>>)
  /\ turn' = turn + 1
  /\ phase' = "model"
  /\ pending' = NoCall
  /\ calls' = << >>
  /\ lastRejected' = NoCall

TraceNext == EmitStep \/ ProcessStep \/ FinishStep \/ NextTurn

TraceSpec == TraceInit /\ [][TraceNext]_traceVars

AllMatched == turn > Len(Observed)


NotAllMatched == ~AllMatched
=============================================================================
