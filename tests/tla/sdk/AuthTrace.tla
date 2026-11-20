------------------------------ MODULE AuthTrace ------------------------------




EXTENDS ProviderAuth, AuthObserved, Sequences, TLC

VARIABLE i

TraceInit == Init /\ i = 0

TraceNext ==
  /\ i < Len(Observed)
  /\ Next
  /\ ev' = Observed[i + 1]
  /\ i' = i + 1

TraceSpec == TraceInit /\ [][TraceNext]_<<vars, i>>

NotAllMatched == i < Len(Observed)


Matched == PrintT(<<"AUTH_MATCHED", i>>)
=============================================================================
