------------------------- MODULE AcpPermissionModes -------------------------




























EXTENDS Naturals, Sequences

CONSTANTS Profiles,
          Values

ModeSeq == <<"auto", "ask", "full-access">>
Modes == {ModeSeq[k] : k \in 1..Len(ModeSeq)}
ModesCsv == "auto,ask,full-access"
NamesCsv == "Auto,Ask,Full access"
DefaultMode == "auto"

Eff(p) == IF p = "unset" THEN DefaultMode ELSE p



Enforce(m) ==
    CASE m = "ask" -> "asked/no-run"
      [] m = "auto" -> "reviewed/ran"
      [] m = "full-access" -> "direct/ran"

VARIABLES profile, cur, saved, last
vars == <<profile, cur, saved, last>>

NoView == [current |-> "", legacy |-> "", listed |-> "", legacyListed |-> "",
           names |-> "", schemaOk |-> TRUE]


SessionView(m) == [current |-> m, legacy |-> m, listed |-> ModesCsv,
                   legacyListed |-> ModesCsv, names |-> NamesCsv, schemaOk |-> TRUE]


ConfigView(m) == [SessionView(m) EXCEPT !.legacy = "n/a", !.legacyListed = "n/a"]


StatusView(m) == ConfigView(m)

Obs(op, arg, ok, hasView, view, enforce, stored) ==
    [op |-> op, arg |-> arg, ok |-> ok, hasView |-> hasView, view |-> view,
     enforce |-> enforce, stored |-> stored]

Init ==
    /\ profile \in Profiles
    /\ cur = Eff(profile)
    /\ saved = FALSE
    /\ last = Obs("new", "none", TRUE, TRUE, SessionView(Eff(profile)), "none", profile)

SetConfig(v) ==
    IF v \in Modes
    THEN /\ cur' = v
         /\ profile' = v
         /\ last' = Obs("set", v, TRUE, TRUE, ConfigView(v), "none", v)
         /\ UNCHANGED saved
    ELSE /\ last' = Obs("set", v, FALSE, FALSE, NoView, "none", profile)
         /\ UNCHANGED <<profile, cur, saved>>


SetLegacy(v) ==
    IF v \in Modes
    THEN /\ cur' = v
         /\ profile' = v
         /\ last' = Obs("legacy", v, TRUE, FALSE, NoView, "none", v)
         /\ UNCHANGED saved
    ELSE /\ last' = Obs("legacy", v, FALSE, FALSE, NoView, "none", profile)
         /\ UNCHANGED <<profile, cur, saved>>

Prompt ==
    /\ saved' = TRUE
    /\ last' = Obs("prompt", "none", TRUE, FALSE, NoView, Enforce(cur), profile)
    /\ UNCHANGED <<profile, cur>>


Resume ==
    /\ saved
    /\ LET resumed == Eff(profile) IN
           /\ cur' = resumed
           /\ last' = Obs("resume", "none", TRUE, TRUE, SessionView(resumed), "none", profile)
    /\ UNCHANGED <<profile, saved>>


Fresh ==
    /\ LET started == Eff(profile) IN
           /\ cur' = started
           /\ last' = Obs("fresh", "none", TRUE, TRUE, SessionView(started), "none", profile)
    /\ saved' = FALSE
    /\ UNCHANGED profile


NewSession ==
    /\ LET opened == Eff(profile) IN
           /\ cur' = opened
           /\ last' = Obs("new", "none", TRUE, TRUE, SessionView(opened), "none", profile)
    /\ saved' = FALSE
    /\ UNCHANGED profile



External(v) ==
    /\ profile' = v
    /\ last' = Obs("other", v, TRUE, FALSE, NoView, "none", v)
    /\ UNCHANGED <<cur, saved>>


Status ==
    /\ last' = Obs("status", "none", TRUE, TRUE, StatusView(Eff(profile)), "none", profile)
    /\ UNCHANGED <<profile, cur, saved>>

Next ==
    \/ \E v \in Values : SetConfig(v) \/ SetLegacy(v)
    \/ \E v \in Modes : External(v)
    \/ Prompt
    \/ Resume
    \/ Fresh
    \/ NewSession
    \/ Status

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------



EnforceTable == [m \in Modes |->
                    IF m = "ask" THEN "asked/no-run"
                    ELSE IF m = "auto" THEN "reviewed/ran"
                    ELSE "direct/ran"]

SessionOps == {"new", "resume", "fresh"}
ChangeOps == {"set", "legacy"}

ListsExactlyCliModes ==
    last.hasView =>
        /\ last.view.listed = ModesCsv
        /\ last.view.names = NamesCsv
        /\ last.view.legacyListed \in {ModesCsv, "n/a"}

SchemaClean == last.hasView => last.view.schemaOk

ReportsEnforcedMode ==
    (last.hasView /\ last.op # "status") => /\ last.view.current = cur
                                            /\ last.view.legacy \in {cur, "n/a"}


StatusMatchesNextSession == last.op = "status" => last.view.current = Eff(profile)

SessionsStartFromProfile ==
    last.op \in SessionOps => /\ cur = Eff(profile)
                              /\ last.view.legacy = cur
                              /\ last.view.legacyListed = ModesCsv

DefaultIsAuto ==
    (last.op \in SessionOps /\ profile = "unset") => cur = "auto"

UnknownRejected == last.op \in ChangeOps => (last.ok <=> last.arg \in Modes)

ChangeIsSaved ==
    (last.op \in ChangeOps /\ last.ok) => /\ cur = last.arg
                                          /\ profile = last.arg

StoredIsProfile == last.stored = profile

PromptEnforcesMode == last.op = "prompt" => last.enforce = EnforceTable[cur]

TypeOK ==
    /\ profile \in Modes \cup {"unset"}
    /\ cur \in Modes
    /\ saved \in BOOLEAN


RejectedChangesNothing ==
    [][(last'.op \in ChangeOps /\ ~last'.ok) => UNCHANGED <<profile, cur>>]_vars


OpenSessionKeepsMode == [][last'.op = "other" => cur' = cur]_vars



FullAccessOnlyByChoice ==
    [][(cur' = "full-access" /\ cur # "full-access") =>
           \/ (last'.op \in ChangeOps /\ last'.arg = "full-access")
           \/ (last'.op \in SessionOps /\ profile' = "full-access")]_vars
=============================================================================
