----------------------------- MODULE DurableSteer -----------------------------



































EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Steers,
    MaxTools,
    MaxHandoffs,
    MaxCancels,
    Retries,
    Interrupt,
    HandBack,
    JoinBeforeStart,
    Dedupe

ASSUME Interrupt \in BOOLEAN /\ HandBack \in BOOLEAN
ASSUME JoinBeforeStart \in BOOLEAN /\ Dedupe \in BOOLEAN /\ Retries \in BOOLEAN

P == "p"
Msgs == {P} \cup Steers
None == "none"
States == {"waiting", "running", "end", "cancelled"}

VARIABLES
    sent,
    turns,


    phase,
    queue,
    worker,
    retried,
    dup,
    preStart,
    tools,
    handoffs,
    cancels,
    act

vars == <<sent, turns, phase, queue, worker, retried, dup, preStart, tools, handoffs, cancels, act>>

Range(s) == {s[i] : i \in DOMAIN s}

TypeOK ==
    /\ sent \in Seq(Msgs)
    /\ \A i \in DOMAIN turns : turns[i] \in [owner: Msgs, state: States, ctx: SUBSET Msgs]
    /\ phase \in {"idle", "gen", "args", "tool"}
    /\ queue \in Seq(Steers)
    /\ worker \in BOOLEAN
    /\ retried \subseteq Steers /\ dup \subseteq Steers /\ preStart \subseteq Steers
    /\ tools \in 0..MaxTools /\ handoffs \in 0..MaxHandoffs /\ cancels \in 0..MaxCancels
    /\ act \in [name: {"Init", "Send", "Retry", "Start", "ModelText", "ToolArgs", "ToolCall",
                       "ToolEnd", "Cancel", "Handoff"},
                m: Msgs \cup {None}]

Init ==
    /\ sent = <<>>
    /\ turns = <<>>
    /\ phase = "idle"
    /\ queue = <<>>
    /\ worker = FALSE
    /\ retried = {} /\ dup = {} /\ preStart = {}
    /\ tools = 0 /\ handoffs = 0 /\ cancels = 0
    /\ act = [name |-> "Init", m |-> None]

RunningAt == {i \in DOMAIN turns : turns[i].state = "running"}
WaitingAt == {i \in DOMAIN turns : turns[i].state = "waiting"}
Running == RunningAt # {}
Run == CHOOSE i \in RunningAt : TRUE
FirstWaiting == CHOOSE i \in WaitingAt : \A j \in WaitingAt : i <= j


Placed(t, steers) == [t EXCEPT !.ctx = t.ctx \cup Range(steers)]



NewTurns(steers) ==
    IF steers = <<>> THEN <<>>
    ELSE IF JoinBeforeStart
         THEN <<[owner |-> steers[1], state |-> "waiting", ctx |-> Range(steers)]>>
         ELSE [k \in 1..Len(steers) |-> [owner |-> steers[k], state |-> "waiting", ctx |-> {steers[k]}]]



Finish(how, back) ==
    LET ended == [turns EXCEPT ![Run].state = how] \o NewTurns(back)
        waiting == {i \in DOMAIN ended : ended[i].state = "waiting"}
        next == CHOOSE i \in waiting : \A j \in waiting : i <= j
    IN IF waiting # {}
       THEN /\ turns' = [ended EXCEPT ![next].state = "running"]
            /\ phase' = "gen"
            /\ worker' = TRUE
       ELSE /\ turns' = ended
            /\ phase' = "idle"
            /\ worker' = FALSE




Send(m) ==
    /\ m \notin Range(sent)
    /\ (m = P) = (sent = <<>>)
    /\ sent' = Append(sent, m)
    /\ IF m = P
          THEN /\ turns' = <<[owner |-> P, state |-> "waiting", ctx |-> {P}]>>
               /\ UNCHANGED <<phase, queue, preStart>>
          ELSE IF Running
          THEN /\ IF phase = "gen" /\ Interrupt

                     THEN /\ turns' = [turns EXCEPT ![Run] = Placed(turns[Run], <<m>>)]
                          /\ UNCHANGED queue
                     ELSE /\ queue' = Append(queue, m)
                          /\ UNCHANGED turns
               /\ UNCHANGED <<phase, preStart>>
          ELSE IF WaitingAt # {}
          THEN /\ preStart' = preStart \cup {m}
               /\ turns' = IF JoinBeforeStart
                              THEN [turns EXCEPT ![FirstWaiting].ctx = @ \cup {m}]
                              ELSE turns \o NewTurns(<<m>>)
               /\ UNCHANGED <<phase, queue>>
          ELSE /\ turns' = turns \o NewTurns(<<m>>)
               /\ UNCHANGED <<phase, queue, preStart>>
    /\ UNCHANGED <<worker, retried, dup, tools, handoffs, cancels>>
    /\ act' = [name |-> "Send", m |-> m]




