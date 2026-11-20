---- MODULE SignIn ----



































EXTENDS Naturals, FiniteSets

CONSTANTS
    MaxLogins,
    MaxHosts,
    MaxLeases,
    Bridge

Logins == 1..MaxLogins
Hosts == 1..MaxHosts
States == 0..MaxLogins



Kinds == {"get", "form_ours", "form_foreign", "other"}
Phases == {"unused", "open", "consumed", "redeeming", "closed"}

VARIABLES
    cur, alive, retired, leases,
    phase,

    hostOf,
    got,
    live,
    flow,
    shownUrl,
    indicator,
    saved,
    next,
    badRedeem,
    foreignTaken

vars == <<cur, alive, retired, leases, phase, hostOf, got, live, flow, shownUrl, indicator, saved, next, badRedeem, foreignTaken>>

Open(k) == phase[k] \in {"open", "consumed", "redeeming"}

TypeOK ==
    /\ cur \in Hosts /\ alive \in [Hosts -> BOOLEAN] /\ retired \in [Hosts -> BOOLEAN]
    /\ leases \in [Hosts -> 0..MaxLeases]
    /\ phase \in [Logins -> Phases]
    /\ hostOf \in [Logins -> 0..MaxHosts]
    /\ got \in [Logins -> States]
    /\ live \in [Hosts -> 0..MaxLogins]
    /\ flow \in [Hosts -> States]
    /\ shownUrl \in [Logins -> BOOLEAN]
    /\ indicator \in BOOLEAN /\ saved \in BOOLEAN
    /\ next \in 1..(MaxLogins + 1)
    /\ badRedeem \in BOOLEAN /\ foreignTaken \in BOOLEAN

Init ==
    /\ cur = 1 /\ alive = [h \in Hosts |-> h = 1] /\ retired = [h \in Hosts |-> FALSE]
    /\ leases = [h \in Hosts |-> 0]
    /\ phase = [k \in Logins |-> "unused"]
    /\ hostOf = [k \in Logins |-> 0]
    /\ got = [k \in Logins |-> 0]
    /\ live = [h \in Hosts |-> 0]
    /\ flow = [h \in Hosts |-> 0]
    /\ shownUrl = [k \in Logins |-> FALSE]
    /\ indicator = FALSE /\ saved = FALSE
    /\ next = 1
    /\ badRedeem = FALSE /\ foreignTaken = FALSE


Ended(k) == [phase EXCEPT ![k] = "closed"]


SigningIn(h) == live[h] # 0 /\ Open(live[h])





StartLogin ==
    /\ alive[cur] /\ next <= MaxLogins
    /\ \A h \in Hosts : alive[h] => h = cur
    /\ ~SigningIn(cur)
    /\ LET k == next
       IN /\ phase' = [phase EXCEPT ![k] = "open"]
          /\ hostOf' = [hostOf EXCEPT ![k] = cur]
          /\ live' = [live EXCEPT ![cur] = k]
          /\ flow' = IF flow[cur] = 0 THEN [flow EXCEPT ![cur] = k] ELSE flow
          /\ next' = next + 1
    /\ UNCHANGED <<cur, alive, retired, leases, got, shownUrl, indicator, saved, badRedeem, foreignTaken>>




AgainLogin ==
    /\ alive[cur]
    /\ \A h \in Hosts : alive[h] => h = cur
    /\ SigningIn(cur)
    /\ UNCHANGED vars



Authorize(k) ==
    /\ phase[k] = "open" /\ alive[hostOf[k]] /\ live[hostOf[k]] = k /\ ~shownUrl[k]
    /\ shownUrl' = [shownUrl EXCEPT ![k] = TRUE]
    /\ indicator' = TRUE
    /\ UNCHANGED <<cur, alive, retired, leases, phase, hostOf, got, live, flow, saved, next, badRedeem, foreignTaken>>





Takes(kind) == IF Bridge THEN kind = "form_ours" ELSE kind = "get"

Arrive(k, s, kind) ==
    /\ phase[k] = "open"
    /\ IF Takes(kind) /\ s = k
       THEN /\ phase' = [phase EXCEPT ![k] = "consumed"]
            /\ got' = [got EXCEPT ![k] = s]
            /\ foreignTaken' = (foreignTaken \/ kind \in {"form_foreign", "other"} \/ s # k)
       ELSE UNCHANGED <<phase, got, foreignTaken>>
    /\ UNCHANGED <<cur, alive, retired, leases, hostOf, live, flow, shownUrl, indicator, saved, next, badRedeem>>



Paste(k, s) ==
    /\ phase[k] = "open"
    /\ phase' = [phase EXCEPT ![k] = "consumed"]
    /\ got' = [got EXCEPT ![k] = s]
    /\ UNCHANGED <<cur, alive, retired, leases, hostOf, live, flow, shownUrl, indicator, saved, next, badRedeem, foreignTaken>>


Handle(k) ==
    /\ phase[k] = "consumed" /\ alive[hostOf[k]] /\ live[hostOf[k]] = k
    /\ LET h == hostOf[k]
           ok == flow[h] # 0 /\ got[k] = flow[h]
       IN IF ok
          THEN /\ phase' = [phase EXCEPT ![k] = "redeeming"]
               /\ badRedeem' = (badRedeem \/ got[k] # flow[h])
               /\ UNCHANGED <<live, flow, indicator>>
          ELSE
               /\ phase' = Ended(k)
               /\ live' = [live EXCEPT ![h] = 0]
               /\ flow' = [flow EXCEPT ![h] = 0]
               /\ indicator' = FALSE
               /\ UNCHANGED badRedeem
    /\ UNCHANGED <<cur, alive, retired, leases, hostOf, got, shownUrl, saved, next, foreignTaken>>



