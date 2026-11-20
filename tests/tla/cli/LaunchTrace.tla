---------------------------- MODULE LaunchTrace ----------------------------




















EXTENDS LaunchSelection, LaunchObserved, Sequences

VARIABLE k
traceVars == <<st, k>>

Starts(o) ==
  { Fresh([o.sc EXCEPT !.early = e]) : e \in (IF o.orderFree THEN BOOLEAN ELSE {o.sc.early}) }

IndicatorMatches(r, i) ==
  i = "unobserved" \/ ((r.claimedFast \/ r.claimedUltra) <=> (i = "on"))

ReqMatches(r, o) ==
  IF ~o.present
    THEN r.model = "none"
    ELSE /\ r.model = o.model
         /\ IndicatorMatches(r, o.indicator)
         /\ r.wireFast = o.wireFast
         /\ r.wireUltra = o.wireUltra
         /\ r.wireEffort = o.wireEffort

Matches(o) ==
  /\ Finished
  /\ st.outcome = o.outcome
  /\ st.notices = o.notices
  /\ ReqMatches(st.req, o.req)

TraceInit == k = 1 /\ st \in Starts(Observed[1])

Step ==
  /\ k <= Len(Observed)
  /\ (AskValidate \/ FirstFrame \/ CatalogReady \/ Send)
  /\ UNCHANGED k

Advance ==
  /\ k <= Len(Observed)
  /\ Matches(Observed[k])
  /\ k' = k + 1
  /\ IF k + 1 <= Len(Observed) THEN st' \in Starts(Observed[k + 1]) ELSE UNCHANGED st

TraceSpec == TraceInit /\ [][Step \/ Advance]_traceVars


NotAllMatched == k <= Len(Observed)
=============================================================================
