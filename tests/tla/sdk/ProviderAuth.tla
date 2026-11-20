---------------------------- MODULE ProviderAuth ----------------------------
















EXTENDS Naturals, FiniteSets

CONSTANTS
  Provider,
  Engines,
  Requests,
  EngineOf,
  UrlOf,
  Expiring,
  Rejecting,
  ForeignRefresh,
  CheckAccount,
  ScopeAll,
  NoSingleFlight,
  SharedMemory,
  Recheck,
  Lock


NoTok == 999
NoAcct == "none"
Refreshable == Provider # "custom"
Accounts == {"A", "B"}


Cred(at, rt, acct, fresh) == [at |-> at, rt |-> rt, acct |-> acct, fresh |-> fresh]
NoCred == Cred(NoTok, NoTok, NoAcct, TRUE)
Supplied0 == Cred(0, IF Refreshable THEN 0 ELSE NoTok, "A", ~Expiring)
NeedsRefresh(c) == c.rt # NoTok /\ ~c.fresh
Authorized(r) == ScopeAll \/ UrlOf[r] = "provider"
Mem(e) == IF SharedMemory THEN "agent" ELSE e
Memories == {Mem(e) : e \in Engines}

VARIABLES
  host,
  spent,
  reused,
  issued,
  acctOf,
  desc,
  tasks,
  req,
  ev

vars == <<host, spent, reused, issued, acctOf, desc, tasks, req, ev>>

Req(phase, supplied, used, sends, wait, status) ==
  [phase |-> phase, supplied |-> supplied, used |-> used, sends |-> sends, wait |-> wait, status |-> status]



Task(e, cur, sup, next, phase) == [e |-> e, cur |-> cur, sup |-> sup, next |-> next, phase |-> phase]

Init ==
  /\ host = Supplied0
  /\ spent = {}
  /\ reused = FALSE
  /\ issued = 0
  /\ acctOf = [n \in {0} |-> "A"]
  /\ desc = [m \in Memories |-> [n \in {} |-> NoCred]]
  /\ tasks = {}
  /\ req = [r \in Requests |-> Req("new", NoCred, NoCred, 0, NoTok, 0)]
  /\ ev = [k |-> "init"]


Best(e, s) == IF s.at \in DOMAIN desc[Mem(e)] THEN desc[Mem(e)][s.at] ELSE s

Running(e, rt) == {t \in tasks : Mem(t.e) = Mem(e) /\ t.cur.rt = rt /\ t.phase \in {"lock", "redeem", "verify", "save"}}


Holding == {t \in tasks : t.phase \in {"redeem", "verify", "save", "failed"}}


StartOrJoin(e, cur, sup) ==
  IF Running(e, cur.rt) # {} /\ ~NoSingleFlight
  THEN tasks' = tasks
  ELSE tasks' = tasks \cup {Task(e, cur, sup, NoCred, IF Lock THEN "lock" ELSE "redeem")}




Ask(r) ==
  LET e == EngineOf[r]
      best == Best(e, host)
  IN /\ req[r].phase = "new"
     /\ Authorized(r)
     /\ IF NeedsRefresh(best)
        THEN /\ StartOrJoin(e, best, host)
             /\ req' = [req EXCEPT ![r] = Req("wait", host, NoCred, 0, best.rt, 0)]
        ELSE /\ tasks' = tasks
             /\ req' = [req EXCEPT ![r] = Req("ready", host, best, 0, NoTok, 0)]
     /\ ev' = [k |-> "ask", r |-> r]
     /\ UNCHANGED <<host, spent, reused, issued, acctOf, desc>>

Bypass(r) ==
  /\ req[r].phase = "new"
  /\ ~Authorized(r)
  /\ req' = [req EXCEPT ![r] = Req("ready", NoCred, NoCred, 0, NoTok, 0)]
  /\ ev' = [k |-> "bypass", r |-> r]
  /\ UNCHANGED <<host, spent, reused, issued, acctOf, desc, tasks>>



Acquire(t) ==
  /\ t \in tasks
  /\ t.phase = "lock"
  /\ Holding = {}
  /\ LET newer == host.at # t.cur.at /\ host.at # t.sup.at /\ ~NeedsRefresh(host)
     IN tasks' = (tasks \ {t}) \cup {IF newer THEN [t EXCEPT !.next = host, !.phase = "save"] ELSE [t EXCEPT !.phase = "redeem"]}
  /\ ev' = [k |-> "acquire", e |-> t.e]
  /\ UNCHANGED <<host, spent, reused, issued, acctOf, desc, req>>



Redeem(t) ==
  /\ t \in tasks
  /\ t.phase = "redeem"
  /\ IF t.cur.rt \in spent
     THEN /\ reused' = TRUE
          /\ tasks' = (tasks \ {t}) \cup {[t EXCEPT !.phase = "failed"]}
          /\ ev' = [k |-> "redeem", e |-> t.e, rt |-> t.cur.rt, ok |-> FALSE, acct |-> NoAcct]
          /\ UNCHANGED <<spent, issued, acctOf>>
     ELSE \E acct \in (IF ForeignRefresh THEN Accounts ELSE {"A"}):
          LET n == issued + 1
              next == Cred(n, n, acct, TRUE)
          IN /\ spent' = spent \cup {t.cur.rt}
             /\ issued' = n
             /\ acctOf' = [x \in DOMAIN acctOf \cup {n} |-> IF x = n THEN acct ELSE acctOf[x]]
             /\ tasks' = (tasks \ {t}) \cup {[t EXCEPT !.next = next, !.phase = IF Provider = "grok" THEN "verify" ELSE "save"]}
             /\ ev' = [k |-> "redeem", e |-> t.e, rt |-> t.cur.rt, ok |-> TRUE, acct |-> acct]
             /\ UNCHANGED reused
  /\ UNCHANGED <<host, desc, req>>


