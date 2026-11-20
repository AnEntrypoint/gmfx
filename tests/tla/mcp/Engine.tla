---- MODULE Engine ----



























EXTENDS Naturals, FiniteSets

CONSTANTS Servers, Calls, Owner(_), MaxAttempts, MaxHost

ASSUME MaxAttempts \in Nat \ {0} /\ MaxHost \in Nat /\ \A c \in Calls: Owner(c) \in Servers

Phases == {"idle", "connecting", "ready", "backoff", "failed"}
CallStates == {"none", "waiting", "sent", "done"}


Ends == {"none", "denied", "failed", "cancelled", "answered", "lost"}

VARIABLES phase, attempts, need, call, ended, allowed, cause, host,
    retry,
    stayed,
    dropped,
    asked

vars == <<phase, attempts, need, call, ended, allowed, cause, host, retry, stayed, dropped, asked>>

Waiting(s) == {c \in Calls: Owner(c) = s /\ call[c] = "waiting"}
Sent(s) == {c \in Calls: Owner(c) = s /\ call[c] = "sent"}
Demand(s) == need[s] \/ Waiting(s) # {}

TypeOK ==
    /\ phase \in [Servers -> Phases]
    /\ attempts \in [Servers -> 0..MaxAttempts]
    /\ need \in [Servers -> BOOLEAN]
    /\ call \in [Calls -> CallStates]
    /\ ended \in [Calls -> Ends]
    /\ allowed \in [Calls -> BOOLEAN]
    /\ cause \in [Servers -> BOOLEAN]
    /\ host \in 0..MaxHost
    /\ retry \in [Servers -> BOOLEAN]
    /\ stayed \in [Servers -> BOOLEAN]
    /\ dropped \in [Servers -> BOOLEAN]
    /\ asked \in [Servers -> BOOLEAN]

Init ==
    /\ phase = [s \in Servers |-> "idle"]
    /\ attempts = [s \in Servers |-> 0]
    /\ need = [s \in Servers |-> FALSE]
    /\ call = [c \in Calls |-> "none"]
    /\ ended = [c \in Calls |-> "none"]
    /\ allowed = [c \in Calls |-> FALSE]
    /\ cause = [s \in Servers |-> FALSE]
    /\ host = 0
    /\ retry = [s \in Servers |-> FALSE]
    /\ stayed = [s \in Servers |-> FALSE]
    /\ dropped = [s \in Servers |-> FALSE]
    /\ asked = [s \in Servers |-> FALSE]






Ask(c, ok) ==
    /\ call[c] = "none"
    /\ allowed' = [allowed EXCEPT ![c] = ok]
    /\ LET s == Owner(c) IN
       /\ call' = [call EXCEPT ![c] =
              IF ~ok \/ phase[s] = "failed" THEN "done"
              ELSE IF phase[s] = "ready" THEN "sent" ELSE "waiting"]
       /\ ended' = [ended EXCEPT ![c] =
              IF ~ok THEN "denied" ELSE IF phase[s] = "failed" THEN "failed" ELSE "none"]
    /\ UNCHANGED <<phase, attempts, need, cause, host, retry, stayed, dropped, asked>>



Need(s) ==
    /\ ~need[s]
    /\ phase[s] \notin {"ready", "failed"}
    /\ need' = [need EXCEPT ![s] = TRUE]
    /\ asked' = [asked EXCEPT ![s] = TRUE]
    /\ UNCHANGED <<phase, attempts, call, ended, allowed, cause, host, retry, stayed, dropped>>



Cancel(c) ==
    /\ call[c] = "waiting"
    /\ call' = [call EXCEPT ![c] = "done"]
    /\ ended' = [ended EXCEPT ![c] = "cancelled"]
    /\ UNCHANGED <<phase, attempts, need, allowed, cause, host, retry, stayed, dropped, asked>>





Drop(s, keep) ==
    /\ host < MaxHost
    /\ host' = host + 1
    /\ phase' = [phase EXCEPT ![s] = "idle"]
    /\ attempts' = [attempts EXCEPT ![s] = 0]
    /\ need' = [need EXCEPT ![s] = need[s] /\ keep]
    /\ call' = [c \in Calls |-> IF c \in Sent(s) \/ (~keep /\ c \in Waiting(s)) THEN "done" ELSE call[c]]
    /\ ended' = [c \in Calls |-> IF c \in Sent(s) \/ (~keep /\ c \in Waiting(s)) THEN "cancelled" ELSE ended[c]]
    /\ retry' = [retry EXCEPT ![s] = FALSE]
    /\ dropped' = [dropped EXCEPT ![s] = TRUE]

    /\ asked' = [asked EXCEPT ![s] = asked[s] /\ keep]
    /\ UNCHANGED <<allowed, cause, stayed>>





Connect(s) ==
    /\ phase[s] = "idle"
    /\ Demand(s) \/ retry[s]
    /\ attempts[s] < MaxAttempts
    /\ phase' = [phase EXCEPT ![s] = "connecting"]
    /\ attempts' = [attempts EXCEPT ![s] = @ + 1]
    /\ cause' = [cause EXCEPT ![s] = Demand(s) \/ retry[s]]
    /\ stayed' = [stayed EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<need, call, ended, allowed, host, retry, dropped, asked>>



