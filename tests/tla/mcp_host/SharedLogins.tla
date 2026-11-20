---- MODULE SharedLogins ----
































EXTENDS Naturals

CONSTANTS
    Procs,
    MaxVer,
    RevokeOnReplay,
    SaveFaults,
    Revocation

Vers == 1..MaxVer

VARIABLES
    store,
    held,
    tried,
    needs,
    unsaved,
    next,
    dead,
    chain,
    out,

    erased,
    retook,
    replayed,
    stale,
    resurrected,
    leftValid

vars == <<store, held, tried, needs, unsaved, next, dead, chain, out, erased, retook, replayed, stale, resurrected, leftValid>>
ghosts == <<erased, retook, replayed, stale, resurrected, leftValid>>

TypeOK ==
    /\ store \in 0..MaxVer
    /\ held \in [Procs -> 0..MaxVer]
    /\ tried \in [Procs -> 0..MaxVer]
    /\ needs \in [Procs -> BOOLEAN]
    /\ unsaved \in [Procs -> BOOLEAN]
    /\ next \in 1..(MaxVer + 1)
    /\ dead \subseteq Vers
    /\ chain \in [Vers -> 0..MaxVer]
    /\ out \in BOOLEAN
    /\ erased \in BOOLEAN /\ retook \in BOOLEAN /\ replayed \in BOOLEAN /\ stale \in BOOLEAN
    /\ resurrected \in BOOLEAN /\ leftValid \in BOOLEAN

Init ==
    /\ store = 0
    /\ held = [p \in Procs |-> 0]
    /\ tried = [p \in Procs |-> 0]
    /\ needs = [p \in Procs |-> FALSE]
    /\ unsaved = [p \in Procs |-> FALSE]
    /\ next = 1
    /\ dead = {}
    /\ chain = [v \in Vers |-> 0]
    /\ out = FALSE
    /\ erased = FALSE /\ retook = FALSE /\ replayed = FALSE /\ stale = FALSE
    /\ resurrected = FALSE /\ leftValid = FALSE

SignIn(p) ==
    /\ next <= MaxVer
    /\ store' = next
    /\ held' = [held EXCEPT ![p] = next]
    /\ tried' = [tried EXCEPT ![p] = next]
    /\ needs' = [needs EXCEPT ![p] = FALSE]
    /\ unsaved' = [unsaved EXCEPT ![p] = FALSE]
    /\ next' = next + 1
    /\ chain' = [chain EXCEPT ![next] = next]
    /\ out' = FALSE
    /\ UNCHANGED <<dead, erased, retook, replayed, stale, resurrected, leftValid>>



Drop(p) ==
    /\ held' = [held EXCEPT ![p] = 0]
    /\ needs' = [needs EXCEPT ![p] = TRUE]
    /\ unsaved' = [unsaved EXCEPT ![p] = FALSE]
    /\ store' = IF store = tried[p] THEN 0 ELSE store
    /\ erased' = (erased \/ (store > tried[p] /\ store' = 0))
    /\ stale' = (stale \/ (store' # 0 /\ store' < held[p] /\ store' \in dead /\ chain[store'] = chain[held[p]]))

Refused(p) ==
    /\ held[p] # 0
    /\ dead' = dead \cup {held[p]}
    /\ Drop(p)
    /\ UNCHANGED <<tried, next, chain, out, retook, replayed, resurrected, leftValid>>

NeedsScope(p) ==
    /\ held[p] # 0
    /\ ~needs[p]
    /\ needs' = [needs EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<store, held, tried, unsaved, next, dead, chain, out>>
    /\ UNCHANGED ghosts

PickUp(p) ==
    /\ needs[p]
    /\ store # 0
    /\ store # tried[p]
    /\ held' = [held EXCEPT ![p] = store]
    /\ tried' = [tried EXCEPT ![p] = store]
    /\ needs' = [needs EXCEPT ![p] = FALSE]
    /\ unsaved' = [unsaved EXCEPT ![p] = FALSE]
    /\ retook' = (retook \/ store = tried[p])
    /\ UNCHANGED <<store, next, dead, chain, out, erased, replayed, stale, resurrected, leftValid>>

