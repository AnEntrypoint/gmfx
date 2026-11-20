---------------------------- MODULE LaunchSelection ----------------------------



















EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
  Design,
  Mutant,
  Class

ASSUME Design \in {"current", "proposed"}
ASSUME Mutant \in {"none", "reject_weak", "no_canonical", "block_frame", "persist", "silent"}
ASSUME Class \in {"all", "ideal", "nonideal"}

VARIABLE st
vars == <<st>>



Paths      == {"ask", "interactive"}



ModelReqs  == {"none", "exact", "partial_unique", "partial_ambiguous", "unknown", "private_hidden"}
SpeedReqs  == {"none", "fast", "ultrafast", "off"}
EffortReqs == {"none", "supported", "unsupported"}

Catalogs   == {"authenticated", "anonymous", "failed", "absent"}

ScenarioSpace ==
  [path: Paths, model: ModelReqs, speed: SpeedReqs, effort: EffortReqs,
   catalog: Catalogs, fastCap: BOOLEAN, ultraCap: BOOLEAN, early: BOOLEAN]

Ideal(s) ==
  /\ s.catalog = "authenticated"
  /\ s.model \in {"none", "exact"}
  /\ s.speed = "fast" => s.fastCap
  /\ s.speed = "ultrafast" => s.ultraCap
  /\ s.effort # "unsupported"
  /\ ~s.early

Scenarios ==
  { s \in ScenarioSpace :
      /\ s.path = "ask" => ~s.early
      /\ CASE Class = "all"      -> TRUE
           [] Class = "ideal"    -> Ideal(s)
           [] Class = "nonideal" -> ~Ideal(s) }



Loaded(s)        == s.catalog \in {"authenticated", "anonymous"}
Authoritative(s) == s.catalog = "authenticated"


Match(s) ==
  IF ~Loaded(s) THEN "no_catalog"
  ELSE CASE s.model = "none"              -> "none"
         [] s.model = "exact"             -> "matched"
         [] s.model = "partial_unique"    -> "matched"
         [] s.model = "partial_ambiguous" -> "ambiguous"
         [] s.model = "unknown"           -> "unknown"
         [] s.model = "private_hidden"    -> IF Authoritative(s) THEN "matched" ELSE "unknown"



Name(s, m) == IF m = "raw" /\ s.model \in {"exact", "private_hidden"} THEN "canonical" ELSE m


GatewayAccepts(s, m) == Name(s, m) \in {"canonical", "configured"}



CapKnownFor(s, m) ==
  /\ Loaded(s)
  /\ \/ Name(s, m) = "configured"
     \/ /\ Name(s, m) = "canonical"
        /\ (s.model = "private_hidden" => Authoritative(s))




NoReq ==
  [ model |-> "none", claimedFast |-> FALSE, wireFast |-> FALSE, claimedUltra |-> FALSE,
    wireUltra |-> FALSE, claimedEffort |-> "none", wireEffort |-> "none", after |-> FALSE ]

Fresh(s) ==
  [ sc          |-> s,
    phase       |-> "start",
    catalogSeen |-> FALSE,
    sel         |-> [ model  |-> IF s.model = "none" THEN "configured" ELSE "raw",
                      fast   |-> s.speed = "fast",
                      ultra  |-> s.speed = "ultrafast",
                      effort |-> s.effort ],
    outcome     |-> "pending",
    req         |-> NoReq,
    corrections |-> {},
    notices     |-> {},
    persisted   |-> FALSE ]

Init == st \in { Fresh(s) : s \in Scenarios }

S == st.sc


ModelRejected(s) ==
  /\ Match(s) \in {"ambiguous", "unknown"}
  /\ (Authoritative(s) \/ Mutant = "reject_weak")

Resolved(s, cur) ==
  IF Match(s) = "matched" /\ Mutant # "no_canonical" THEN "canonical" ELSE cur



AskValidate ==
  /\ S.path = "ask"
  /\ st.phase = "start"
  /\ IF Design = "current"
       THEN st' = [st EXCEPT !.phase = "running"]
       ELSE LET m == Resolved(S, st.sel.model)
                k == CapKnownFor(S, m)
                reason ==
                  CASE ModelRejected(S)                                  -> "rejected_model"
                    [] st.sel.ultra /\ ~(k /\ S.ultraCap)                -> "rejected_ultrafast"
                    [] st.sel.fast /\ k /\ ~S.fastCap                    -> "rejected_fast"
                    [] st.sel.effort = "unsupported" /\ k                -> "rejected_effort"
                    [] OTHER                                             -> "none"
            IN st' = [st EXCEPT !.sel.model = m,
                                !.phase = IF reason = "none" THEN "running" ELSE "done",
                                !.outcome = IF reason = "none" THEN "pending" ELSE reason]



