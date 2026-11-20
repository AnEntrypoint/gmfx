---------------------------- MODULE V1Conversion ----------------------------



















































EXTENDS Naturals, FiniteSets

CONSTANTS
    Procs,
    RootId,
    ChildId,
    NewIds,
    None,
    Torn,
    MaxV,
    MaxLocks,
    MaxExtra,
    MaxCrash,
    MaxReq,
    AvoidV1Ids

Ids == {RootId, ChildId}
Parent == [i \in Ids |-> IF i = ChildId THEN RootId ELSE None]
ASSUME RootId # ChildId /\ Ids \cap NewIds = {} /\ Procs \cap {"free", "writer"} = {}

AllIds == Ids \cup NewIds
Roots == {i \in Ids : Parent[i] = None}
Children(r) == {c \in Ids : Parent[c] = r}
Fam(r) == {r} \cup Children(r)

Kinds == {"none", "open", "all", "recover"}
Answers == {"none", "opened", "converted", "busy", "unreadable", "notfound",
            "recovered", "healthy", "unsalvageable", "inv2"}
Status == {"none", "import", "fresh", "salvage"}

Damages == {"ok", "salvage", "lost"}

VARIABLES
    v1ver,
    v1lock,
    writing,
    locks,
    bad,
    pub,
    base,

    staged,
    stagedBase,
    extra,
    conv,

    req,
    out,
    refused,
    reqs,
    crashes,
    famOf,
    keeps


vars == <<v1ver, v1lock, writing, locks, bad, pub, base, staged, stagedBase,
          extra, conv, req, out, refused, reqs, crashes, famOf, keeps>>

Idle == [pc |-> "idle", root |-> None, members |-> {}, copied |-> {}]
NoReq == [kind |-> "none", root |-> None]

TypeOK ==
    /\ v1ver \in [Ids -> 0..MaxV]
    /\ v1lock \in [Ids -> {"free", "writer"} \cup Procs]
    /\ writing \in [Ids -> BOOLEAN]
    /\ locks \in [Ids -> 0..MaxLocks]
    /\ bad \in [Ids -> Damages]
    /\ pub \in [AllIds -> Status]
    /\ base \in [AllIds -> (0..MaxV) \cup {Torn}]
    /\ staged \in [Ids -> BOOLEAN]
    /\ stagedBase \in [Ids -> (0..MaxV) \cup {Torn}]
    /\ extra \in [AllIds -> 0..MaxExtra]
    /\ \A p \in Procs :
         /\ conv[p].pc \in {"idle", "locked", "staged", "published", "salvaging"}
         /\ conv[p].root \in Roots \cup {None}
         /\ conv[p].members \subseteq Ids /\ conv[p].copied \subseteq conv[p].members
         /\ req[p].kind \in Kinds /\ req[p].root \in Roots \cup {None}
         /\ out[p].ans \in Answers /\ out[p].root \in Roots \cup {None}
         /\ refused[p] \subseteq Ids
    /\ reqs \in 0..MaxReq
    /\ crashes \in 0..MaxCrash
    /\ famOf \in [Roots -> SUBSET Ids]
    /\ keeps \subseteq Ids

Live(i) == pub[i] \in {"import", "fresh", "salvage"}



Orphan(i) == Parent[i] # None /\ pub[i] = "import" /\ pub[Parent[i]] = "none"
Dirty == \E i \in Ids : staged[i]





Leftover(p, i) ==
    /\ pub[i] = "import" /\ v1ver[i] > 0 /\ v1ver[i] = base[i] /\ bad[i] = "ok"
    /\ v1lock[i] = "free" /\ i \notin refused[p]
    /\ i \notin keeps



Listed ==
    {r \in Roots : Live(r) \/ (pub[r] = "none" /\ v1ver[r] > 0)}
        \cup {n \in NewIds : Live(n)}

Init ==
    /\ v1ver = [i \in Ids |-> 0]
    /\ v1lock = [i \in Ids |-> "free"]
    /\ writing = [i \in Ids |-> FALSE]
    /\ locks = [i \in Ids |-> 0]
    /\ bad = [i \in Ids |-> "ok"]
    /\ pub = [i \in AllIds |-> "none"]
    /\ base = [i \in AllIds |-> 0]
    /\ staged = [i \in Ids |-> FALSE]
    /\ stagedBase = [i \in Ids |-> 0]
    /\ extra = [i \in AllIds |-> 0]
    /\ conv = [p \in Procs |-> Idle]
    /\ req = [p \in Procs |-> NoReq]
    /\ out = [p \in Procs |-> [ans |-> "none", root |-> None]]
    /\ refused = [p \in Procs |-> {}]
    /\ reqs = 0
    /\ crashes = 0
    /\ famOf = [r \in Roots |-> {}]
    /\ keeps \in SUBSET Ids



