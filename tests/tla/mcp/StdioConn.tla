---- MODULE StdioConn ----




















EXTENDS Naturals

CONSTANTS MaxAttempts, MaxStarts

ASSUME MaxAttempts \in Nat \ {0} /\ MaxStarts \in Nat \ {0}

Conn == {"idle", "starting", "running", "closing", "terminating", "killing", "backoff", "failed", "stopped"}
Live == {"running", "closing", "terminating", "killing"}
Down == {"idle", "backoff", "failed", "stopped"}
Proc == {"none", "alive", "exited", "reaped"}
Era == {"unknown", "modern", "legacy"}
Kind == {"request", "notification", "response"}
Gens == 1..MaxStarts
Timers == {"grace", "term", "backoff"} \X Gens

VARIABLES
    conn,
    proc,
    gen,
    attempts,
    era,
    stdinOpen,
    stopping,
    errored,
    sent,
    pipe,
    armed,

    staleDelivered, badWrite, respondedModern, earlyTerm, restartedEarly

vars == <<conn, proc, gen, attempts, era, stdinOpen, stopping, errored, sent, pipe, armed,
          staleDelivered, badWrite, respondedModern, earlyTerm, restartedEarly>>

Init ==
    /\ conn = "idle"
    /\ proc = "none"
    /\ gen = 0
    /\ attempts = 0
    /\ era = "unknown"
    /\ stdinOpen = FALSE
    /\ stopping = FALSE
    /\ errored = FALSE
    /\ sent = {}
    /\ pipe = {}
    /\ armed = {}
    /\ staleDelivered = FALSE
    /\ badWrite = FALSE
    /\ respondedModern = FALSE
    /\ earlyTerm = FALSE
    /\ restartedEarly = FALSE



Failure ==
    /\ attempts' = attempts + 1
    /\ IF attempts + 1 >= MaxAttempts
          THEN conn' = "failed" /\ armed' = armed
          ELSE conn' = "backoff" /\ armed' = armed \cup {<<"backoff", gen>>}




StartRequested ==
    /\ conn \in {"idle", "stopped"}
    /\ gen < MaxStarts
    /\ conn' = "starting"
    /\ gen' = gen + 1
    /\ attempts' = IF conn = "stopped" THEN 0 ELSE attempts
    /\ era' = "unknown"
    /\ stopping' = FALSE
    /\ errored' = FALSE
    /\ sent' = {}
    /\ UNCHANGED <<proc, stdinOpen, pipe, armed,
                   staleDelivered, badWrite, respondedModern, earlyTerm, restartedEarly>>


Spawned ==
    /\ conn = "starting"
    /\ proc' = "alive"
    /\ IF stopping
          THEN conn' = "closing" /\ stdinOpen' = FALSE /\ armed' = armed \cup {<<"grace", gen>>}
          ELSE conn' = "running" /\ stdinOpen' = TRUE /\ armed' = armed
    /\ UNCHANGED <<gen, attempts, era, stopping, errored, sent, pipe,
                   staleDelivered, badWrite, respondedModern, earlyTerm, restartedEarly>>

SpawnFailed ==
    /\ conn = "starting"
    /\ IF stopping
          THEN conn' = "stopped" /\ UNCHANGED <<attempts, armed>>
          ELSE Failure
    /\ UNCHANGED <<proc, gen, era, stdinOpen, stopping, errored, sent, pipe,
                   staleDelivered, badWrite, respondedModern, earlyTerm, restartedEarly>>


EmitLine ==
    /\ proc = "alive"
    /\ pipe' = pipe \cup {gen}
    /\ UNCHANGED <<conn, proc, gen, attempts, era, stdinOpen, stopping, errored, sent, armed,
                   staleDelivered, badWrite, respondedModern, earlyTerm, restartedEarly>>


Deliverable(g) == g = gen /\ conn \in Live



