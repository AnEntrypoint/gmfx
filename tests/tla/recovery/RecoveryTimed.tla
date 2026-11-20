---------------------------- MODULE RecoveryTimed ----------------------------
















EXTENDS Recovery

CONSTANTS
    Ceiling,
    SendTicks,
    HandoffTicks,
    HealTicks

ASSUME /\ Ceiling \in 1..10 /\ SendTicks \in 1..5 /\ HandoffTicks \in 1..SendTicks
       /\ HealTicks \in Nat

VARIABLES
    waitLeft,
    fresh,
    sendAge,
    healAge

timeVars == <<waitLeft, fresh, sendAge, healAge>>
tvars == <<vars, timeVars>>

TTypeOK ==
    /\ TypeOK
    /\ waitLeft \in 0..(Ceiling + 1)
    /\ fresh \in BOOLEAN
    /\ sendAge \in 0..SendTicks
    /\ healAge \in 0..(HealTicks + 1)


Healthy == net = "up" /\ gateway = "ok" /\ ~needUser


LongHint == Ceiling + 1





Waits(hinted) ==
    (1..Ceiling) \cup
        (IF hinted THEN {IF Bug = "unbounded_wait" THEN LongHint ELSE Ceiling}
                   ELSE {})


NewSend == inflight' /\ ~inflight



Follow(A, hinted) ==
    /\ A
    /\ waitLeft' \in IF phase' = "waiting" /\ phase # "waiting" THEN Waits(hinted)
                     ELSE IF phase' = "waiting" THEN {waitLeft}
                     ELSE {0}
    /\ fresh' = (fresh \/ status' # status \/ NewSend)
    /\ sendAge' = IF inflight' /\ inflight THEN sendAge ELSE 0
    /\ healAge' = IF faults' > faults \/ ~alive' THEN 0 ELSE healAge




MustRefresh == phase = "waiting"



HandOffDue ==
    /\ phase = "working" /\ inflight /\ ~flowing /\ status = "retrying"
    /\ sendAge + 1 >= HandoffTicks



Tick ==
    /\ alive /\ phase \in Active
    /\ (inflight => sendAge < SendTicks)
    /\ healAge' = IF Healthy /\ phase # "need_user"
                     THEN Min(healAge + 1, HealTicks + 1) ELSE 0
    /\ sendAge' = IF inflight THEN sendAge + 1 ELSE 0
    /\ IF phase = "waiting" /\ waitLeft <= 1

          THEN /\ TimerFires
               /\ waitLeft' = 0 /\ fresh' = TRUE


          ELSE IF HandOffDue /\ Bug # "no_handoff"
          THEN /\ HandOff
               /\ waitLeft' = 0 /\ fresh' = TRUE

          ELSE /\ UNCHANGED vars
               /\ waitLeft' = IF phase = "waiting" THEN waitLeft - 1 ELSE 0
               /\ fresh' = (MustRefresh /\ Bug # "frozen_countdown")

TInit ==
    /\ Init
    /\ waitLeft = 0 /\ fresh = TRUE /\ sendAge = 0 /\ healAge = 0




TNext ==
    \/ Follow(Responding, FALSE)
    \/ Follow(Respond, net = "up" /\ ~needUser /\ gateway = "broken")
    \/ Follow(Drop, FALSE) \/ Follow(StaleSocket, FALSE)
    \/ Follow(NetDown, FALSE) \/ Follow(NetUp, FALSE)
    \/ Follow(GatewayBreak, FALSE) \/ Follow(GatewayHeal, FALSE)
    \/ Follow(NeedUserFault, FALSE)
    \/ Follow(Crash, FALSE) \/ Follow(Close, FALSE) \/ Follow(Relaunch, FALSE)
    \/ Follow(UserCancels, FALSE) \/ Follow(UserActs, FALSE)
    \/ Tick
    \/ Follow(Finished, FALSE)

TSpec == TInit /\ [][TNext]_tvars

-----------------------------------------------------------------------------




WaitBounded == waitLeft <= Ceiling



StatusFresh == (alive /\ ~flowing /\ MustRefresh) => fresh




HandsOff ==
    (alive /\ phase = "working" /\ inflight /\ ~flowing /\ status = "retrying")
        => sendAge < HandoffTicks



HealsWithin == (alive /\ phase \in Active) => healAge <= HealTicks

=============================================================================