WCreate(i) ==
    /\ v1ver[i] = 0
    /\ Parent[i] # None => v1ver[Parent[i]] > 0
    /\ pub[i] = "none"
    /\ v1ver' = [v1ver EXCEPT ![i] = 1]
    /\ UNCHANGED <<v1lock, writing, locks, bad, pub, base, staged, stagedBase,
                   extra, conv, req, out, refused, reqs, crashes, famOf, keeps>>

WLock(i) ==
    /\ v1ver[i] > 0
    /\ v1lock[i] = "free"
    /\ locks[i] < MaxLocks
    /\ v1lock' = [v1lock EXCEPT ![i] = "writer"]
    /\ locks' = [locks EXCEPT ![i] = @ + 1]
    /\ UNCHANGED <<v1ver, writing, bad, pub, base, staged, stagedBase, extra,
                   conv, req, out, refused, reqs, crashes, famOf, keeps>>

WBegin(i) ==
    /\ v1lock[i] = "writer"
    /\ ~writing[i]
    /\ v1ver[i] < MaxV
    /\ writing' = [writing EXCEPT ![i] = TRUE]
    /\ UNCHANGED <<v1ver, v1lock, locks, bad, pub, base, staged, stagedBase,
                   extra, conv, req, out, refused, reqs, crashes, famOf, keeps>>

WEnd(i) ==
    /\ writing[i]
    /\ writing' = [writing EXCEPT ![i] = FALSE]
    /\ v1ver' = [v1ver EXCEPT ![i] = @ + 1]
    /\ UNCHANGED <<v1lock, locks, bad, pub, base, staged, stagedBase, extra,
                   conv, req, out, refused, reqs, crashes, famOf, keeps>>

WUnlock(i) ==
    /\ v1lock[i] = "writer"
    /\ ~writing[i]
    /\ v1lock' = [v1lock EXCEPT ![i] = "free"]
    /\ UNCHANGED <<v1ver, writing, locks, bad, pub, base, staged, stagedBase,
                   extra, conv, req, out, refused, reqs, crashes, famOf, keeps>>



WCrash(i) ==
    /\ v1lock[i] = "writer"
    /\ crashes < MaxCrash
    /\ v1lock' = [v1lock EXCEPT ![i] = "free"]
    /\ writing' = [writing EXCEPT ![i] = FALSE]
    /\ crashes' = crashes + 1
    /\ UNCHANGED <<v1ver, locks, bad, pub, base, staged, stagedBase, extra,
                   conv, req, out, refused, reqs, famOf, keeps>>



Damage(i) ==
    /\ v1ver[i] > 0
    /\ bad[i] = "ok"
    /\ \E d \in Damages \ {"ok"} : bad' = [bad EXCEPT ![i] = d]
    /\ UNCHANGED <<v1ver, v1lock, writing, locks, pub, base, staged,
                   stagedBase, extra, conv, req, out, refused, reqs, crashes, famOf,
                   keeps>>



FCreate(i) ==
    /\ i \in NewIds \/ (i \in Roots /\ (AvoidV1Ids => v1ver[i] = 0))
    /\ pub[i] = "none"
    /\ i \in Ids => ~staged[i]
    /\ pub' = [pub EXCEPT ![i] = "fresh"]
    /\ UNCHANGED <<v1ver, v1lock, writing, locks, bad, base, staged,
                   stagedBase, extra, conv, req, out, refused, reqs, crashes, famOf,
                   keeps>>

FAppend(i) ==
    /\ Live(i)
    /\ i \in NewIds \/ i \in Roots
    /\ extra[i] < MaxExtra
    /\ extra' = [extra EXCEPT ![i] = @ + 1]
    /\ UNCHANGED <<v1ver, v1lock, writing, locks, bad, pub, base, staged,
                   stagedBase, conv, req, out, refused, reqs, crashes, famOf,
                   keeps>>



