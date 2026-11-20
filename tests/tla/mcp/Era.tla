---- MODULE Era ----















EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Preferred,
    Legacy,
    Other,
    MaxProcesses


SmokePreferred == <<"m1", "m2">>
StressPreferred == <<"m1", "m2", "m3">>

ModernVersions == {Preferred[k] : k \in 1..Len(Preferred)}
Versions == ModernVersions \cup {Legacy} \cup Other
States == {"unknown", "probing", "initializing", "modern", "legacy", "failed"}
Ready == {"modern", "legacy"}

ASSUME Len(Preferred) > 0 /\ Legacy \notin ModernVersions /\ MaxProcesses \in Nat \ {0}

VARIABLES
    state,
    version,
    tried,
    pending,
    advertised,
    process,
    lastMeta,

    modernSeen,
    processEra,
    flipped,
    initializedSent,
    badFallback,
    earlyOp,
    unlisted

vars == <<state, version, tried, pending, advertised, process, lastMeta,
          modernSeen, processEra, flipped, initializedSent, badFallback, earlyOp, unlisted>>

ghosts == <<modernSeen, processEra, flipped, initializedSent, badFallback, earlyOp, unlisted>>

Init ==
    /\ state = "unknown"
    /\ version = "none"
    /\ tried = [v \in ModernVersions |-> 0]
    /\ pending = "none"
    /\ advertised = {}
    /\ process = 0
    /\ lastMeta = "unset"
    /\ modernSeen = FALSE
    /\ processEra = "none"
    /\ flipped = FALSE
    /\ initializedSent = 0
    /\ badFallback = FALSE
    /\ earlyOp = FALSE
    /\ unlisted = FALSE




NextCandidate(s) ==
    LET untried == {k \in 1..Len(Preferred) : Preferred[k] \in s /\ tried[Preferred[k]] = 0}
    IN IF untried # {}
          THEN Preferred[CHOOSE k \in untried : \A j \in untried : k <= j]
       ELSE IF version \in ModernVersions /\ version \in s /\ tried[version] = 1
          THEN version
       ELSE "none"


FirstShared(s) ==
    LET shared == {k \in 1..Len(Preferred) : Preferred[k] \in s}
    IN IF shared = {} THEN "none" ELSE Preferred[CHOOSE k \in shared : \A j \in shared : k <= j]

Probe(v) ==
    /\ state' = "probing"
    /\ version' = v
    /\ tried' = [tried EXCEPT ![v] = @ + 1]
    /\ pending' = "discover"



StartInitialize(sawModern, listed) ==
    /\ state' = "initializing"
    /\ version' = Legacy
    /\ pending' = "initialize"
    /\ badFallback' = (badFallback \/ (sawModern /\ Legacy \notin listed))
    /\ UNCHANGED tried

Fail ==
    /\ state' = "failed"
    /\ pending' = "none"
    /\ UNCHANGED <<version, tried>>

BecomeReady(era) ==
    /\ processEra' = IF processEra = "none" THEN era ELSE processEra
    /\ flipped' = (flipped \/ (processEra # "none" /\ processEra # era))


ProcessStarted ==
    /\ process < MaxProcesses
    /\ process' = process + 1
    /\ state' = "unknown"
    /\ version' = "none"
    /\ tried' = [v \in ModernVersions |-> 0]
    /\ pending' = "none"
    /\ advertised' = {}
    /\ lastMeta' = "unset"
    /\ modernSeen' = FALSE
    /\ processEra' = "none"
    /\ initializedSent' = 0
    /\ unlisted' = FALSE
    /\ UNCHANGED <<flipped, badFallback, earlyOp>>


DetectRequested ==
    /\ state = "unknown"
    /\ process > 0
    /\ Probe(Preferred[1])
    /\ UNCHANGED <<advertised, process, lastMeta, ghosts>>

DiscoverResult(s) ==
    /\ pending = "discover"
    /\ advertised' = s
    /\ modernSeen' = TRUE
    /\ LET chosen == FirstShared(s)
       IN IF chosen # "none"
             THEN /\ state' = "modern" /\ version' = chosen /\ pending' = "none"
                  /\ BecomeReady("modern") /\ UNCHANGED <<tried, badFallback>>
          ELSE IF Legacy \in s
             THEN StartInitialize(TRUE, s) /\ UNCHANGED <<processEra, flipped>>
          ELSE Fail /\ UNCHANGED <<processEra, flipped, badFallback>>
    /\ unlisted' = FALSE
    /\ UNCHANGED <<process, lastMeta, initializedSent, earlyOp>>



UnsupportedVersion(s) ==
    /\ pending = "discover"
    /\ advertised' = s
    /\ modernSeen' = TRUE
    /\ LET next == NextCandidate(s)
       IN IF next # "none"
             THEN Probe(next) /\ UNCHANGED badFallback
          ELSE IF Legacy \in s
             THEN StartInitialize(TRUE, s)
          ELSE Fail /\ UNCHANGED badFallback
    /\ unlisted' = FALSE
    /\ UNCHANGED <<process, lastMeta, processEra, flipped, initializedSent, earlyOp>>


