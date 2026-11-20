---------------------------- MODULE ShellSnapshot ----------------------------
























EXTENDS Integers, FiniteSets, TLC

CONSTANTS Cmds, MaxGen, Mutation

ASSUME MaxGen \in Nat \ {0}
ASSUME Mutation \in {"none", "no_single_flight", "free_while_leased",
                     "stale_grant", "reload_per_command", "notice_repeat",
                     "use_partial", "clear_dirty_late", "keep_broken"}

Gens    == 1..MaxGen
NoGen   == 0
NoGrant == -1

VARIABLES
    owner,
    active,
    capGen,
    inflight,
    nextGen,
    epoch,
    genEpoch,
    dirty,
    completed,
    leases,
    freed,
    broken,
    loads,
    triggers,
    fullRuns,
    failEpisodes,
    notices,
    noticeShown,
    grant,
    pc,
    auth,
    authEpoch,
    cgen,
    runEpoch

snapVars  == <<owner, active, capGen, inflight, nextGen, genEpoch, completed, freed, broken>>
countVars == <<loads, triggers, fullRuns, failEpisodes, notices, noticeShown>>
cmdVars   == <<pc, auth, authEpoch, cgen, runEpoch>>
vars      == <<snapVars, countVars, cmdVars, epoch, dirty, leases, grant>>

PcStates == {"idle", "admitted", "waiting", "run_snap", "run_full", "done"}

TypeOK ==
    /\ owner \in {"empty", "capturing", "ready", "failed"}
    /\ active \in 0..MaxGen
    /\ capGen \in 0..MaxGen
    /\ inflight \in 0..Cardinality(Cmds)
    /\ nextGen \in 1..(MaxGen + 1)
    /\ epoch \in Nat
    /\ genEpoch \in [Gens -> Nat]
    /\ dirty \in BOOLEAN
    /\ completed \subseteq Gens
    /\ freed \subseteq Gens
    /\ broken \subseteq Gens
    /\ leases \in [Gens -> 0..Cardinality(Cmds)]
    /\ loads \in Nat /\ triggers \in Nat /\ fullRuns \in Nat
    /\ failEpisodes \in Nat /\ notices \in Nat
    /\ noticeShown \in BOOLEAN
    /\ grant \in {NoGrant} \cup Nat
    /\ pc \in [Cmds -> PcStates]
    /\ auth \in [Cmds -> {"none", "grant", "explicit"}]
    /\ authEpoch \in [Cmds -> Nat]
    /\ cgen \in [Cmds -> 0..MaxGen]
    /\ runEpoch \in [Cmds -> Nat]

Init ==
    /\ owner = "empty"
    /\ active = NoGen
    /\ capGen = NoGen
    /\ inflight = 0
    /\ nextGen = 1
    /\ epoch = 0
    /\ genEpoch = [g \in Gens |-> 0]
    /\ dirty = FALSE
    /\ completed = {}
    /\ leases = [g \in Gens |-> 0]
    /\ freed = {}
    /\ broken = {}
    /\ loads = 0
    /\ triggers = 0
    /\ fullRuns = 0
    /\ failEpisodes = 0
    /\ notices = 0
    /\ noticeShown = FALSE
    /\ grant = NoGrant
    /\ pc = [c \in Cmds |-> "idle"]
    /\ auth = [c \in Cmds |-> "none"]
    /\ authEpoch = [c \in Cmds |-> 0]
    /\ cgen = [c \in Cmds |-> NoGen]
    /\ runEpoch = [c \in Cmds |-> 0]

Pending(c) == pc[c] \in {"admitted", "waiting"}

-----------------------------------------------------------------------------



AdmitByGrant(c) ==
    /\ pc[c] = "idle"
    /\ grant # NoGrant
    /\ (grant = epoch \/ Mutation = "stale_grant")
    /\ pc' = [pc EXCEPT ![c] = "admitted"]
    /\ auth' = [auth EXCEPT ![c] = "grant"]
    /\ authEpoch' = [authEpoch EXCEPT ![c] = grant]
    /\ UNCHANGED <<snapVars, countVars, epoch, dirty, leases, grant, cgen, runEpoch>>

AdmitExplicit(c) ==
    /\ pc[c] = "idle"
    /\ \E remember \in BOOLEAN : grant' = IF remember THEN epoch ELSE grant
    /\ pc' = [pc EXCEPT ![c] = "admitted"]
    /\ auth' = [auth EXCEPT ![c] = "explicit"]
    /\ UNCHANGED <<snapVars, countVars, epoch, dirty, leases, authEpoch, cgen, runEpoch>>


ReAsk(c) ==
    /\ pc' = [pc EXCEPT ![c] = "idle"]
    /\ auth' = [auth EXCEPT ![c] = "none"]
    /\ UNCHANGED <<snapVars, countVars, epoch, dirty, leases, grant, authEpoch, cgen, runEpoch>>