Request(p, k, r) ==
    /\ k \in Kinds \ {"none"}
    /\ req[p] = NoReq
    /\ conv[p] = Idle
    /\ reqs < MaxReq
    /\ req' = [req EXCEPT ![p] = [kind |-> k, root |-> r]]
    /\ out' = [out EXCEPT ![p] = [ans |-> "none", root |-> r]]
    /\ refused' = [refused EXCEPT ![p] = {}]
    /\ reqs' = reqs + 1
    /\ UNCHANGED <<v1ver, v1lock, writing, locks, bad, pub, base, staged,
                   stagedBase, extra, conv, crashes, famOf, keeps>>

Answer(p, a) ==
    /\ req' = [req EXCEPT ![p] = NoReq]
    /\ out' = [out EXCEPT ![p] = [ans |-> a, root |-> req[p].root]]

Done(p) == IF req[p].kind = "open" THEN "opened" ELSE "converted"

Waiting(p) == req[p] # NoReq /\ conv[p] = Idle /\ req[p].kind # "recover"


AHeld(p) ==
    /\ Waiting(p)
    /\ Live(req[p].root)
    /\ ~\E i \in Fam(req[p].root) : Leftover(p, i)
    /\ Answer(p, Done(p))
    /\ UNCHANGED <<v1ver, v1lock, writing, locks, bad, pub, base, staged,
                   stagedBase, extra, conv, refused, reqs, crashes, famOf,
                   keeps>>


CClean(p, i) ==
    /\ Waiting(p)
    /\ Live(req[p].root)
    /\ i \in Fam(req[p].root)
    /\ Leftover(p, i)
    /\ v1ver' = [v1ver EXCEPT ![i] = 0]
    /\ UNCHANGED <<v1lock, writing, locks, bad, pub, base, staged,
                   stagedBase, extra, conv, req, out, refused, reqs, crashes, famOf,
                   keeps>>


CCleanRefused(p, i) ==
    /\ Waiting(p)
    /\ Live(req[p].root)
    /\ i \in Fam(req[p].root)
    /\ Leftover(p, i)
    /\ crashes < MaxCrash
    /\ refused' = [refused EXCEPT ![p] = @ \cup {i}]
    /\ crashes' = crashes + 1
    /\ UNCHANGED <<v1ver, v1lock, writing, locks, bad, pub, base, staged,
                   stagedBase, extra, conv, req, out, reqs, famOf, keeps>>


AMissing(p) ==
    /\ Waiting(p)
    /\ pub[req[p].root] = "none" /\ v1ver[req[p].root] = 0
    /\ Answer(p, IF req[p].kind = "open" THEN "notfound" ELSE "converted")
    /\ UNCHANGED <<v1ver, v1lock, writing, locks, bad, pub, base, staged,
                   stagedBase, extra, conv, refused, reqs, crashes, famOf,
                   keeps>>




CBegin(p) ==
    LET r == req[p].root
        present == {i \in Fam(r) : v1ver[i] > 0} IN
    /\ Waiting(p)
    /\ pub[r] = "none" /\ v1ver[r] > 0
    /\ IF \A i \in present : v1lock[i] = "free"
       THEN /\ v1lock' = [i \in Ids |-> IF i \in present THEN p ELSE v1lock[i]]
            /\ conv' = [conv EXCEPT ![p] = [pc |-> "locked", root |-> r, members |-> present, copied |-> {}]]
            /\ UNCHANGED <<req, out>>
       ELSE /\ Answer(p, "busy")
            /\ UNCHANGED <<v1lock, conv>>
    /\ UNCHANGED <<v1ver, writing, locks, bad, pub, base, staged,
                   stagedBase, extra, refused, reqs, crashes, famOf, keeps>>




CStage(p) ==
    LET m == conv[p].members
        copy == {i \in m : pub[i] = "none"} IN
    /\ conv[p].pc = "locked"
    /\ IF \E i \in copy : bad[i] # "ok"
       THEN /\ v1lock' = [i \in Ids |-> IF i \in m THEN "free" ELSE v1lock[i]]
            /\ staged' = [i \in Ids |-> IF i \in Fam(conv[p].root) THEN FALSE ELSE staged[i]]
            /\ conv' = [conv EXCEPT ![p] = Idle]
            /\ Answer(p, "unreadable")
            /\ UNCHANGED stagedBase
       ELSE /\ staged' = [i \in Ids |-> IF i \in Fam(conv[p].root) THEN i \in copy ELSE staged[i]]
            /\ stagedBase' = [i \in Ids |->
                                IF i \in copy
                                THEN (IF writing[i] THEN Torn ELSE v1ver[i])
                                ELSE stagedBase[i]]
            /\ conv' = [conv EXCEPT ![p].pc = "staged", ![p].copied = copy]
            /\ UNCHANGED <<v1lock, req, out>>
    /\ UNCHANGED <<v1ver, writing, locks, bad, pub, base, extra, refused,
                   reqs, crashes, famOf, keeps>>


