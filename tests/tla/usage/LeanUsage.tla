---------------------------- MODULE LeanUsage ----------------------------









EXTENDS Naturals, FiniteSets

CONSTANTS Procs, Idents, None, FLOOR, TIMER, DAY, MAXT

ASSUME FLOOR \in Nat \ {0} /\ TIMER \in Nat /\ TIMER > FLOOR /\ DAY \in Nat \ {0}

VARIABLES
    now,
    ident,
    open,
    inflight,
    lastStart,
    failedAt,
    cache,
    shown,
    finCount

vars == <<now, ident, open, inflight, lastStart, failedAt, cache, shown, finCount>>

Day(t) == t \div DAY
Days == 0..Day(MAXT)
Times == 0..MAXT
Opt(S) == S \cup {None}

EmptyRec == [todayDay |-> None, todayAt |-> None, finDay |-> None]




ViewOf(c, i, t) ==
    [ident |-> i,
     today |-> IF c[i].todayDay = Day(t) THEN c[i].todayAt ELSE None,
     finCurrent |-> c[i].finDay = Day(t)]

Hidden == [ident |-> None, today |-> None, finCurrent |-> FALSE]

TypeOK ==
    /\ now \in Times
    /\ ident \in [Procs -> Idents]
    /\ open \in [Procs -> BOOLEAN]
    /\ inflight \in [Procs -> Opt([ident : Idents, at : Times, fin : BOOLEAN])]
    /\ lastStart \in [Procs -> Opt(Times)]
    /\ failedAt \in [Procs -> Opt(Times)]
    /\ cache \in [Idents -> [todayDay : Opt(Days), todayAt : Opt(Times), finDay : Opt(Days)]]
    /\ finCount \in [Procs -> [Idents -> [Days -> Nat]]]

Init ==
    /\ now = 0
    /\ ident \in [Procs -> Idents]
    /\ open = [p \in Procs |-> FALSE]
    /\ inflight = [p \in Procs |-> None]
    /\ lastStart = [p \in Procs |-> None]
    /\ failedAt = [p \in Procs |-> None]
    /\ cache = [i \in Idents |-> EmptyRec]
    /\ shown = [p \in Procs |-> Hidden]
    /\ finCount = [p \in Procs |-> [i \in Idents |-> [d \in Days |-> 0]]]





Since(t, n) == IF t = None THEN TRUE ELSE now - t >= n

FloorClear(p) ==
    /\ inflight[p] = None
    /\ Since(lastStart[p], FLOOR)
    /\ Since(failedAt[p], FLOOR)



StartFetch(p) ==
    LET i == ident[p]
        fin == cache[i].finDay # Day(now)
    IN /\ inflight' = [inflight EXCEPT ![p] = [ident |-> i, at |-> now, fin |-> fin]]
       /\ lastStart' = [lastStart EXCEPT ![p] = now]

Tick ==
    /\ now < MAXT
    /\ now' = now + 1


    /\ shown' = [p \in Procs |-> IF open[p] THEN ViewOf(cache, ident[p], now + 1) ELSE shown[p]]
    /\ UNCHANGED <<ident, open, inflight, lastStart, failedAt, cache, finCount>>


Open(p) ==
    /\ ~open[p]
    /\ open' = [open EXCEPT ![p] = TRUE]
    /\ shown' = [shown EXCEPT ![p] = ViewOf(cache, ident[p], now)]
    /\ IF FloorClear(p)
       THEN StartFetch(p)
       ELSE UNCHANGED <<inflight, lastStart>>
    /\ UNCHANGED <<now, ident, failedAt, cache, finCount>>

Close(p) ==
    /\ open[p]
    /\ open' = [open EXCEPT ![p] = FALSE]
    /\ shown' = [shown EXCEPT ![p] = Hidden]
    /\ UNCHANGED <<now, ident, inflight, lastStart, failedAt, cache, finCount>>