Redeemed(k, ok) ==
    /\ phase[k] = "redeeming" /\ alive[hostOf[k]]
    /\ LET h == hostOf[k]
       IN /\ phase' = Ended(k)
          /\ live' = [live EXCEPT ![h] = 0]
          /\ flow' = [flow EXCEPT ![h] = 0]
          /\ indicator' = FALSE
          /\ saved' = (saved \/ ok)
    /\ UNCHANGED <<cur, alive, retired, leases, hostOf, got, shownUrl, next, badRedeem, foreignTaken>>


Expire(k) ==
    /\ Open(k) /\ alive[hostOf[k]] /\ live[hostOf[k]] = k
    /\ LET h == hostOf[k]
       IN /\ phase' = Ended(k)
          /\ live' = [live EXCEPT ![h] = 0]
          /\ flow' = [flow EXCEPT ![h] = 0]
          /\ indicator' = FALSE
    /\ UNCHANGED <<cur, alive, retired, leases, hostOf, got, shownUrl, saved, next, badRedeem, foreignTaken>>



Gone(h, ph) == [k \in Logins |-> IF hostOf[k] = h /\ Open(k) THEN "closed" ELSE ph[k]]
SignsIn(h) == \E k \in Logins : hostOf[k] = h /\ Open(k)
GoneIndicator(h) == IF SignsIn(h) THEN FALSE ELSE indicator

Lease ==
    /\ alive[cur] /\ leases[cur] < MaxLeases
    /\ leases' = [leases EXCEPT ![cur] = @ + 1]
    /\ UNCHANGED <<cur, alive, retired, phase, hostOf, got, live, flow, shownUrl, indicator, saved, next, badRedeem, foreignTaken>>

Release(h) ==
    /\ leases[h] > 0
    /\ leases' = [leases EXCEPT ![h] = @ - 1]
    /\ IF retired[h] /\ leases[h] = 1
       THEN /\ alive' = [alive EXCEPT ![h] = FALSE]
            /\ phase' = Gone(h, phase)
            /\ live' = [live EXCEPT ![h] = 0]
            /\ flow' = [flow EXCEPT ![h] = 0]
            /\ indicator' = GoneIndicator(h)
       ELSE UNCHANGED <<alive, phase, live, flow, indicator>>
    /\ UNCHANGED <<cur, retired, hostOf, got, shownUrl, saved, next, badRedeem, foreignTaken>>





ReloadDrops ==
    /\ alive[cur]
    /\ IF SigningIn(cur)
       THEN /\ phase' = Ended(live[cur])
            /\ live' = [live EXCEPT ![cur] = 0]
            /\ indicator' = FALSE
       ELSE UNCHANGED <<phase, live, indicator>>
    /\ flow' = [flow EXCEPT ![cur] = 0]
    /\ UNCHANGED <<cur, alive, retired, leases, hostOf, got, shownUrl, saved, next, badRedeem, foreignTaken>>


ReloadKeeps == alive[cur] /\ UNCHANGED vars


Replace ==
    /\ cur < MaxHosts
    /\ LET n == cur + 1
           free == leases[cur] = 0
       IN /\ cur' = n
          /\ retired' = [retired EXCEPT ![cur] = TRUE]
          /\ alive' = [alive EXCEPT ![n] = TRUE, ![cur] = ~free]
          /\ phase' = IF free THEN Gone(cur, phase) ELSE phase
          /\ live' = IF free THEN [live EXCEPT ![cur] = 0] ELSE live
          /\ flow' = IF free THEN [flow EXCEPT ![cur] = 0] ELSE flow
          /\ indicator' = IF free THEN GoneIndicator(cur) ELSE indicator
    /\ UNCHANGED <<leases, hostOf, got, shownUrl, saved, next, badRedeem, foreignTaken>>

Next ==
    \/ StartLogin
    \/ AgainLogin
    \/ \E k \in Logins : Authorize(k) \/ Handle(k) \/ Expire(k) \/ Redeemed(k, TRUE) \/ Redeemed(k, FALSE)
    \/ \E k \in Logins, s \in States, kind \in Kinds : Arrive(k, s, kind)
    \/ \E k \in Logins, s \in States : Paste(k, s)
    \/ Lease
    \/ \E h \in Hosts : Release(h)
    \/ ReloadKeeps
    \/ ReloadDrops
    \/ Replace

    \/ UNCHANGED vars

Fairness ==
    /\ \A k \in Logins : WF_vars(Authorize(k)) /\ WF_vars(Handle(k)) /\ WF_vars(Expire(k))
                         /\ WF_vars(Redeemed(k, TRUE) \/ Redeemed(k, FALSE))
    /\ \A h \in Hosts : WF_vars(Release(h))

Spec == Init /\ [][Next]_vars /\ Fairness




RedeemOnlyLiveState == ~badRedeem




ListenerTakesOnlyItsOwn == ~foreignTaken


NoListenerWithoutHost == \A k \in Logins : Open(k) => alive[hostOf[k]]


OneSignInPerHost == \A h \in Hosts : Cardinality({k \in Logins : hostOf[k] = h /\ Open(k)}) <= 1


IndicatorImpliesListener == indicator => \E k \in Logins : Open(k) /\ alive[hostOf[k]]


OneSignInPerServer == Cardinality({k \in Logins : Open(k)}) <= 1



FlowHasListener == \A h \in Hosts : flow[h] # 0 => live[h] = flow[h] /\ Open(flow[h])


KeptSignInGoesOn == [][ReloadKeeps => \A k \in Logins : Open(k) => Open(k)']_vars




EveryLoginEnds == \A k \in Logins : Open(k) ~> ~Open(k)


IndicatorClears == indicator ~> ~indicator
====