CPublishChild(p, c) ==
    /\ conv[p].pc = "staged"
    /\ c \in conv[p].members \ {conv[p].root}
    /\ staged[c]
    /\ staged' = [staged EXCEPT ![c] = FALSE]
    /\ pub' = [pub EXCEPT ![c] = "import"]
    /\ base' = [base EXCEPT ![c] = stagedBase[c]]
    /\ UNCHANGED <<v1ver, v1lock, writing, locks, bad, stagedBase, extra, conv,
                   req, out, refused, reqs, crashes, famOf, keeps>>

CPublishRoot(p) ==
    LET r == conv[p].root IN
    /\ conv[p].pc = "staged"
    /\ \A c \in conv[p].members \ {r} : ~staged[c]
    /\ staged' = [staged EXCEPT ![r] = FALSE]
    /\ pub' = [pub EXCEPT ![r] = "import"]
    /\ base' = [base EXCEPT ![r] = stagedBase[r]]
    /\ conv' = [conv EXCEPT ![p].pc = "published"]
    /\ famOf' = [famOf EXCEPT ![r] = conv[p].members]
    /\ UNCHANGED <<v1ver, v1lock, writing, locks, bad, stagedBase, extra, req,
                   out, refused, reqs, crashes, keeps>>




Deletable(p, i) ==
    /\ i \in conv[p].members /\ v1ver[i] > 0 /\ v1ver[i] = base[i]
    /\ i \in conv[p].copied \/ bad[i] = "ok"
    /\ i \notin keeps


CDelete(p, i) ==
    /\ conv[p].pc = "published"
    /\ Deletable(p, i)
    /\ i \notin refused[p]
    /\ v1ver' = [v1ver EXCEPT ![i] = 0]
    /\ UNCHANGED <<v1lock, writing, locks, bad, pub, base, staged, stagedBase,
                   extra, conv, req, out, refused, reqs, crashes, famOf, keeps>>


CDeleteRefused(p, i) ==
    /\ conv[p].pc = "published"
    /\ Deletable(p, i)
    /\ i \notin refused[p]
    /\ crashes < MaxCrash
    /\ refused' = [refused EXCEPT ![p] = @ \cup {i}]
    /\ crashes' = crashes + 1
    /\ UNCHANGED <<v1ver, v1lock, writing, locks, bad, pub, base, staged,
                   stagedBase, extra, conv, req, out, reqs, famOf, keeps>>



CFinish(p) ==
    /\ conv[p].pc = "published"
    /\ \A i \in conv[p].members : ~Deletable(p, i) \/ i \in refused[p]
    /\ v1lock' = [i \in Ids |-> IF i \in conv[p].members THEN "free" ELSE v1lock[i]]
    /\ conv' = [conv EXCEPT ![p] = Idle]
    /\ Answer(p, Done(p))
    /\ UNCHANGED <<v1ver, writing, locks, bad, pub, base, staged, stagedBase,
                   extra, refused, reqs, crashes, famOf, keeps>>



SWaiting(p) == req[p].kind = "recover" /\ conv[p] = Idle
OnlyV1(r) == pub[r] = "none" /\ v1ver[r] > 0



SElsewhere(p) ==
    /\ SWaiting(p)
    /\ ~OnlyV1(req[p].root)
    /\ Answer(p, IF Live(req[p].root) THEN "inv2" ELSE "notfound")
    /\ UNCHANGED <<v1ver, v1lock, writing, locks, bad, pub, base, staged,
                   stagedBase, extra, conv, refused, reqs, crashes, famOf,
                   keeps>>


