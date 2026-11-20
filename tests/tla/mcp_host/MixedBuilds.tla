---- MODULE MixedBuilds ----

























EXTENDS Naturals

CONSTANTS RevokeOnReplay

Loc == "v3"
Copy == FALSE

Chains == {"old", "new"}
None == "none"
Holders == {"older", "this", "v2", "v3"}

VARIABLES
    v2kind,
    v2,
    v3,
    older,
    this,
    current,
    rotated,
    alive,

    erased,
    ended,
    taken

vars == <<v2kind, v2, v3, older, this, current, rotated, alive, erased, ended, taken>>

TypeOK ==
    /\ v2kind \in {"absent", "v1", "v2"}
    /\ v2 \in Chains \cup {None} /\ v3 \in Chains \cup {None}
    /\ older \in Chains \cup {None} /\ this \in Chains \cup {None}
    /\ current \in [Chains -> SUBSET Holders]
    /\ rotated \in [Chains -> {"older", "this", None}]
    /\ alive \subseteq Chains
    /\ erased \in BOOLEAN /\ ended \in BOOLEAN /\ taken \in BOOLEAN

Init ==

    /\ v2kind = "v1" /\ v2 = "old"
    /\ v3 = IF Copy THEN "old" ELSE None
    /\ older = "old" /\ this = None
    /\ current = [c \in Chains |-> IF c = "old" THEN {"older", "v2"} \cup (IF Copy THEN {"v3"} ELSE {}) ELSE {}]
    /\ rotated = [c \in Chains |-> None]
    /\ alive = {"old"}
    /\ erased = FALSE /\ ended = FALSE /\ taken = FALSE


Doc == IF Loc = "v3" THEN v3 ELSE v2


ThisWrite(c) ==
    IF Loc = "v3"
    THEN /\ v3' = c /\ UNCHANGED <<v2kind, v2>>
    ELSE /\ v2' = c /\ v2kind' = "v2" /\ UNCHANGED v3



OlderWrite(c) ==
    /\ v2' = c /\ v2kind' = "v1"
    /\ erased' = (erased \/ (v2 = "new" /\ c # "new"))
    /\ UNCHANGED v3



ThisGet ==
    /\ Loc = "v3" \/ v2kind # "absent"
    /\ this' = Doc
    /\ current' = IF Doc # None /\ Loc \in current[Doc]
                  THEN [current EXCEPT ![Doc] = @ \cup {"this"}] ELSE current
    /\ taken' = (taken \/ Doc = "old")
    /\ UNCHANGED <<v2kind, v2, v3, older, rotated, alive, erased, ended>>


ThisSignIn ==
    /\ this' = "new"
    /\ alive' = alive \cup {"new"}
    /\ current' = [current EXCEPT !["new"] = {"this", Loc}]
    /\ rotated' = [rotated EXCEPT !["new"] = None]
    /\ ThisWrite("new")
    /\ UNCHANGED <<older, erased, ended, taken>>


ThisLogout ==
    /\ this # None
    /\ \E gone \in {alive, alive \ {this}} : alive' = gone
    /\ this' = None
    /\ ThisWrite(None)
    /\ UNCHANGED <<older, current, rotated, erased, ended, taken>>


Rotate(s, c, doc) ==
    /\ current' = [current EXCEPT ![c] = {s, doc}]
    /\ rotated' = [rotated EXCEPT ![c] = s]


ThisRefresh ==
    LET c == this IN
    /\ c # None
    /\ IF c \in alive /\ "this" \in current[c]
       THEN /\ Rotate("this", c, Loc)
            /\ ThisWrite(c)
            /\ UNCHANGED <<older, this, alive, erased, ended, taken>>
       ELSE IF c \in alive /\ Doc = c /\ Loc \in current[c]

       THEN /\ current' = [current EXCEPT ![c] = @ \cup {"this"}]
            /\ UNCHANGED <<v2kind, v2, v3, older, this, rotated, alive, erased, ended, taken>>


       ELSE /\ this' = None
            /\ ended' = (ended \/ (c \in alive /\ rotated[c] = "older"))
            /\ alive' = IF RevokeOnReplay /\ c \in alive THEN alive \ {c} ELSE alive
            /\ IF Doc = c /\ Loc \notin current[c] THEN ThisWrite(None) ELSE UNCHANGED <<v2kind, v2, v3>>
            /\ UNCHANGED <<older, current, rotated, erased, taken>>




OlderEnds ==
    /\ older # None
    /\ older' = None
    /\ LET revoke == RevokeOnReplay /\ older \in alive /\ "older" \notin current[older] IN
       /\ alive' = IF revoke THEN alive \ {older} ELSE alive
       /\ ended' = (ended \/ (revoke /\ this = older))
    /\ OlderWrite(None)
    /\ UNCHANGED <<this, current, rotated, taken>>


OlderRefresh ==
    LET c == older IN
    /\ c # None
    /\ IF c \in alive /\ "older" \in current[c]
       THEN /\ Rotate("older", c, "v2")
            /\ OlderWrite(c)
            /\ UNCHANGED <<older, this, alive, ended, taken>>
       ELSE OlderEnds


Expire ==
    \E c \in alive :
        /\ alive' = alive \ {c}
        /\ UNCHANGED <<v2kind, v2, v3, older, this, current, rotated, erased, ended, taken>>

Next ==
    \/ ThisGet \/ ThisSignIn \/ ThisLogout \/ ThisRefresh
    \/ OlderRefresh \/ OlderEnds \/ Expire

Spec == Init /\ [][Next]_vars


NoLoginErasedByOlder == ~erased


NoLoginEndedByOlder == ~ended



OlderLoginNotTaken == ~taken
====
