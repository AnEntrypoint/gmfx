--------------------------- MODULE V1ConversionTrace ---------------------------


































EXTENDS V1Conversion, ConversionData, Sequences, TLC

VARIABLE l
tvars == <<vars, l>>

ASSUME TLCSet(1, 0)

P1 == "p1"
P2 == "p2"


Made(o) == CASE o.k = "open2" -> 2 [] o.k \in {"open", "all", "crash", "recover"} -> 1 [] OTHER -> 0
RECURSIVE ReqCount(_)
ReqCount(n) == IF n = 0 THEN 0 ELSE Made(Obs[n]) + ReqCount(n - 1)


ConvAllowed(p, o) == ConvWork(p) \/ (o.denied /\ ConvRefused(p))



HolderStep(i) == WBegin(i) \/ WEnd(i)


Hidden(o, n) ==
    CASE o.k \in {"create", "write", "hold", "release"} ->
            \E i \in Ids : WriterStep(i)
      [] o.k = "damage" -> \E i \in Ids : Damage(i)
      [] o.k = "fresh" -> \E i \in NewIds : FCreate(i) \/ FAppend(i)
      [] o.k \in {"open", "all", "recover"} ->
            \/ reqs < ReqCount(n) /\ Request(P1, o.k, o.r)
            \/ ConvAllowed(P1, o)
            \/ \E i \in Ids : HolderStep(i)
            \/ req[P1] = NoReq /\ reqs = ReqCount(n) /\ \E i \in AllIds : FAppend(i)
      [] o.k = "open2" ->
            \/ reqs = ReqCount(n) - 2 /\ Request(P1, "open", o.r)
            \/ reqs = ReqCount(n) - 1 /\ Request(P2, "open", o.r)
            \/ \E p \in {P1, P2} : ConvAllowed(p, o)
            \/ \E i \in Ids : HolderStep(i)
            \/ req[P1] = NoReq /\ req[P2] = NoReq /\ reqs = ReqCount(n) /\ \E i \in AllIds : FAppend(i)
      [] o.k = "crash" ->
            \/ reqs < ReqCount(n) /\ \E kk \in {"open", "all"} : Request(P1, kk, o.r)
            \/ ConvAllowed(P1, o) \/ CCrash(P1)
            \/ \E i \in Ids : HolderStep(i)
      [] OTHER -> FALSE

Match(o, n) ==
    /\ v1ver = o.v1
    /\ pub = o.pub
    /\ \A i \in AllIds : pub[i] = "import" => base[i] = o.base[i]
    /\ extra = o.extra
    /\ Dirty = o.dirty
    /\ Listed = o.listed
    /\ bad = o.bad
    /\ keeps = o.keeps
    /\ {i \in Ids : v1lock[i] = "writer"} = o.held
    /\ reqs = ReqCount(n)
    /\ \A p \in Procs : req[p] = NoReq /\ conv[p] = Idle
    /\ o.k \in {"open", "all", "recover"} => out[P1].ans = o.ans
    /\ o.k = "open2" =>
         \/ out[P1].ans = o.ans /\ out[P2].ans = o.ans2
         \/ out[P1].ans = o.ans2 /\ out[P2].ans = o.ans
    /\ o.k = "crash" => out[P1].ans = "none"

TraceInit == Init /\ l = 1

TraceNext ==
    /\ l <= Len(Obs)
    /\ \/ Hidden(Obs[l], l) /\ UNCHANGED l
       \/ Match(Obs[l], l) /\ l' = l + 1 /\ UNCHANGED vars

TraceSpec == TraceInit /\ [][TraceNext]_tvars

Progress ==
    IF l - 1 > TLCGet(1)
    THEN TLCSet(1, l - 1) /\ PrintT(<<"matched_lines", l - 1>>)
    ELSE TRUE

NotDone == l <= Len(Obs)
=============================================================================