-----------------------------------------------------------------------------


NeedsCapture ==
    \/ owner = "empty"
    \/ (owner \in {"ready", "failed"} /\ dirty)

StartCapture(c) ==
    /\ Pending(c)
    /\ \/ NeedsCapture
       \/ (Mutation = "no_single_flight" /\ owner = "capturing")
    /\ nextGen <= MaxGen
    /\ owner' = "capturing"
    /\ capGen' = nextGen
    /\ nextGen' = nextGen + 1
    /\ inflight' = inflight + 1
    /\ genEpoch' = [genEpoch EXCEPT ![nextGen] = epoch]


    /\ dirty' = IF Mutation = "clear_dirty_late" THEN dirty ELSE FALSE
    /\ loads' = loads + 1
    /\ pc' = [pc EXCEPT ![c] = "waiting"]
    /\ UNCHANGED <<active, completed, freed, broken, triggers, fullRuns, failEpisodes,
                   notices, noticeShown, epoch, leases, grant, auth, authEpoch,
                   cgen, runEpoch>>


Retire(g, f) ==
    IF g # NoGen /\ (leases[g] = 0 \/ Mutation = "free_while_leased")
    THEN f \cup {g}
    ELSE f

CaptureOk ==
    /\ owner = "capturing"
    /\ owner' = "ready"
    /\ active' = capGen
    /\ capGen' = NoGen
    /\ inflight' = inflight - 1
    /\ completed' = completed \cup {capGen}
    /\ freed' = Retire(active, freed)
    /\ noticeShown' = FALSE
    /\ dirty' = IF Mutation = "clear_dirty_late" THEN FALSE ELSE dirty
    /\ UNCHANGED <<nextGen, genEpoch, broken, loads, triggers, fullRuns, failEpisodes,
                   notices, epoch, leases, grant, cmdVars>>




CaptureFail ==
    /\ owner = "capturing"
    /\ owner' = "failed"
    /\ active' = NoGen
    /\ capGen' = NoGen
    /\ inflight' = inflight - 1
    /\ freed' = Retire(active, freed) \cup {capGen}
    /\ failEpisodes' = failEpisodes + 1
    /\ noticeShown' = FALSE
    /\ dirty' = IF Mutation = "clear_dirty_late" THEN FALSE ELSE dirty
    /\ UNCHANGED <<nextGen, genEpoch, completed, broken, loads, triggers, fullRuns,
                   notices, epoch, leases, grant, cmdVars>>

Acquire(c) ==
    /\ Pending(c)
    /\ \/ (owner = "ready" /\ ~dirty)
       \/ (Mutation = "use_partial" /\ owner = "capturing")
    /\ LET g == IF owner = "ready" THEN active ELSE capGen
       IN  IF auth[c] = "grant" /\ authEpoch[c] # genEpoch[g] /\ Mutation # "stale_grant"
           THEN ReAsk(c)
           ELSE /\ leases' = [leases EXCEPT ![g] = @ + 1]
                /\ cgen' = [cgen EXCEPT ![c] = g]
                /\ runEpoch' = [runEpoch EXCEPT ![c] = genEpoch[g]]
                /\ pc' = [pc EXCEPT ![c] = "run_snap"]
                /\ loads' = IF Mutation = "reload_per_command" THEN loads + 1 ELSE loads
                /\ UNCHANGED <<snapVars, triggers, fullRuns, failEpisodes, notices,
                               noticeShown, epoch, dirty, grant, auth, authEpoch>>

RunFull(c) ==
    /\ Pending(c)
    /\ owner = "failed"
    /\ ~dirty
    /\ IF auth[c] = "grant" /\ authEpoch[c] # epoch /\ Mutation # "stale_grant"
       THEN ReAsk(c)
       ELSE /\ pc' = [pc EXCEPT ![c] = "run_full"]
            /\ runEpoch' = [runEpoch EXCEPT ![c] = epoch]
            /\ loads' = loads + 1
            /\ fullRuns' = fullRuns + 1
            /\ notices' = IF ~noticeShown \/ Mutation = "notice_repeat"
                          THEN notices + 1
                          ELSE notices
            /\ noticeShown' = TRUE
            /\ UNCHANGED <<snapVars, triggers, failEpisodes, epoch, dirty, leases,
                           grant, auth, authEpoch, cgen>>

