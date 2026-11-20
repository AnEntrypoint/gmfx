---- MODULE Subscription ----

















EXTENDS Naturals

CONSTANTS Subs, Kinds, Ask(_), MaxListens, MaxTries

ASSUME Subs \subseteq Nat \ {0} /\ \A s \in Subs: Ask(s) \subseteq Kinds /\ Ask(s) # {}



TwoAsks(s) == IF s = 1 THEN {"tools"} ELSE {"tools", "prompts"}

None == 0
NoId == 0
Ids == 1..MaxListens
Phases == {"off", "pending", "active", "waiting", "ended"}

VARIABLES
    phase,
    cur,
    asked,
    acked,
    tries,
    next,
    stdio,
    up,

    owner,
    ackSeen,
    allowed,
    over,
    told,
    final,

    misrouted,
    early,
    unasked,
    late,
    sentDown,
    relistened

vars == <<phase, cur, asked, acked, tries, next, stdio, up, owner, ackSeen, allowed, over, told, final,
          misrouted, early, unasked, late, sentDown, relistened>>
ghosts == <<misrouted, early, unasked, late, sentDown, relistened>>

Init ==
    /\ phase = [s \in Subs |-> "off"]
    /\ cur = [s \in Subs |-> NoId]
    /\ asked = [s \in Subs |-> {}]
    /\ acked = [s \in Subs |-> {}]
    /\ tries = [s \in Subs |-> 0]
    /\ next = 1
    /\ stdio \in BOOLEAN
    /\ up = TRUE
    /\ owner = [n \in Ids |-> None]
    /\ ackSeen = [n \in Ids |-> FALSE]
    /\ allowed = [n \in Ids |-> {}]
    /\ over = [n \in Ids |-> FALSE]
    /\ told = [n \in Ids |-> 0]
    /\ final = [n \in Ids |-> FALSE]
    /\ misrouted = FALSE /\ early = FALSE /\ unasked = FALSE /\ late = FALSE /\ sentDown = FALSE
    /\ relistened = FALSE


Listen(s, f) ==
    /\ next <= MaxListens
    /\ phase' = [phase EXCEPT ![s] = "pending"]
    /\ cur' = [cur EXCEPT ![s] = next]
    /\ asked' = [asked EXCEPT ![s] = f]
    /\ acked' = [acked EXCEPT ![s] = {}]
    /\ next' = next + 1
    /\ owner' = [owner EXCEPT ![next] = s]
    /\ sentDown' = (sentDown \/ (stdio /\ ~up))


Open(s) ==
    /\ phase[s] \in {"off", "ended"}
    /\ ~stdio \/ up
    /\ Listen(s, Ask(s))
    /\ tries' = [tries EXCEPT ![s] = 0]
    /\ UNCHANGED <<stdio, up, ackSeen, allowed, over, told, final, misrouted, early, unasked, late, relistened>>



Resend(s) ==
    /\ phase[s] = "waiting"
    /\ ~stdio \/ up
    /\ Listen(s, asked[s])
    /\ relistened' = (relistened \/ final[cur[s]])
    /\ UNCHANGED <<tries, stdio, up, ackSeen, allowed, over, told, final, misrouted, early, unasked, late>>


Cancel(s) ==
    /\ phase[s] \in {"pending", "active", "waiting"}
    /\ phase' = [phase EXCEPT ![s] = "off"]
    /\ over' = IF phase[s] \in {"pending", "active"} THEN [over EXCEPT ![cur[s]] = TRUE] ELSE over
    /\ UNCHANGED <<cur, asked, acked, tries, next, stdio, up, owner, ackSeen, allowed, told, final, ghosts>>

Current(n) == \E s \in Subs: phase[s] \in {"pending", "active"} /\ cur[s] = n
OwnerOf(n) == CHOOSE s \in Subs: cur[s] = n


Ends(s, n) ==
    /\ phase' = [phase EXCEPT ![s] = "ended"]
    /\ over' = [over EXCEPT ![n] = TRUE]
    /\ told' = [told EXCEPT ![n] = @ + 1]




Ack(n, f) ==
    IF Current(n) /\ phase[OwnerOf(n)] = "pending"
    THEN LET s == OwnerOf(n)
             a == f \cap asked[s]
         IN /\ ackSeen' = [ackSeen EXCEPT ![n] = TRUE]
            /\ allowed' = [allowed EXCEPT ![n] = Ask(owner[n]) \cap f]
            /\ IF a = {}
               THEN /\ Ends(s, n)
                    /\ final' = [final EXCEPT ![n] = TRUE]
                    /\ UNCHANGED <<acked, tries>>
               ELSE /\ phase' = [phase EXCEPT ![s] = "active"]
                    /\ acked' = [acked EXCEPT ![s] = a]
                    /\ tries' = [tries EXCEPT ![s] = 0]
                    /\ UNCHANGED <<over, told, final>>
            /\ UNCHANGED <<cur, asked, next, stdio, up, owner, ghosts>>
    ELSE UNCHANGED vars



