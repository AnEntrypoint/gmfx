------------------------------- MODULE Recovery -------------------------------

























EXTENDS Naturals

CONSTANTS
    MaxFaults,
    Ladder,
    Bug

Bugs == {"none", "stall_stop", "no_wake", "stale_socket", "frozen_status",
         "no_closing", "never_ask", "hot_retry", "send_without_save",

         "unbounded_wait", "frozen_countdown", "no_handoff"}

ASSUME /\ MaxFaults \in Nat /\ Ladder \in 1..4 /\ Bug \in Bugs

Min(a, b) == IF a < b THEN a ELSE b

Phases   == {"working", "waiting", "need_user", "done_ok", "done_cancel", "stopped"}
Active   == {"working", "waiting", "need_user"}
Terminal == Phases \ Active
Statuses == {"clear", "waiting", "retrying", "need_user", "stopped", "none"}
Alarms   == {"waiting", "retrying", "need_user", "stopped"}
MaxAttempt == 3

VARIABLES
    phase,
    status,
    inflight,
    flowing,
    attempt,
    sameFail,
    lastSendWaited,
    savedInflight,
    savedClean,
    seenDeaths,
    deaths,
    cleanExit,
    net,
    gateway,
    needUser,
    faults,
    alive,
    cancelled

vars == <<phase, status, inflight, flowing, attempt, sameFail, lastSendWaited,
          savedInflight, savedClean, seenDeaths, deaths, cleanExit, net,
          gateway, needUser, faults, alive, cancelled>>

TypeOK ==
    /\ phase \in Phases
    /\ status \in Statuses
    /\ inflight \in BOOLEAN
    /\ flowing \in BOOLEAN
    /\ attempt \in 0..MaxAttempt
    /\ sameFail \in 0..Ladder
    /\ lastSendWaited \in BOOLEAN
    /\ savedInflight \in BOOLEAN
    /\ savedClean \in BOOLEAN
    /\ seenDeaths \in 0..MaxFaults
    /\ deaths \in 0..MaxFaults
    /\ cleanExit \in BOOLEAN
    /\ net \in {"up", "down"}
    /\ gateway \in {"ok", "broken"}
    /\ needUser \in BOOLEAN
    /\ faults \in 0..MaxFaults
    /\ alive \in BOOLEAN
    /\ cancelled \in BOOLEAN


Init ==
    /\ phase = "working"
    /\ status = "clear"
    /\ inflight = TRUE
    /\ flowing = FALSE
    /\ attempt = 1
    /\ sameFail = 0
    /\ lastSendWaited = TRUE
    /\ savedInflight = TRUE
    /\ savedClean = FALSE
    /\ seenDeaths = 0
    /\ deaths = 0
    /\ cleanExit = FALSE
    /\ net = "up"
    /\ gateway = "ok"
    /\ needUser = FALSE
    /\ faults = 0
    /\ alive = TRUE
    /\ cancelled = FALSE

-----------------------------------------------------------------------------





SendNow(waited) ==
    /\ phase' = "working"
    /\ inflight' = TRUE
    /\ flowing' = FALSE
    /\ attempt' = Min(attempt + 1, MaxAttempt)
    /\ lastSendWaited' = waited

    /\ savedInflight' = IF Bug = "send_without_save" /\ attempt > 0
                           THEN savedInflight ELSE TRUE
    /\ status' = IF attempt + 1 > 1 THEN "retrying" ELSE "clear"


OnFail(kind) ==
    IF kind = "need_user"
       THEN /\ phase' = "need_user" /\ status' = "need_user"
            /\ inflight' = FALSE /\ flowing' = FALSE /\ savedInflight' = FALSE
            /\ UNCHANGED <<attempt, sameFail, lastSendWaited>>
       ELSE LET counted  == kind # "offline"
                nextFail == IF counted THEN Min(sameFail + 1, Ladder) ELSE sameFail
            IN /\ sameFail' = nextFail
               /\ IF Bug = "hot_retry"

                     THEN SendNow(FALSE)
                  ELSE IF Bug = "stall_stop" /\ counted /\ nextFail >= Ladder

                     THEN /\ phase' = "stopped" /\ status' = "stopped"
                          /\ inflight' = FALSE /\ flowing' = FALSE
                          /\ savedInflight' = FALSE
                          /\ UNCHANGED <<attempt, lastSendWaited>>
                  ELSE /\ phase' = "waiting" /\ status' = "waiting"
                       /\ inflight' = FALSE /\ flowing' = FALSE
                       /\ savedInflight' = FALSE
                       /\ UNCHANGED <<attempt, lastSendWaited>>