Verify(t) ==
  /\ t \in tasks
  /\ t.phase = "verify"
  /\ LET refused == CheckAccount /\ t.next.acct # t.cur.acct
     IN tasks' = (tasks \ {t}) \cup {[t EXCEPT !.phase = IF refused THEN "failed" ELSE "save"]}
  /\ ev' = [k |-> "verify", e |-> t.e, at |-> t.next.at, acct |-> t.next.acct]
  /\ UNCHANGED <<host, spent, reused, issued, acctOf, desc, req>>




Save(t) ==
  /\ t \in tasks
  /\ t.phase = "save"
  /\ host' = t.next
  /\ desc' = [desc EXCEPT ![Mem(t.e)] = [x \in DOMAIN desc[Mem(t.e)] \cup {t.sup.at} |-> IF x = t.sup.at THEN t.next ELSE desc[Mem(t.e)][x]]]
  /\ tasks' = tasks \ {t}
  /\ req' = [r \in Requests |->
              IF Mem(EngineOf[r]) = Mem(t.e) /\ req[r].wait = t.cur.rt /\ req[r].phase \in {"wait", "rewait"}
              THEN [req[r] EXCEPT !.phase = "ready", !.used = t.next, !.wait = NoTok]
              ELSE req[r]]
  /\ ev' = [k |-> "save", e |-> t.e, at |-> t.next.at]
  /\ UNCHANGED <<spent, reused, issued, acctOf>>


Fail(t) ==
  /\ t \in tasks
  /\ t.phase = "failed"
  /\ tasks' = tasks \ {t}
  /\ req' = [r \in Requests |->
              IF Mem(EngineOf[r]) = Mem(t.e) /\ req[r].wait = t.cur.rt /\ req[r].phase \in {"wait", "rewait"}
              THEN [req[r] EXCEPT !.phase = "error", !.wait = NoTok]
              ELSE req[r]]
  /\ ev' = [k |-> "fail", e |-> t.e, rt |-> t.cur.rt]
  /\ UNCHANGED <<host, spent, reused, issued, acctOf, desc>>




Send(r) ==
  LET q == req[r]
      status == IF q.used.at = 0 /\ Rejecting THEN 401 ELSE 200
      retry == status = 401 /\ q.used.rt # NoTok /\ q.sends = 0
      e == EngineOf[r]
  IN /\ q.phase = "ready"
     /\ IF retry /\ Recheck
        THEN /\ tasks' = tasks
             /\ req' = [req EXCEPT ![r] = [q EXCEPT !.phase = "recheck", !.sends = 1, !.status = status]]
        ELSE IF retry
        THEN /\ StartOrJoin(e, q.used, q.supplied)
             /\ req' = [req EXCEPT ![r] = [q EXCEPT !.phase = "rewait", !.sends = 1, !.wait = q.used.rt, !.status = status]]
        ELSE /\ tasks' = tasks
             /\ req' = [req EXCEPT ![r] = [q EXCEPT !.phase = "done", !.sends = q.sends + 1, !.status = status]]
     /\ ev' = [k |-> "send", r |-> r, at |-> q.used.at, status |-> status]
     /\ UNCHANGED <<host, spent, reused, issued, acctOf, desc>>




RecheckAfter401(r) ==
  LET q == req[r]
      e == EngineOf[r]
      latest == Best(e, host)
  IN /\ q.phase = "recheck"
     /\ IF latest.at # q.used.at /\ NeedsRefresh(latest)
        THEN /\ StartOrJoin(e, latest, host)
             /\ req' = [req EXCEPT ![r] = [q EXCEPT !.phase = "rewait", !.supplied = host, !.wait = latest.rt]]
        ELSE IF latest.at # q.used.at
        THEN /\ tasks' = tasks
             /\ req' = [req EXCEPT ![r] = [q EXCEPT !.phase = "ready", !.supplied = host, !.used = latest]]
        ELSE /\ StartOrJoin(e, q.used, host)
             /\ req' = [req EXCEPT ![r] = [q EXCEPT !.phase = "rewait", !.supplied = host, !.wait = q.used.rt]]
     /\ ev' = [k |-> "ask", r |-> r]
     /\ UNCHANGED <<host, spent, reused, issued, acctOf, desc>>

Next ==
  \/ \E r \in Requests : Ask(r) \/ Bypass(r) \/ Send(r) \/ RecheckAfter401(r)
  \/ \E t \in tasks : Acquire(t) \/ Redeem(t) \/ Verify(t) \/ Save(t) \/ Fail(t)

Spec == Init /\ [][Next]_vars

Done == \A r \in Requests : req[r].phase \in {"done", "error"}

---------------------------------------------------------------------------



NoRefreshReuse == ~reused


AtMostOneResend == \A r \in Requests : req[r].sends <= 2


NoForeignToken ==
  /\ host.acct \in {"A", NoAcct}
  /\ \A r \in Requests : req[r].used.at = NoTok \/ acctOf[req[r].used.at] = "A"


ScopedAuth == \A r \in Requests : UrlOf[r] = "other" => req[r].used.at = NoTok


KeyNeverRefreshed == Provider = "custom" => issued = 0 /\ spent = {}

TypeOK ==
  /\ issued \in 0..4
  /\ \A r \in Requests : req[r].phase \in {"new", "wait", "ready", "rewait", "recheck", "done", "error"}
=============================================================================