Up(s) ==
    /\ phase[s] = "connecting"
    /\ phase' = [phase EXCEPT ![s] = "ready"]
    /\ need' = [need EXCEPT ![s] = FALSE]
    /\ call' = [c \in Calls |-> IF c \in Waiting(s) THEN "sent" ELSE call[c]]
    /\ retry' = [retry EXCEPT ![s] = FALSE]
    /\ asked' = [asked EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<attempts, ended, allowed, cause, host, stayed, dropped>>


Stable(s) ==
    /\ phase[s] = "ready" /\ attempts[s] > 0
    /\ attempts' = [attempts EXCEPT ![s] = 0]
    /\ stayed' = [stayed EXCEPT ![s] = TRUE]
    /\ UNCHANGED <<phase, need, call, ended, allowed, cause, host, retry, dropped, asked>>





Down(s) ==
    /\ phase[s] \in {"connecting", "ready"}
    /\ LET gaveUp == attempts[s] >= MaxAttempts IN
       /\ phase' = [phase EXCEPT ![s] = IF gaveUp THEN "failed" ELSE "backoff"]
       /\ need' = [need EXCEPT ![s] = need[s] /\ ~gaveUp]
       /\ call' = [c \in Calls |-> IF c \in Sent(s) \/ c \in Waiting(s) THEN "done" ELSE call[c]]
       /\ ended' = [c \in Calls |-> IF c \in Sent(s) THEN "lost"
                                    ELSE IF c \in Waiting(s) THEN "failed" ELSE ended[c]]
       /\ retry' = [retry EXCEPT ![s] = ~gaveUp]
       /\ asked' = [asked EXCEPT ![s] = asked[s] /\ ~gaveUp]
    /\ dropped' = [dropped EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<attempts, allowed, cause, host, stayed>>

BackoffOver(s) ==
    /\ phase[s] = "backoff"
    /\ phase' = [phase EXCEPT ![s] = "idle"]
    /\ UNCHANGED <<attempts, need, call, ended, allowed, cause, host, retry, stayed, dropped, asked>>


Answer(c) ==
    /\ call[c] = "sent"
    /\ call' = [call EXCEPT ![c] = "done"]
    /\ ended' = [ended EXCEPT ![c] = "answered"]
    /\ UNCHANGED <<phase, attempts, need, allowed, cause, host, retry, stayed, dropped, asked>>

Next ==
    \/ \E c \in Calls, ok \in BOOLEAN: Ask(c, ok)
    \/ \E c \in Calls: Cancel(c) \/ Answer(c)
    \/ \E s \in Servers: Need(s) \/ Connect(s) \/ Up(s) \/ Down(s) \/ BackoffOver(s) \/ Stable(s)
    \/ \E s \in Servers, keep \in BOOLEAN: Drop(s, keep)

Fairness ==
    /\ \A s \in Servers: WF_vars(Connect(s)) /\ WF_vars(Up(s) \/ Down(s)) /\ WF_vars(BackoffOver(s))
    /\ \A c \in Calls: WF_vars(Answer(c))

Spec == Init /\ [][Next]_vars /\ Fairness


SmokeOwner(c) == IF c <= 2 THEN 1 ELSE 2




PermissionBeforeCall ==
    \A c \in Calls: (call[c] \in {"waiting", "sent"} \/ ended[c] \in {"answered", "lost"}) => allowed[c]


DeniedEndsThere == \A c \in Calls: ended[c] = "denied" => call[c] = "done" /\ ~allowed[c]


LazyConnect == \A s \in Servers: phase[s] = "connecting" => cause[s]



RetryOnlyAfterFailure ==
    \A s \in Servers: retry[s] => ~dropped[s] /\ phase[s] \in {"backoff", "idle", "connecting"}



StayedBeforeFreshTries == \A s \in Servers: phase[s] = "ready" /\ attempts[s] = 0 => stayed[s]


BoundedReconnect ==
    \A s \in Servers: phase[s] = "failed" => attempts[s] = MaxAttempts



StatusConsistent ==
    /\ \A c \in Calls: call[c] = "sent" => phase[Owner(c)] = "ready"
    /\ \A s \in Servers: phase[s] = "failed" => ~need[s] /\ Waiting(s) = {}
    /\ \A s \in Servers: phase[s] = "ready" => ~need[s] /\ Waiting(s) = {}



AskedHasNeed == \A s \in Servers: asked[s] => need[s]




Isolation ==
    [][\A s \in Servers:
        (phase'[s] # phase[s]) =>
            /\ \A t \in Servers \ {s}: phase'[t] = phase[t]
            /\ \A c \in Calls: Owner(c) # s => call'[c] = call[c]]_vars



WaitsForOneStart ==
    [][\A s \in Servers:
        (phase[s] \in {"connecting", "ready"} /\ phase'[s] \in {"backoff", "failed"}) =>
            \A c \in Calls: Owner(c) = s => call'[c] # "waiting"]_vars


EveryCallEnds == \A c \in Calls: call[c] \in {"waiting", "sent"} ~> call[c] = "done"
NeedServed == \A s \in Servers: need[s] ~> ~need[s]



RetriesEnd == \A s \in Servers: retry[s] ~> ~retry[s]
====