Finish(c) ==
    /\ pc[c] \in {"run_snap", "run_full"}
    /\ pc' = [pc EXCEPT ![c] = "done"]
    /\ IF pc[c] = "run_snap"
       THEN /\ leases' = [leases EXCEPT ![cgen[c]] = @ - 1]
            /\ freed' = IF cgen[c] # active /\ cgen[c] # capGen /\ leases[cgen[c]] = 1
                        THEN freed \cup {cgen[c]}
                        ELSE freed
            /\ cgen' = [cgen EXCEPT ![c] = NoGen]
       ELSE UNCHANGED <<leases, freed, cgen>>
    /\ UNCHANGED <<owner, active, capGen, inflight, nextGen, genEpoch, completed,
                   broken, countVars, epoch, dirty, grant, auth, authEpoch, runEpoch>>





ReplayFail(c) ==
    /\ pc[c] = "run_snap"
    /\ LET g         == cgen[c]
           holds     == owner = "ready" /\ active = g
           lastLease == leases[g] = 1
       IN  /\ broken' = broken \cup {g}
           /\ leases' = [leases EXCEPT ![g] = @ - 1]
           /\ cgen' = [cgen EXCEPT ![c] = NoGen]
           /\ pc' = [pc EXCEPT ![c] = "run_full"]
           /\ loads' = loads + 1
           /\ fullRuns' = fullRuns + 1
           /\ IF holds /\ Mutation # "keep_broken"
              THEN /\ owner' = "failed"
                   /\ active' = NoGen
                   /\ freed' = IF lastLease THEN freed \cup {g} ELSE freed
                   /\ failEpisodes' = failEpisodes + 1
                   /\ notices' = notices + 1
                   /\ noticeShown' = TRUE
              ELSE /\ freed' = IF g # active /\ g # capGen /\ lastLease
                               THEN freed \cup {g}
                               ELSE freed
                   /\ UNCHANGED <<owner, active, failEpisodes, notices, noticeShown>>
    /\ UNCHANGED <<capGen, inflight, nextGen, genEpoch, completed, triggers,
                   epoch, dirty, grant, auth, authEpoch, runEpoch>>


Cancel(c) ==
    /\ Pending(c)
    /\ pc' = [pc EXCEPT ![c] = "done"]
    /\ UNCHANGED <<snapVars, countVars, epoch, dirty, leases, grant, auth,
                   authEpoch, cgen, runEpoch>>


MarkDirty ==
    /\ ~dirty
    /\ nextGen <= MaxGen
    /\ dirty' = TRUE
    /\ epoch' = epoch + 1
    /\ triggers' = triggers + 1
    /\ UNCHANGED <<snapVars, loads, fullRuns, failEpisodes, notices, noticeShown,
                   leases, grant, cmdVars>>

Done ==
    /\ \A c \in Cmds : pc[c] = "done"
    /\ UNCHANGED vars

Next ==
    \/ \E c \in Cmds :
          \/ AdmitByGrant(c)
          \/ AdmitExplicit(c)
          \/ StartCapture(c)
          \/ Acquire(c)
          \/ RunFull(c)
          \/ Finish(c)
          \/ ReplayFail(c)
          \/ Cancel(c)
    \/ CaptureOk
    \/ CaptureFail
    \/ MarkDirty
    \/ Done

Fairness ==
    /\ WF_vars(CaptureOk \/ CaptureFail)
    /\ \A c \in Cmds : WF_vars(StartCapture(c) \/ Acquire(c) \/ RunFull(c))
    /\ \A c \in Cmds : WF_vars(Finish(c))

Spec       == Init /\ [][Next]_vars /\ Fairness
SafetySpec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------



SingleFlight == inflight <= 1


NoUseAfterFree == \A c \in Cmds : pc[c] = "run_snap" => cgen[c] \notin freed


FreeOnlyUnleased == \A g \in freed : leases[g] = 0


RunsCompleteSnapshot == \A c \in Cmds : pc[c] = "run_snap" => cgen[c] \in completed


NoLeak ==
    \A g \in 1..(nextGen - 1) :
        (g # active /\ g # capGen /\ leases[g] = 0) => g \in freed



DotfilesPaidOnce == loads <= 1 + triggers + fullRuns


GrantMatchesEpoch ==
    \A c \in Cmds :
        (pc[c] \in {"run_snap", "run_full"} /\ auth[c] = "grant")
            => authEpoch[c] = runEpoch[c]


NoticeOncePerEpisode == notices <= failEpisodes



NoReuseOfBroken == owner = "ready" => active \notin broken


FreshWhenClean == (owner = "ready" /\ ~dirty) => genEpoch[active] = epoch

-----------------------------------------------------------------------------


CaptureResolves == (owner = "capturing") ~> (owner \in {"ready", "failed"})

EveryCallProgresses ==
    \A c \in Cmds :
        (pc[c] \in {"admitted", "waiting"})
            ~> (pc[c] \in {"run_snap", "run_full", "done", "idle"})

EveryRunFinishes ==
    \A c \in Cmds : (pc[c] \in {"run_snap", "run_full"}) ~> (pc[c] = "done")

=============================================================================