SBegin(p) ==
    LET r == req[p].root IN
    /\ SWaiting(p)
    /\ OnlyV1(r)
    /\ IF v1lock[r] = "free"
       THEN /\ v1lock' = [v1lock EXCEPT ![r] = p]
            /\ conv' = [conv EXCEPT ![p] = [pc |-> "salvaging", root |-> r, members |-> {r}, copied |-> {}]]
            /\ UNCHANGED <<req, out>>
       ELSE /\ Answer(p, "busy")
            /\ UNCHANGED <<conv, v1lock>>
    /\ UNCHANGED <<v1ver, writing, locks, bad, pub, base, staged,
                   stagedBase, extra, refused, reqs, crashes, famOf, keeps>>





SFinish(p) ==
    LET r == conv[p].root
        free == {n \in NewIds : pub[n] = "none"} IN
    /\ conv[p].pc = "salvaging"
    /\ IF bad[r] = "salvage" /\ free # {}
       THEN \E n \in free : pub' = [pub EXCEPT ![n] = "salvage"]
       ELSE UNCHANGED pub
    /\ v1lock' = [v1lock EXCEPT ![r] = "free"]
    /\ conv' = [conv EXCEPT ![p] = Idle]
    /\ Answer(p, CASE bad[r] = "ok" -> "healthy"
                  [] bad[r] = "salvage" -> "recovered"
                  [] OTHER -> "unsalvageable")
    /\ UNCHANGED <<v1ver, writing, locks, bad, base, staged, stagedBase,
                   extra, refused, reqs, crashes, famOf, keeps>>

SalvStep(p) == SElsewhere(p) \/ SBegin(p) \/ SFinish(p)


CCrash(p) ==
    /\ req[p] # NoReq
    /\ crashes < MaxCrash
    /\ v1lock' = [i \in Ids |-> IF v1lock[i] = p THEN "free" ELSE v1lock[i]]
    /\ conv' = [conv EXCEPT ![p] = Idle]
    /\ req' = [req EXCEPT ![p] = NoReq]
    /\ out' = [out EXCEPT ![p] = [ans |-> "none", root |-> req[p].root]]
    /\ crashes' = crashes + 1
    /\ UNCHANGED <<v1ver, writing, locks, bad, pub, base, staged,
                   stagedBase, extra, refused, reqs, famOf, keeps>>


ConvWork(p) ==
    \/ AHeld(p) \/ AMissing(p) \/ CBegin(p) \/ CStage(p) \/ CPublishRoot(p) \/ CFinish(p)
    \/ SalvStep(p)
    \/ \E c \in Ids : CPublishChild(p, c) \/ CDelete(p, c) \/ CClean(p, c)


ConvRefused(p) == \E c \in Ids : CDeleteRefused(p, c) \/ CCleanRefused(p, c)

ConvStep(p) == ConvWork(p) \/ ConvRefused(p) \/ CCrash(p)

WriterStep(i) == WCreate(i) \/ WLock(i) \/ WBegin(i) \/ WEnd(i) \/ WUnlock(i) \/ WCrash(i)

Next ==
    \/ \E p \in Procs :
         \/ ConvStep(p)
         \/ \E k \in Kinds \ {"none"}, r \in Roots : Request(p, k, r)
    \/ \E i \in Ids : WriterStep(i) \/ Damage(i)
    \/ \E i \in AllIds : FCreate(i) \/ FAppend(i)

Spec == Init /\ [][Next]_vars



FairSpec ==
    /\ Spec
    /\ \A p \in Procs :
         /\ WF_vars(AHeld(p)) /\ WF_vars(AMissing(p)) /\ WF_vars(CBegin(p))
         /\ WF_vars(CStage(p)) /\ WF_vars(CPublishRoot(p)) /\ WF_vars(CFinish(p))
         /\ WF_vars(SElsewhere(p)) /\ WF_vars(SBegin(p)) /\ WF_vars(SFinish(p))
         /\ \A c \in Ids : WF_vars(CPublishChild(p, c)) /\ WF_vars(CDelete(p, c)) /\ WF_vars(CClean(p, c))
    /\ \A i \in Ids : WF_vars(WUnlock(i)) /\ WF_vars(WEnd(i))






LockHeld ==
    \A p \in Procs :
        conv[p].pc \in {"locked", "staged", "published", "salvaging"} =>
            \A i \in conv[p].members : v1lock[i] = p
CopyIsCurrent ==
    \A p \in Procs :
        conv[p].pc = "staged" =>
            \A i \in conv[p].members : staged[i] => stagedBase[i] = v1ver[i]