OnSuccess ==
    /\ phase' = "done_ok" /\ status' = "clear"
    /\ inflight' = FALSE /\ flowing' = FALSE /\ savedInflight' = FALSE
    /\ UNCHANGED <<attempt, sameFail, lastSendWaited>>

-----------------------------------------------------------------------------



Responding ==
    /\ alive /\ phase = "working" /\ inflight /\ ~flowing
    /\ flowing' = TRUE
    /\ status' = IF Bug = "frozen_status" THEN status ELSE "clear"
    /\ UNCHANGED <<phase, inflight, attempt, sameFail, lastSendWaited,
                   savedInflight, savedClean, seenDeaths, deaths, cleanExit,
                   net, gateway, needUser, faults, alive, cancelled>>





HandOff ==
    /\ alive /\ phase = "working" /\ inflight /\ ~flowing /\ status = "retrying"
    /\ status' = "clear"
    /\ UNCHANGED <<phase, inflight, flowing, attempt, sameFail, lastSendWaited,
                   savedInflight, savedClean, seenDeaths, deaths, cleanExit,
                   net, gateway, needUser, faults, alive, cancelled>>



Respond ==
    /\ alive /\ inflight
    /\ CASE net = "down"         -> OnFail("offline")
         [] needUser             -> OnFail("need_user")
         [] gateway = "broken"   -> OnFail("server")
         [] OTHER                -> flowing /\ OnSuccess
    /\ UNCHANGED <<savedClean, seenDeaths, deaths, cleanExit, net, gateway,
                   needUser, faults, alive, cancelled>>


Drop ==
    /\ alive /\ inflight /\ faults < MaxFaults
    /\ faults' = faults + 1
    /\ OnFail("dropped")
    /\ UNCHANGED <<savedClean, seenDeaths, deaths, cleanExit, net, gateway,
                   needUser, alive, cancelled>>



StaleSocket ==
    /\ Bug = "stale_socket"
    /\ alive /\ inflight
    /\ net = "up" /\ gateway = "ok" /\ ~needUser
    /\ OnFail("dropped")
    /\ UNCHANGED <<savedClean, seenDeaths, deaths, cleanExit, net, gateway,
                   needUser, faults, alive, cancelled>>


TimerFires ==
    /\ alive /\ phase = "waiting"
    /\ Bug # "no_wake"
    /\ SendNow(TRUE)
    /\ UNCHANGED <<sameFail, savedClean, seenDeaths, deaths, cleanExit, net,
                   gateway, needUser, faults, alive, cancelled>>

-----------------------------------------------------------------------------


NetDown ==
    /\ net = "up" /\ faults < MaxFaults
    /\ net' = "down" /\ faults' = faults + 1
    /\ UNCHANGED <<phase, status, inflight, flowing, attempt, sameFail,
                   lastSendWaited, savedInflight, savedClean, seenDeaths,
                   deaths, cleanExit, gateway, needUser, alive, cancelled>>

NetUp ==
    /\ net = "down"
    /\ net' = "up"
    /\ UNCHANGED <<phase, status, inflight, flowing, attempt, sameFail,
                   lastSendWaited, savedInflight, savedClean, seenDeaths,
                   deaths, cleanExit, gateway, needUser, faults, alive,
                   cancelled>>

GatewayBreak ==
    /\ gateway = "ok" /\ faults < MaxFaults
    /\ gateway' = "broken" /\ faults' = faults + 1
    /\ UNCHANGED <<phase, status, inflight, flowing, attempt, sameFail,
                   lastSendWaited, savedInflight, savedClean, seenDeaths,
                   deaths, cleanExit, net, needUser, alive, cancelled>>

GatewayHeal ==
    /\ gateway = "broken"
    /\ gateway' = "ok"
    /\ UNCHANGED <<phase, status, inflight, flowing, attempt, sameFail,
                   lastSendWaited, savedInflight, savedClean, seenDeaths,
                   deaths, cleanExit, net, needUser, faults, alive, cancelled>>

NeedUserFault ==
    /\ ~needUser /\ faults < MaxFaults
    /\ needUser' = TRUE /\ faults' = faults + 1
    /\ UNCHANGED <<phase, status, inflight, flowing, attempt, sameFail,
                   lastSendWaited, savedInflight, savedClean, seenDeaths,
                   deaths, cleanExit, net, gateway, alive, cancelled>>

-----------------------------------------------------------------------------