FirstFrame ==
  /\ S.path = "interactive"
  /\ st.phase = "start"
  /\ Mutant = "block_frame" => st.catalogSeen
  /\ st' = [st EXCEPT !.phase = "running"]

Corrected(s, sel) ==
  IF ModelRejected(s)
    THEN [ sel |-> [model |-> "configured", fast |-> FALSE, ultra |-> FALSE, effort |-> "none"],
           corrections |-> {"model"} ]
    ELSE LET m == Resolved(s, sel.model)
             k == CapKnownFor(s, m)
             fast   == sel.fast /\ ~(k /\ ~s.fastCap)
             ultra  == sel.ultra /\ k /\ s.ultraCap
             effort == IF sel.effort = "unsupported" /\ k THEN "none" ELSE sel.effort
         IN [ sel |-> [model |-> m, fast |-> fast, ultra |-> ultra, effort |-> effort],
              corrections |-> { c \in {"fast", "ultrafast", "effort"} :
                                  CASE c = "fast"      -> fast # sel.fast
                                    [] c = "ultrafast" -> ultra # sel.ultra
                                    [] c = "effort"    -> effort # sel.effort } ]

CatalogReady ==
  /\ S.path = "interactive"
  /\ ~st.catalogSeen
  /\ S.early => st.phase = "done"
  /\ IF Design = "current"
       THEN st' = [st EXCEPT !.catalogSeen = TRUE]
       ELSE LET c == Corrected(S, st.sel) IN
            st' = [st EXCEPT !.catalogSeen = TRUE,
                             !.sel = c.sel,
                             !.corrections = c.corrections,
                             !.notices = IF Mutant = "silent" THEN {} ELSE c.corrections,
                             !.persisted = Mutant = "persist" /\ c.corrections # {}]



Send ==
  /\ st.phase = "running"
  /\ S.path = "interactive" => (S.early <=> ~st.catalogSeen)
  /\ LET m == st.sel.model
         k == CapKnownFor(S, m)
     IN IF st.sel.ultra /\ ~(k /\ S.ultraCap)
          THEN st' = [st EXCEPT !.phase = "done", !.outcome = "turn_error"]
          ELSE st' = [st EXCEPT
                 !.phase = "done",
                 !.outcome = IF GatewayAccepts(S, m) THEN "sent" ELSE "gateway_error",
                 !.req = [ model        |-> Name(S, m),
                           claimedFast  |-> st.sel.fast,
                           wireFast     |-> st.sel.fast /\ k /\ S.fastCap,
                           claimedUltra |-> st.sel.ultra,
                           wireUltra    |-> st.sel.ultra,
                           claimedEffort |-> st.sel.effort,
                           wireEffort   |-> IF st.sel.effort = "supported" /\ k THEN "supported" ELSE "none",
                           after        |-> S.path = "ask" \/ st.catalogSeen ]]

Finished ==
  /\ st.phase = "done"
  /\ S.path = "interactive" => st.catalogSeen

Next ==
  \/ AskValidate
  \/ FirstFrame
  \/ CatalogReady
  \/ Send
  \/ (Finished /\ UNCHANGED vars)

Spec == Init /\ [][Next]_vars


FairSpec == Spec /\ WF_vars(Next)





Decided == st.req.after


ValidModel == Decided /\ Authoritative(S) => GatewayAccepts(S, st.req.model)


HonestSpeed ==
  Decided /\ CapKnownFor(S, st.req.model) =>
    /\ st.req.claimedFast = st.req.wireFast
    /\ st.req.claimedUltra = st.req.wireUltra


HonestEffort ==
  Decided /\ CapKnownFor(S, st.req.model) => st.req.claimedEffort = st.req.wireEffort


AskFailsEarly == S.path = "ask" => st.outcome # "turn_error"


NoFalseReject ==
  /\ (st.outcome = "rejected_model" \/ "model" \in st.corrections) =>
       Authoritative(S) /\ S.model \in {"partial_ambiguous", "unknown"}
  /\ (st.outcome = "rejected_fast" \/ "fast" \in st.corrections) =>
       CapKnownFor(S, st.sel.model) /\ ~S.fastCap
  /\ (st.outcome = "rejected_effort" \/ "effort" \in st.corrections) =>
       CapKnownFor(S, st.sel.model) /\ S.effort = "unsupported"
  /\ (st.outcome = "rejected_ultrafast" \/ "ultrafast" \in st.corrections) =>
       ~(CapKnownFor(S, st.sel.model) /\ S.ultraCap)


Canonical == Decided /\ S.model = "partial_unique" /\ Loaded(S) => st.req.model = "canonical"


SettingsUntouched == ~st.persisted


FirstFrameNotBlocked == (S.path = "interactive" /\ st.phase = "start") => ENABLED FirstFrame


CorrectionsAnnounced == st.corrections \subseteq st.notices


Termination == <>Finished
=============================================================================
