---- MODULE TraceFullDetailOrder ----










EXTENDS FullDetailOrder, TraceData

OnObservedRun ==
    /\ Len(events) <= Len(ObservedLive)
    /\ events = SubSeq(ObservedLive, 1, Len(events))

NotTheRun ==
    ~((committed \/ crashed) /\ events = ObservedLive /\ replay = ObservedReplay)
====