LineReceived(g) ==
    /\ g \in pipe
    /\ pipe' \in {pipe, pipe \ {g}}
    /\ IF Deliverable(g)
          THEN attempts' = 0 /\ staleDelivered' = (staleDelivered \/ g # gen)
          ELSE UNCHANGED <<attempts, staleDelivered>>
    /\ UNCHANGED <<conn, proc, gen, era, stdinOpen, stopping, errored, sent, armed,
                   badWrite, respondedModern, earlyTerm, restartedEarly>>


ConnectionError ==
    /\ conn' = "killing"
    /\ stdinOpen' = FALSE
    /\ errored' = TRUE
    /\ sent' = sent \cup {"kill"}



OversizedLine(g) ==
    /\ g \in pipe
    /\ pipe' = pipe \ {g}
    /\ IF g = gen /\ conn = "running"
          THEN ConnectionError
          ELSE UNCHANGED <<conn, stdinOpen, errored, sent>>
    /\ UNCHANGED <<proc, gen, attempts, era, stopping, armed,
                   staleDelivered, badWrite, respondedModern, earlyTerm, restartedEarly>>


WriteFailed ==
    /\ conn = "running"
    /\ ConnectionError
    /\ UNCHANGED <<proc, gen, attempts, era, stopping, pipe, armed,
                   staleDelivered, badWrite, respondedModern, earlyTerm, restartedEarly>>




ResponseAllowed == era # "modern"


Send(k) ==
    /\ conn = "running"
    /\ k = "response" => ResponseAllowed
    /\ badWrite' = (badWrite \/ ~stdinOpen)
    /\ respondedModern' = (respondedModern \/ (k = "response" /\ era = "modern"))
    /\ UNCHANGED <<conn, proc, gen, attempts, era, stdinOpen, stopping, errored, sent, pipe, armed,
                   staleDelivered, earlyTerm, restartedEarly>>


EraDetected(e) ==
    /\ conn = "running"
    /\ era = "unknown"
    /\ era' = e
    /\ UNCHANGED <<conn, proc, gen, attempts, stdinOpen, stopping, errored, sent, pipe, armed,
                   staleDelivered, badWrite, respondedModern, earlyTerm, restartedEarly>>


Crash ==
    /\ proc = "alive"
    /\ proc' = "exited"
    /\ UNCHANGED <<conn, gen, attempts, era, stdinOpen, stopping, errored, sent, pipe, armed,
                   staleDelivered, badWrite, respondedModern, earlyTerm, restartedEarly>>


Killed ==
    /\ proc = "alive"
    /\ "kill" \in sent
    /\ proc' = "exited"
    /\ UNCHANGED <<conn, gen, attempts, era, stdinOpen, stopping, errored, sent, pipe, armed,
                   staleDelivered, badWrite, respondedModern, earlyTerm, restartedEarly>>



ProcessExited ==
    /\ proc = "exited"
    /\ proc' = "reaped"
    /\ stdinOpen' = FALSE
    /\ IF stopping
          THEN conn' = "stopped" /\ UNCHANGED <<attempts, armed>>
          ELSE Failure
    /\ UNCHANGED <<gen, era, stopping, errored, sent, pipe,
                   staleDelivered, badWrite, respondedModern, earlyTerm, restartedEarly>>


StopRequested ==
    /\ ~stopping
    /\ conn # "stopped"
    /\ stopping' = TRUE
    /\ CASE conn = "running" ->
                conn' = "closing" /\ stdinOpen' = FALSE /\ armed' = armed \cup {<<"grace", gen>>}
         [] conn \in Down ->
                conn' = "stopped" /\ UNCHANGED <<stdinOpen, armed>>
         [] OTHER ->
                UNCHANGED <<conn, stdinOpen, armed>>
    /\ UNCHANGED <<proc, gen, attempts, era, errored, sent, pipe,
                   staleDelivered, badWrite, respondedModern, earlyTerm, restartedEarly>>



GraceTimerFired(g) ==
    /\ <<"grace", g>> \in armed
    /\ IF g = gen /\ conn = "closing"
          THEN /\ conn' = "terminating"
               /\ sent' = sent \cup {"term"}
               /\ armed' = (armed \ {<<"grace", g>>}) \cup {<<"term", gen>>}
               /\ earlyTerm' = (earlyTerm \/ <<"grace", gen>> \in (armed \ {<<"grace", g>>}))
          ELSE /\ armed' = armed \ {<<"grace", g>>}
               /\ UNCHANGED <<conn, sent, earlyTerm>>
    /\ UNCHANGED <<proc, gen, attempts, era, stdinOpen, stopping, errored, pipe,
                   staleDelivered, badWrite, respondedModern, restartedEarly>>


TermTimerFired(g) ==
    /\ <<"term", g>> \in armed
    /\ armed' = armed \ {<<"term", g>>}
    /\ IF g = gen /\ conn = "terminating"
          THEN conn' = "killing" /\ sent' = sent \cup {"kill"}
          ELSE UNCHANGED <<conn, sent>>
    /\ UNCHANGED <<proc, gen, attempts, era, stdinOpen, stopping, errored, pipe,
                   staleDelivered, badWrite, respondedModern, earlyTerm, restartedEarly>>


BackoffTimerFired(g) ==
    /\ <<"backoff", g>> \in armed
    /\ armed' = armed \ {<<"backoff", g>>}
    /\ IF g = gen /\ conn = "backoff"
          THEN conn' = "idle" /\ restartedEarly' = (restartedEarly \/ <<"backoff", gen>> \in armed')
          ELSE UNCHANGED <<conn, restartedEarly>>
    /\ UNCHANGED <<proc, gen, attempts, era, stdinOpen, stopping, errored, sent, pipe,
                   staleDelivered, badWrite, respondedModern, earlyTerm>>


ReconnectRequested ==
    /\ conn = "failed"
    /\ conn' = "idle"
    /\ attempts' = 0
    /\ UNCHANGED <<proc, gen, era, stdinOpen, stopping, errored, sent, pipe, armed,
                   staleDelivered, badWrite, respondedModern, earlyTerm, restartedEarly>>

Next ==
    \/ StartRequested
    \/ Spawned
    \/ SpawnFailed
    \/ EmitLine
    \/ \E g \in Gens: LineReceived(g) \/ OversizedLine(g)
    \/ WriteFailed
    \/ \E k \in Kind: Send(k)
    \/ \E e \in {"modern", "legacy"}: EraDetected(e)
    \/ Crash
    \/ Killed
    \/ ProcessExited
    \/ StopRequested
    \/ \E g \in Gens: GraceTimerFired(g) \/ TermTimerFired(g) \/ BackoffTimerFired(g)
    \/ ReconnectRequested

Fairness ==
    /\ WF_vars(Spawned \/ SpawnFailed)
    /\ WF_vars(Killed)
    /\ WF_vars(ProcessExited)
    /\ \A g \in Gens: WF_vars(GraceTimerFired(g)) /\ WF_vars(TermTimerFired(g)) /\ WF_vars(BackoffTimerFired(g))

Spec == Init /\ [][Next]_vars /\ Fairness

TypeOK ==
    /\ conn \in Conn
    /\ proc \in Proc
    /\ gen \in 0..MaxStarts
    /\ attempts \in 0..MaxAttempts
    /\ era \in Era
    /\ stdinOpen \in BOOLEAN
    /\ stopping \in BOOLEAN
    /\ errored \in BOOLEAN
    /\ sent \subseteq {"term", "kill"}
    /\ pipe \subseteq Gens
    /\ armed \subseteq Timers
    /\ staleDelivered \in BOOLEAN
    /\ badWrite \in BOOLEAN
    /\ respondedModern \in BOOLEAN
    /\ earlyTerm \in BOOLEAN
    /\ restartedEarly \in BOOLEAN


OneProcess == conn = "starting" => proc \in {"none", "reaped"}


NoOrphan == conn \in Down => proc \in {"none", "reaped"}


NoStaleDelivery == ~staleDelivered


WritesOnlyWhenOpen == ~badWrite


NoClientResponsesModern == ~respondedModern




NoRefusedAnswer == (conn = "running" /\ era # "modern") => ResponseAllowed



SignalOrder ==
    /\ "term" \in sent => (~stdinOpen /\ stopping /\ ~errored)
    /\ "kill" \in sent => ("term" \in sent \/ errored)


SignalsOnTime == ~earlyTerm



RestartBounded ==
    /\ attempts <= MaxAttempts
    /\ conn = "failed" => attempts = MaxAttempts
    /\ conn = "backoff" => attempts < MaxAttempts


NoEarlyRestart == ~restartedEarly



Progress ==
    /\ stopping ~> conn = "stopped"
    /\ proc = "exited" ~> proc = "reaped"
====