Retry(m) ==
    /\ Retries
    /\ m \in Steers /\ m \in Range(sent) /\ m \notin retried
    /\ retried' = retried \cup {m}
    /\ dup' = IF Dedupe THEN dup ELSE dup \cup {m}
    /\ UNCHANGED <<sent, turns, phase, queue, worker, preStart, tools, handoffs, cancels>>
    /\ act' = [name |-> "Retry", m |-> m]


Start ==
    /\ ~worker
    /\ WaitingAt # {}
    /\ turns' = [turns EXCEPT ![FirstWaiting].state = "running"]
    /\ phase' = "gen"
    /\ worker' = TRUE
    /\ UNCHANGED <<sent, queue, retried, dup, preStart, tools, handoffs, cancels>>
    /\ act' = [name |-> "Start", m |-> None]



ModelText ==
    /\ phase = "gen"
    /\ IF queue # <<>>
          THEN /\ turns' = [turns EXCEPT ![Run] = Placed(turns[Run], queue)]
               /\ UNCHANGED <<phase, worker>>
          ELSE Finish("end", <<>>)
    /\ queue' = <<>>
    /\ UNCHANGED <<sent, retried, dup, preStart, tools, handoffs, cancels>>
    /\ act' = [name |-> "ModelText", m |-> None]


ToolArgs ==
    /\ phase = "gen"
    /\ tools < MaxTools
    /\ phase' = "args"
    /\ UNCHANGED <<sent, turns, queue, worker, retried, dup, preStart, tools, handoffs, cancels>>
    /\ act' = [name |-> "ToolArgs", m |-> None]


ToolCall ==
    /\ phase = "args"
    /\ phase' = "tool"
    /\ tools' = tools + 1
    /\ UNCHANGED <<sent, turns, queue, worker, retried, dup, preStart, handoffs, cancels>>
    /\ act' = [name |-> "ToolCall", m |-> None]



ToolEnd ==
    /\ phase = "tool"
    /\ turns' = [turns EXCEPT ![Run] = Placed(turns[Run], queue)]
    /\ queue' = <<>>
    /\ phase' = "gen"
    /\ UNCHANGED <<sent, worker, retried, dup, preStart, tools, handoffs, cancels>>
    /\ act' = [name |-> "ToolEnd", m |-> None]


Cancel ==
    /\ Running
    /\ cancels < MaxCancels
    /\ Finish("cancelled", IF HandBack THEN queue ELSE <<>>)
    /\ queue' = <<>>
    /\ cancels' = cancels + 1
    /\ UNCHANGED <<sent, retried, dup, preStart, tools, handoffs>>
    /\ act' = [name |-> "Cancel", m |-> None]



Handoff ==
    /\ phase \in {"gen", "args"}
    /\ handoffs < MaxHandoffs
    /\ turns' = [turns EXCEPT ![Run] = Placed(turns[Run], queue)]
    /\ queue' = <<>>
    /\ phase' = "gen"
    /\ handoffs' = handoffs + 1
    /\ UNCHANGED <<sent, worker, retried, dup, preStart, tools, cancels>>
    /\ act' = [name |-> "Handoff", m |-> None]

Next ==
    \/ \E m \in Msgs : Send(m) \/ Retry(m)
    \/ Start \/ ModelText \/ ToolArgs \/ ToolCall \/ ToolEnd \/ Cancel \/ Handoff

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------



Holders(m) == {i \in DOMAIN turns : turns[i].state # "waiting" /\ m \in turns[i].ctx}
Times(m) == Cardinality(Holders(m)) * (IF m \in dup THEN 2 ELSE 1)


AtMostOnce == \A m \in Msgs : Times(m) <= 1



Quiescent == ~Running /\ WaitingAt = {}
NothingLost == Quiescent => \A i \in DOMAIN sent : Times(sent[i]) = 1


SentIndex(m) == CHOOSE i \in DOMAIN sent : sent[i] = m
InOrder == \A i, j \in DOMAIN turns : i < j => SentIndex(turns[i].owner) < SentIndex(turns[j].owner)


NoSteerWaitsOnReply == phase = "gen" => queue = <<>>


PreStartJoins == \A s \in preStart : \A i \in DOMAIN turns : turns[i].owner # s

=============================================================================