NoTornImport == \A i \in Ids : pub[i] = "import" => base[i] # Torn


NoStaleConvLock == \A p \in Procs : conv[p].pc = "idle" => \A i \in Ids : v1lock[i] # p



NoShadow == \A r \in Roots : v1ver[r] > 0 => pub[r] # "fresh"



ChildrenLanded ==
    \A r \in Roots : pub[r] = "import" => \A c \in famOf[r] \ {r} : pub[c] = "import"



OrphansKeepV1 == \A i \in Ids : Orphan(i) => v1ver[i] > 0


AnswerStep(p) == req[p] # NoReq /\ req'[p] = NoReq /\ out'[p].ans # "none"



AnsweredWhole ==
    [][\A p \in Procs :
         (AnswerStep(p) /\ out'[p].ans \in {"opened", "converted"}) =>
             (pub'[req[p].root] \in {"import", "fresh"} \/ v1ver'[req[p].root] = 0)]_vars


NoFalseNotFound ==
    [][\A p \in Procs :
         (AnswerStep(p) /\ out'[p].ans = "notfound") =>
             (pub'[req[p].root] = "none" /\ v1ver'[req[p].root] = 0)]_vars



NothingHalfConverted ==
    [][\A p \in Procs :
         /\ (AnswerStep(p) /\ out'[p].ans = "busy") =>
                (staged' = staged /\ pub' = pub /\ \A i \in Ids : v1lock'[i] # p)
         /\ (AnswerStep(p) /\ out'[p].ans = "unreadable") =>
                (pub' = pub /\ \A i \in Fam(req[p].root) : ~staged'[i] /\ v1lock'[i] # p)]_vars




NoLossOnDelete ==
    [][\A i \in Ids :
         (v1ver[i] > 0 /\ v1ver'[i] = 0) =>
             /\ pub[i] = "import" /\ pub'[i] = "import"
             /\ base[i] = v1ver[i] /\ ~writing[i]
             /\ v1lock[i] # "writer"
             /\ i \notin keeps]_vars





LeftoversGone ==
    [][\A p \in Procs :
         (AnswerStep(p) /\ out'[p].ans \in {"opened", "converted"}) =>
             \A i \in Fam(req[p].root) :
                 (pub'[i] = "import" /\ v1ver'[i] > 0 /\ v1ver'[i] = base'[i])
                     => (v1lock'[i] \in {"writer"} \cup (Procs \ {p}) \/ bad'[i] # "ok"
                         \/ i \in keeps \/ i \in refused'[p])]_vars


ConverterOnlyDeletes ==
    [][(\E p \in Procs : ConvStep(p)) =>
         /\ \A i \in Ids : v1ver'[i] \in {v1ver[i], 0}
         /\ UNCHANGED <<writing, bad>>]_vars


ConvertsOnlyOnRequest ==
    [][\A r \in Roots :
         (pub[r] = "none" /\ pub'[r] = "import") => \E p \in Procs : req[p].root = r]_vars



RootsStick ==
    [][\A i \in Roots \cup NewIds :
         Live(i) => (pub'[i] = pub[i] /\ base'[i] = base[i])]_vars
ChildrenStick ==
    [][\A c \in Ids :
         (Parent[c] # None /\ pub[c] = "import") => (pub'[c] = "import" /\ base'[c] = base[c])]_vars




SalvageLeavesSource ==
    [][\A p \in Procs :
         SalvStep(p) => /\ UNCHANGED <<v1ver, writing, bad, base, staged>>
                        /\ \A i \in Ids : pub'[i] = pub[i]]_vars




RefusedOnlyWithCause ==
    [][\A p \in Procs :
         LET r == req[p].root
             a == out'[p].ans IN
         AnswerStep(p) =>
             /\ a = "busy" => \E i \in Fam(r) : v1lock[i] \notin {"free", p}
             /\ a = "unreadable" => \E i \in Fam(r) : pub[i] = "none" /\ bad[i] # "ok"
             /\ a = "unsalvageable" => bad[r] = "lost"
             /\ a = "healthy" => bad[r] = "ok"
             /\ a = "recovered" => bad[r] = "salvage"]_vars


RequestsAnswered == \A p \in Procs : (req[p] # NoReq) ~> (req[p] = NoReq)
=============================================================================