Logout(p) ==
    /\ held' = [held EXCEPT ![p] = 0]
    /\ tried' = [tried EXCEPT ![p] = 0]
    /\ needs' = [needs EXCEPT ![p] = TRUE]
    /\ unsaved' = [unsaved EXCEPT ![p] = FALSE]
    /\ store' = 0
    /\ out' = TRUE
    /\ dead' = IF Revocation THEN dead \cup ({held[p], store} \ {0}) ELSE dead
    /\ leftValid' = (leftValid \/ (Revocation /\ store # 0 /\ store \notin dead'))
    /\ UNCHANGED <<next, chain, erased, retook, replayed, stale, resurrected>>


Newer(p) == store # 0 /\ store # tried[p]


Take(p) ==
    /\ held' = [held EXCEPT ![p] = store]
    /\ tried' = [tried EXCEPT ![p] = store]
    /\ unsaved' = [unsaved EXCEPT ![p] = FALSE]
    /\ retook' = (retook \/ store = tried[p])
    /\ UNCHANGED <<store, needs, next, dead, chain, out, erased, replayed, stale, resurrected, leftValid>>


SavedLater(v) == store # 0 /\ chain[store] = chain[v] /\ store > v




Send(p) ==
    LET v == held[p] IN
    IF v \notin dead
    THEN /\ next <= MaxVer
         /\ held' = [held EXCEPT ![p] = next]
         /\ dead' = dead \cup {v}
         /\ chain' = [chain EXCEPT ![next] = chain[v]]
         /\ next' = next + 1
         /\ \/ /\ store' = next
               /\ tried' = [tried EXCEPT ![p] = next]
               /\ unsaved' = [unsaved EXCEPT ![p] = FALSE]
               /\ resurrected' = (resurrected \/ out)
            \/ /\ SaveFaults
               /\ unsaved' = [unsaved EXCEPT ![p] = TRUE]
               /\ UNCHANGED <<store, tried, resurrected>>
         /\ UNCHANGED <<needs, out, erased, retook, replayed, stale, leftValid>>
    ELSE /\ replayed' = (replayed \/ SavedLater(v))
         /\ dead' = IF RevokeOnReplay THEN dead \cup {w \in Vers : chain[w] = chain[v]} ELSE dead
         /\ Drop(p)
         /\ UNCHANGED <<tried, next, chain, out, retook, resurrected, leftValid>>



EndedElsewhere(p) == store = 0 /\ tried[p] # 0



SignOutToo(p) ==
    /\ held' = [held EXCEPT ![p] = 0]
    /\ tried' = [tried EXCEPT ![p] = 0]
    /\ needs' = [needs EXCEPT ![p] = TRUE]
    /\ unsaved' = [unsaved EXCEPT ![p] = FALSE]
    /\ dead' = IF Revocation THEN dead \cup {held[p]} ELSE dead
    /\ UNCHANGED <<store, next, chain, out>>
    /\ UNCHANGED ghosts



Refresh(p) ==
    /\ held[p] # 0 /\ ~needs[p]
    /\ IF Newer(p) THEN Take(p)
       ELSE IF EndedElsewhere(p) THEN SignOutToo(p)
       ELSE Send(p)


Idle == UNCHANGED vars

Next ==
    \/ \E p \in Procs :
        SignIn(p) \/ Refused(p) \/ NeedsScope(p) \/ PickUp(p) \/ Logout(p) \/ Refresh(p)
    \/ Idle

Spec == Init /\ [][Next]_vars


NoNewerLoginErased == ~erased


NoLoginRetaken == ~retook




HeldIsTried == \A p \in Procs : held[p] # 0 /\ ~unsaved[p] => held[p] = tried[p]



NoRetiredRefresh == ~replayed



NoStaleLoginLeft == ~stale



LogoutStays == ~resurrected


LogoutRevokesSaved == ~leftValid
====
