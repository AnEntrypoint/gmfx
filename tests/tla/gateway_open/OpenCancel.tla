---------------------------- MODULE OpenCancel ----------------------------

























EXTENDS TLC

CONSTANTS Abandon, CloseLate, AtomicSwap, StopConnect, FreeOnReturn

VARIABLES worker,
          job,
          conn,
          client,
          state,
          cancelled,
          wseen,
          jseen

vars == <<worker, job, conn, client, state, cancelled, wseen, jseen>>

TypeOK ==
    /\ worker \in {"waiting", "returned", "using", "done"}
    /\ job \in {"lookup", "connect", "finished", "reading", "published"}
    /\ conn \in {"none", "open", "closed"}
    /\ client \in {"live", "freed"}
    /\ state \in {"running", "abandoned", "handed"}
    /\ cancelled \in BOOLEAN
    /\ wseen \in {"none", "running", "abandoned", "handed"}
    /\ jseen \in {"none", "running", "abandoned", "handed"}

Init ==
    /\ worker = "waiting" /\ job = "lookup" /\ conn = "none" /\ client = "live"
    /\ state = "running" /\ cancelled = FALSE
    /\ wseen = "none" /\ jseen = "none"


Cancel ==
    /\ worker = "waiting" /\ ~cancelled
    /\ cancelled' = TRUE
    /\ UNCHANGED <<worker, job, conn, client, state, wseen, jseen>>


LookupReturns ==
    /\ job = "lookup"
    /\ job' = "connect" /\ conn' = "open"
    /\ UNCHANGED <<worker, client, state, cancelled, wseen, jseen>>


ConnectReturns ==
    /\ job = "connect"
    /\ job' = "finished"
    /\ UNCHANGED <<worker, conn, client, state, cancelled, wseen, jseen>>



JobStopConnect ==
    /\ StopConnect /\ job = "connect" /\ state = "abandoned"
    /\ job' = "finished" /\ conn' = "closed"
    /\ UNCHANGED <<worker, client, state, cancelled, wseen, jseen>>


CloseLateConn == IF CloseLate /\ conn = "open" THEN "closed" ELSE conn
FreeLateClient == IF CloseLate THEN "freed" ELSE client



JobPublishAtomic ==
    /\ AtomicSwap /\ job = "finished"
    /\ job' = "published"
    /\ IF state = "running"
          THEN state' = "handed" /\ UNCHANGED <<conn, client>>
          ELSE conn' = CloseLateConn /\ client' = FreeLateClient /\ UNCHANGED state
    /\ UNCHANGED <<worker, cancelled, wseen, jseen>>

JobRead ==
    /\ ~AtomicSwap /\ job = "finished"
    /\ job' = "reading" /\ jseen' = state
    /\ UNCHANGED <<worker, conn, client, state, cancelled, wseen>>

JobWrite ==
    /\ ~AtomicSwap /\ job = "reading"
    /\ job' = "published"
    /\ IF jseen = "running"
          THEN state' = "handed" /\ UNCHANGED <<conn, client>>
          ELSE conn' = CloseLateConn /\ client' = FreeLateClient /\ UNCHANGED state
    /\ UNCHANGED <<worker, cancelled, wseen, jseen>>


WalkAwayClient == IF FreeOnReturn THEN "freed" ELSE client




WorkerAbandonAtomic ==
    /\ Abandon /\ AtomicSwap /\ worker = "waiting" /\ cancelled
    /\ worker' = "returned"
    /\ IF state = "running"
          THEN state' = "abandoned" /\ client' = WalkAwayClient /\ UNCHANGED conn
          ELSE IF state = "handed"
               THEN conn' = "closed" /\ client' = "freed" /\ UNCHANGED state
               ELSE UNCHANGED <<state, conn, client>>
    /\ UNCHANGED <<job, cancelled, wseen, jseen>>

WorkerRead ==
    /\ Abandon /\ ~AtomicSwap /\ worker = "waiting" /\ cancelled /\ wseen = "none"
    /\ wseen' = state
    /\ UNCHANGED <<worker, job, conn, client, state, cancelled, jseen>>

WorkerWrite ==
    /\ Abandon /\ ~AtomicSwap /\ worker = "waiting" /\ cancelled /\ wseen # "none"
    /\ worker' = "returned"
    /\ IF wseen = "running"
          THEN state' = "abandoned" /\ client' = WalkAwayClient /\ UNCHANGED conn
          ELSE IF wseen = "handed"
               THEN conn' = "closed" /\ client' = "freed" /\ UNCHANGED state
               ELSE UNCHANGED <<state, conn, client>>
    /\ UNCHANGED <<job, cancelled, wseen, jseen>>



WorkerAfterPublish ==
    /\ ~Abandon /\ worker = "waiting" /\ job = "published" /\ state = "handed"
    /\ IF cancelled
          THEN worker' = "returned" /\ conn' = "closed" /\ client' = "freed"
          ELSE worker' = "using" /\ UNCHANGED <<conn, client>>
    /\ UNCHANGED <<job, state, cancelled, wseen, jseen>>


WorkerTake ==
    /\ Abandon /\ worker = "waiting" /\ ~cancelled /\ state = "handed"
    /\ worker' = "using"
    /\ UNCHANGED <<job, conn, client, state, cancelled, wseen, jseen>>


WorkerDone ==
    /\ worker = "using"
    /\ worker' = "done" /\ conn' = "closed" /\ client' = "freed"
    /\ UNCHANGED <<job, state, cancelled, wseen, jseen>>

WorkerStep == WorkerAbandonAtomic \/ WorkerRead \/ WorkerWrite \/ WorkerAfterPublish \/ WorkerTake \/ WorkerDone
JobStep == JobStopConnect \/ JobPublishAtomic \/ JobRead \/ JobWrite

Next == Cancel \/ LookupReturns \/ ConnectReturns \/ JobStep \/ WorkerStep

Spec == Init /\ [][Next]_vars /\ WF_vars(WorkerStep) /\ WF_vars(JobStep)


NeverUsedAfterCancel == ~(worker = "using" /\ cancelled)


NoFreeUnderJob == client = "freed" => job = "published"


NoUseAfterFree == worker = "using" => client = "live"


CancelReturns == [](cancelled => <>(worker = "returned"))


LateClosed == <>[](worker # "using" /\ job = "published" => conn # "open")



AbandonedOpenCloses == [](state = "abandoned" => <>[](conn # "open"))


ClientFreed == <>[](worker \in {"returned", "done"} /\ job = "published" => client = "freed")
=============================================================================