Targets(n, k) == {s \in Subs: phase[s] = "active" /\ cur[s] = n /\ k \in acked[s]}

Note(n, k) ==
    LET T == Targets(n, k)
    IN IF T = {}
       THEN UNCHANGED vars
       ELSE /\ misrouted' = (misrouted \/ \E s \in T: owner[n] # s)
            /\ early' = (early \/ ~ackSeen[n])
            /\ unasked' = (unasked \/ k \notin allowed[n])
            /\ late' = (late \/ over[n])
            /\ UNCHANGED <<phase, cur, asked, acked, tries, next, stdio, up, owner, ackSeen, allowed, over, told, final, sentDown, relistened>>


Final(n) ==
    IF Current(n)
    THEN /\ Ends(OwnerOf(n), n)
         /\ final' = [final EXCEPT ![n] = TRUE]
         /\ UNCHANGED <<cur, asked, acked, tries, next, stdio, up, owner, ackSeen, allowed, ghosts>>
    ELSE UNCHANGED vars



Abrupt(s) ==
    IF tries[s] < MaxTries
    THEN /\ phase' = [phase EXCEPT ![s] = "waiting"]
         /\ tries' = [tries EXCEPT ![s] = @ + 1]
         /\ over' = [over EXCEPT ![cur[s]] = TRUE]
         /\ UNCHANGED told
    ELSE /\ Ends(s, cur[s])
         /\ UNCHANGED tries


Lost(n) ==
    /\ ~stdio
    /\ IF Current(n)
       THEN /\ Abrupt(OwnerOf(n))
            /\ UNCHANGED <<cur, asked, acked, next, stdio, up, owner, ackSeen, allowed, final, ghosts>>
       ELSE UNCHANGED vars


Live == {s \in Subs: phase[s] \in {"pending", "active"}}

Crash ==
    /\ stdio /\ up
    /\ up' = FALSE
    /\ phase' = [s \in Subs |-> IF s \in Live THEN (IF tries[s] < MaxTries THEN "waiting" ELSE "ended") ELSE phase[s]]
    /\ tries' = [s \in Subs |-> IF s \in Live /\ tries[s] < MaxTries THEN tries[s] + 1 ELSE tries[s]]
    /\ over' = [n \in Ids |-> over[n] \/ \E s \in Live: cur[s] = n]
    /\ told' = [n \in Ids |-> IF \E s \in Live: cur[s] = n /\ tries[s] = MaxTries THEN told[n] + 1 ELSE told[n]]
    /\ UNCHANGED <<cur, asked, acked, next, stdio, owner, ackSeen, allowed, final, ghosts>>

Restart ==
    /\ stdio /\ ~up
    /\ up' = TRUE
    /\ UNCHANGED <<phase, cur, asked, acked, tries, next, stdio, owner, ackSeen, allowed, over, told, final, ghosts>>

Next ==
    \/ \E s \in Subs: \/ Open(s)
                      \/ Resend(s)
                      \/ Cancel(s)
    \/ \E n \in 1..(next - 1):
           \/ \E f \in SUBSET Kinds: Ack(n, f)
           \/ \E k \in Kinds: Note(n, k)
           \/ Final(n)
           \/ Lost(n)
    \/ Crash
    \/ Restart



Spec == Init /\ [][Next]_vars /\ WF_vars(Restart) /\ \A s \in Subs: SF_vars(Resend(s))

TypeOK ==
    /\ phase \in [Subs -> Phases]
    /\ cur \in [Subs -> 0..MaxListens]
    /\ asked \in [Subs -> SUBSET Kinds]
    /\ acked \in [Subs -> SUBSET Kinds]
    /\ tries \in [Subs -> 0..MaxTries]
    /\ next \in 1..(MaxListens + 1)
    /\ stdio \in BOOLEAN /\ up \in BOOLEAN
    /\ owner \in [Ids -> Subs \cup {None}]
    /\ told \in [Ids -> 0..2]


SubDemux == ~misrouted


AckFirst == ~early


FilterRespected == ~unasked


NothingAfterEnd == ~late



OneEnd == \A n \in Ids: told[n] <= 1
EndTold == \A s \in Subs: phase[s] = "ended" => told[cur[s]] = 1


NoSendWhileDown == ~sentDown



NoRelistenAfterFinal == ~relistened


ActiveListensForSomething == \A s \in Subs: phase[s] = "active" => acked[s] # {}



ListensAgain == \A s \in Subs: phase[s] = "waiting" ~> (phase[s] # "waiting" \/ next > MaxListens)
====