ModernRejection ==
    /\ pending = "discover"
    /\ modernSeen' = TRUE
    /\ Fail
    /\ UNCHANGED <<advertised, process, lastMeta, processEra, flipped, initializedSent, badFallback, earlyOp, unlisted>>





LegacyAnswer ==
    /\ pending = "discover"
    /\ IF modernSeen /\ Legacy \notin advertised
          THEN Fail /\ UNCHANGED badFallback
          ELSE StartInitialize(modernSeen, advertised)
    /\ UNCHANGED <<advertised, process, lastMeta, modernSeen, processEra, flipped, initializedSent, earlyOp, unlisted>>

ProbeTimedOut == LegacyAnswer




DiscoverNotImplemented ==
    /\ pending = "discover"
    /\ state' = "modern"
    /\ pending' = "none"
    /\ modernSeen' = TRUE
    /\ unlisted' = TRUE
    /\ BecomeReady("modern")
    /\ UNCHANGED <<version, tried, advertised, process, lastMeta, initializedSent, badFallback, earlyOp>>



InitializeResult(v) ==
    /\ pending = "initialize"
    /\ IF v = Legacy
          THEN /\ state' = "legacy" /\ version' = v /\ pending' = "none" /\ initializedSent' = initializedSent + 1
               /\ BecomeReady("legacy") /\ UNCHANGED tried
          ELSE Fail /\ UNCHANGED <<initializedSent, processEra, flipped>>
    /\ UNCHANGED <<advertised, process, lastMeta, modernSeen, badFallback, earlyOp, unlisted>>




InitializeError(hint) ==
    /\ pending = "initialize"


    /\ IF hint /\ tried[Preferred[1]] < 2
          THEN Probe(Preferred[1]) /\ modernSeen' = TRUE
          ELSE Fail /\ UNCHANGED modernSeen
    /\ UNCHANGED <<advertised, process, lastMeta, processEra, flipped, initializedSent, badFallback, earlyOp, unlisted>>


InitializeTimedOut ==
    /\ pending = "initialize"
    /\ Fail
    /\ UNCHANGED <<advertised, process, lastMeta, modernSeen, processEra, flipped, initializedSent, badFallback, earlyOp, unlisted>>



MetaFor == IF state = "modern" THEN version ELSE "none"


OperationSent ==
    /\ state \in Ready
    /\ lastMeta' = MetaFor
    /\ earlyOp' = (earlyOp \/ state \notin Ready)
    /\ UNCHANGED <<state, version, tried, pending, advertised, process,
                   modernSeen, processEra, flipped, initializedSent, badFallback, unlisted>>



OperationVersionRejected(s) ==
    /\ state = "modern"
    /\ advertised' = s
    /\ LET next == NextCandidate(s)
       IN IF next # "none"
             THEN /\ version' = next /\ tried' = [tried EXCEPT ![next] = @ + 1]
                  /\ lastMeta' = "unset" /\ UNCHANGED <<state, pending>>
          ELSE Fail /\ UNCHANGED lastMeta
    /\ unlisted' = FALSE
    /\ UNCHANGED <<process, modernSeen, processEra, flipped, initializedSent, badFallback, earlyOp>>

Next ==
    \/ ProcessStarted
    \/ DetectRequested
    \/ \E s \in SUBSET Versions: DiscoverResult(s) \/ UnsupportedVersion(s) \/ OperationVersionRejected(s)
    \/ ModernRejection
    \/ LegacyAnswer
    \/ DiscoverNotImplemented
    \/ \E v \in Versions: InitializeResult(v)
    \/ \E hint \in BOOLEAN: InitializeError(hint)
    \/ InitializeTimedOut
    \/ OperationSent


Spec == Init /\ [][Next]_vars /\ WF_vars(ProbeTimedOut) /\ WF_vars(InitializeTimedOut)

TypeOK ==
    /\ state \in States
    /\ version \in Versions \cup {"none"}
    /\ tried \in [ModernVersions -> Nat]
    /\ pending \in {"none", "discover", "initialize"}
    /\ advertised \subseteq Versions
    /\ process \in 0..MaxProcesses
    /\ lastMeta \in Versions \cup {"none", "unset"}
    /\ modernSeen \in BOOLEAN
    /\ processEra \in {"none", "modern", "legacy"}
    /\ flipped \in BOOLEAN
    /\ initializedSent \in 0..1
    /\ badFallback \in BOOLEAN
    /\ earlyOp \in BOOLEAN
    /\ unlisted \in BOOLEAN




ProbesBounded == \A v \in ModernVersions: tried[v] <= 2


EraSticky == ~flipped



NoFallbackAfterModern == ~badFallback



LegacyOrder ==
    /\ ~earlyOp
    /\ state = "legacy" => initializedSent = 1


ChosenSupported ==
    /\ state = "modern" => version \in ModernVersions /\ (version \in advertised \/ unlisted)
    /\ state = "legacy" => version = Legacy


VersionOnEveryRequest ==
    /\ state = "modern" => lastMeta \in {"unset", version}
    /\ state = "legacy" => lastMeta \in {"unset", "none"}


ReachesEra == state \in {"probing", "initializing"} ~> state \in {"modern", "legacy", "failed", "unknown"}
====
