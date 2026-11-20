------------------------- MODULE FailureStreakTrace -------------------------















EXTENDS FailureStreak, FailureStreakObserved, TLC

VARIABLE turn
traceVars == <<streak, hist, ended, turn>>

Active == turn <= Len(Observed)
T == Observed[turn]

ReplayStep ==
  /\ Active
  /\ Len(hist) < Len(T.steps)
  /\ Step(T.steps[Len(hist) + 1].fail, T.steps[Len(hist) + 1].write)
  /\ UNCHANGED turn

NextTurn ==
  /\ Active
  /\ Len(hist) = Len(T.steps)
  /\ ended = T.ended
  /\ PrintT(<<"FXT_MATCHED", turn>>)
  /\ turn' = turn + 1
  /\ streak' = [c \in Cmds |-> 0]
  /\ hist' = << >>
  /\ ended' = FALSE

TraceInit == Init /\ turn = 1

TraceNext == ReplayStep \/ NextTurn

TraceSpec == TraceInit /\ [][TraceNext]_traceVars


NotAllMatched == turn <= Len(Observed)
=============================================================================
