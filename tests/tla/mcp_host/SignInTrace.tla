---- MODULE SignInTrace ----



















EXTENDS SignIn, TraceObs, Sequences

VARIABLES i, bad

Viol ==
    (IF RedeemOnlyLiveState THEN {} ELSE {"RedeemOnlyLiveState"}) \cup
    (IF ListenerTakesOnlyItsOwn THEN {} ELSE {"ListenerTakesOnlyItsOwn"}) \cup
    (IF NoListenerWithoutHost THEN {} ELSE {"NoListenerWithoutHost"}) \cup
    (IF OneSignInPerHost THEN {} ELSE {"OneSignInPerHost"}) \cup
    (IF IndicatorImpliesListener THEN {} ELSE {"IndicatorImpliesListener"}) \cup
    (IF OneSignInPerServer THEN {} ELSE {"OneSignInPerServer"}) \cup
    (IF FlowHasListener THEN {} ELSE {"FlowHasListener"})

Probed(k, result) ==
    /\ IF result = "open" THEN phase[k] = "open" /\ alive[hostOf[k]] ELSE ~Open(k)
    /\ UNCHANGED vars

Step(rec) ==
    CASE rec.event = "login" -> StartLogin \/ AgainLogin
      [] rec.event = "authorize" -> Authorize(rec.data.login)
      [] rec.event = "probe" -> Probed(rec.data.login, rec.data.result)
      [] rec.event = "callback" -> Arrive(rec.data.login, rec.data.state, rec.data.kind)
      [] rec.event = "redeem" -> Handle(rec.data.login) /\ phase'[rec.data.login] = "redeeming"
      [] rec.event = "signed_in" -> Redeemed(rec.data.login, TRUE)
      [] rec.event = "failed" -> \/ Handle(rec.data.login) /\ phase'[rec.data.login] = "closed"
                                 \/ Redeemed(rec.data.login, FALSE)
                                 \/ Expire(rec.data.login)
      [] rec.event = "reload" -> IF rec.data.server = "kept" THEN ReloadKeeps ELSE ReloadDrops
      [] rec.event = "replace" -> Replace
      [] rec.event = "lease" -> Lease
      [] rec.event = "release" -> \E h \in Hosts : Release(h)
      [] rec.event = "status" -> indicator = rec.data.signing /\ UNCHANGED vars
      [] OTHER -> FALSE

TraceInit == Init /\ i = 0 /\ bad = Viol

TraceNext ==
    /\ i < Len(ObsTrace)
    /\ Step(ObsTrace[i + 1])
    /\ i' = i + 1
    /\ bad' = bad \cup Viol'

NotDone == i < Len(ObsTrace)
NotDoneClean == i < Len(ObsTrace) \/ bad # {}
NotDoneDirty == i < Len(ObsTrace) \/ bad = {}
====