Crash ==
    /\ alive /\ phase \in Active /\ faults < MaxFaults
    /\ faults' = faults + 1
    /\ alive' = FALSE
    /\ cleanExit' = FALSE
    /\ deaths' = IF inflight THEN Min(deaths + 1, MaxFaults) ELSE deaths
    /\ inflight' = FALSE /\ flowing' = FALSE /\ status' = "none"
    /\ UNCHANGED <<phase, attempt, sameFail, lastSendWaited, savedInflight,
                   savedClean, seenDeaths, net, gateway, needUser, cancelled>>


Close ==
    /\ alive /\ phase \in Active /\ faults < MaxFaults
    /\ faults' = faults + 1
    /\ alive' = FALSE
    /\ cleanExit' = TRUE

    /\ savedClean' = IF Bug = "no_closing" THEN savedClean ELSE TRUE
    /\ inflight' = FALSE /\ flowing' = FALSE /\ status' = "none"
    /\ UNCHANGED <<phase, attempt, sameFail, lastSendWaited, savedInflight,
                   seenDeaths, deaths, net, gateway, needUser, cancelled>>



Relaunch ==
    /\ ~alive /\ phase \in Active
    /\ alive' = TRUE
    /\ savedClean' = FALSE
    /\ LET abrupt == savedInflight /\ ~savedClean
           seen   == IF abrupt THEN Min(seenDeaths + 1, MaxFaults) ELSE seenDeaths
           ask    == (seen >= 2 /\ Bug # "never_ask") \/ phase = "need_user"
       IN /\ seenDeaths' = seen
          /\ IF ask
                THEN /\ phase' = "need_user" /\ status' = "need_user"
                     /\ inflight' = FALSE /\ flowing' = FALSE
                     /\ savedInflight' = FALSE
                     /\ UNCHANGED <<attempt, lastSendWaited>>
                ELSE SendNow(TRUE)
    /\ UNCHANGED <<sameFail, deaths, cleanExit, net, gateway, needUser,
                   faults, cancelled>>

-----------------------------------------------------------------------------



UserCancels ==
    /\ alive /\ phase \in Active
    /\ phase' = "done_cancel" /\ status' = "clear" /\ cancelled' = TRUE
    /\ inflight' = FALSE /\ flowing' = FALSE /\ savedInflight' = FALSE
    /\ UNCHANGED <<attempt, sameFail, lastSendWaited, savedClean, seenDeaths,
                   deaths, cleanExit, net, gateway, needUser, faults, alive>>





UserActs ==
    LET loop == seenDeaths >= 2 IN
    /\ alive /\ phase = "need_user"
    /\ needUser' = FALSE
    /\ seenDeaths' = IF loop THEN 0 ELSE seenDeaths
    /\ deaths' = IF loop THEN 0 ELSE deaths
    /\ SendNow(TRUE)
    /\ UNCHANGED <<sameFail, savedClean, cleanExit, net, gateway, faults,
                   alive, cancelled>>


Finished ==
    /\ phase \in Terminal
    /\ UNCHANGED vars

Next ==
    \/ Responding \/ HandOff \/ Respond \/ Drop \/ StaleSocket \/ TimerFires
    \/ NetDown \/ NetUp \/ GatewayBreak \/ GatewayHeal \/ NeedUserFault
    \/ Crash \/ Close \/ Relaunch
    \/ UserCancels \/ UserActs
    \/ Finished



Fairness ==
    /\ WF_vars(Responding) /\ WF_vars(Respond) /\ WF_vars(TimerFires)
    /\ WF_vars(Relaunch) /\ WF_vars(UserActs)
    /\ WF_vars(NetUp) /\ WF_vars(GatewayHeal)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------



NeverGivesUp ==
    /\ phase # "stopped"
    /\ (phase = "done_cancel" => cancelled)


Heals == <>(phase \in {"done_ok", "done_cancel"})


NoFalseAlarm == (status \in Alarms) => faults > 0




StatusHonest ==
    alive =>
        /\ (phase = "waiting" => status = "waiting")
        /\ (phase = "need_user" => status = "need_user")
        /\ (phase = "working" /\ inflight /\ ~flowing =>
                status \in IF attempt > 1 THEN {"retrying", "clear"} ELSE {"clear"})
        /\ (phase = "working" /\ flowing => status = "clear")


ResumesAfterClose ==
    [][(Relaunch /\ cleanExit /\ phase # "need_user") => phase' # "need_user"]_vars


CrashLoopAsks ==
    [][(Relaunch /\ ~cleanExit /\ deaths >= 2 /\ phase # "need_user")
         => phase' = "need_user"]_vars


NoHotRetry == lastSendWaited



SaveBeforeSend == alive => (savedInflight = inflight)

=============================================================================