Redraw(p) == [shown EXCEPT ![p] = IF open[p] THEN ViewOf(cache, ident[p], now) ELSE shown[p]]


Manual(p) ==
    /\ open[p]
    /\ FloorClear(p)
    /\ StartFetch(p)
    /\ shown' = Redraw(p)
    /\ UNCHANGED <<now, ident, open, failedAt, cache, finCount>>


Timer(p) ==
    /\ open[p]
    /\ FloorClear(p)
    /\ lastStart[p] # None
    /\ Since(lastStart[p], TIMER)
    /\ StartFetch(p)
    /\ shown' = Redraw(p)
    /\ UNCHANGED <<now, ident, open, failedAt, cache, finCount>>




Complete(p) ==
    LET f == inflight[p]
        i == f.ident
        newer == IF cache[i].todayAt = None THEN TRUE ELSE f.at >= cache[i].todayAt
        rec == [todayDay |-> Day(f.at),
                todayAt |-> f.at,
                finDay |-> IF f.fin THEN Day(f.at) ELSE cache[i].finDay]
        c2 == IF newer THEN [cache EXCEPT ![i] = rec] ELSE cache
    IN /\ f # None
       /\ cache' = c2
       /\ inflight' = [inflight EXCEPT ![p] = None]
       /\ failedAt' = [failedAt EXCEPT ![p] = None]
       /\ shown' = [q \in Procs |->
                       IF q = p /\ open[q] THEN ViewOf(c2, ident[q], now) ELSE shown[q]]
       /\ finCount' = IF newer /\ f.fin
                      THEN [finCount EXCEPT ![p][i][Day(f.at)] = @ + 1]
                      ELSE finCount
       /\ UNCHANGED <<now, ident, open, lastStart>>


Fail(p) ==
    /\ inflight[p] # None
    /\ inflight' = [inflight EXCEPT ![p] = None]
    /\ failedAt' = [failedAt EXCEPT ![p] = now]
    /\ shown' = Redraw(p)
    /\ UNCHANGED <<now, ident, open, lastStart, cache, finCount>>




Switch(p, j) ==
    /\ j # ident[p]
    /\ ident' = [ident EXCEPT ![p] = j]
    /\ shown' = [shown EXCEPT ![p] = IF open[p] THEN ViewOf(cache, j, now) ELSE Hidden]
    /\ UNCHANGED <<now, open, inflight, lastStart, failedAt, cache, finCount>>

Next ==
    \/ Tick
    \/ \E p \in Procs :
          \/ Open(p) \/ Close(p) \/ Manual(p) \/ Timer(p) \/ Complete(p) \/ Fail(p)
          \/ \E j \in Idents : Switch(p, j)

Spec == Init /\ [][Next]_vars

---------------------------------------------------------------------------



ShowsOwnIdentity == \A p \in Procs : open[p] => shown[p].ident = ident[p]


TodayIsToday ==
    \A p \in Procs : open[p] /\ shown[p].today # None => Day(shown[p].today) = Day(now)



FinishedOncePerDay ==
    \A p \in Procs, i \in Idents, d \in Days : finCount[p][i][d] <= 1


FinishedBounded ==
    \A i \in Idents, d \in Days :
        LET total[S \in SUBSET Procs] ==
                IF S = {} THEN 0
                ELSE LET q == CHOOSE x \in S : TRUE IN finCount[q][i][d] + total[S \ {q}]
        IN total[Procs] <= Cardinality(Procs)


FetchRules ==
    [][\A p \in Procs :
         (inflight[p] = None /\ inflight'[p] # None) =>
             /\ open[p] \/ open'[p]
             /\ Since(lastStart[p], FLOOR)]_vars


CacheNeverRegresses ==
    [][\A i \in Idents :
         IF cache[i].todayAt = None THEN TRUE
         ELSE cache'[i].todayAt # None /\ cache'[i].todayAt >= cache[i].todayAt]_vars
=============================================================================
