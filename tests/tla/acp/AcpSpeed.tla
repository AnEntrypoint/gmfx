------------------------------- MODULE AcpSpeed -------------------------------

















EXTENDS Naturals, TLC

CONSTANTS Models, SupFast, SupUltra

ASSUME SupFast \subseteq Models /\ SupUltra \subseteq Models

VARIABLES model, fast, ultra, last

vars == <<model, fast, ultra, last>>

Ops == {"new", "fast", "ultrafast", "model", "unknown", "prompt", "resume"}
Speeds == {"none", "standard", "fast", "ultrafast"}

Bool(b) == IF b THEN "true" ELSE "false"


View == [model |-> model,
         fast  |-> IF model \in SupFast THEN Bool(fast) ELSE "absent",
         ultra |-> IF model \in SupUltra THEN Bool(ultra) ELSE "absent"]


RequestSpeed == IF ultra THEN "ultrafast"
                ELSE IF fast /\ model \in SupFast THEN "fast"
                ELSE "standard"

Result(op, arg, ok, speed) == [op |-> op, arg |-> arg, ok |-> ok, speed |-> speed]

Init == /\ model \in Models
        /\ fast \in BOOLEAN
        /\ ultra = FALSE
        /\ last = Result("new", "none", TRUE, "none")

SetFast(b) ==
    IF b /\ model \notin SupFast
    THEN /\ last' = Result("fast", Bool(b), FALSE, "none")
         /\ UNCHANGED <<model, fast, ultra>>
    ELSE /\ fast' = b
         /\ ultra' = (ultra /\ ~b)
         /\ last' = Result("fast", Bool(b), TRUE, "none")
         /\ UNCHANGED model

SetUltra(b) ==
    IF b /\ model \notin SupUltra
    THEN /\ last' = Result("ultrafast", Bool(b), FALSE, "none")
         /\ UNCHANGED <<model, fast, ultra>>
    ELSE /\ ultra' = b
         /\ fast' = (fast /\ ~b)
         /\ last' = Result("ultrafast", Bool(b), TRUE, "none")
         /\ UNCHANGED model

SetModel(m) ==
    /\ model' = m
    /\ fast' = (fast /\ m \in SupFast)
    /\ ultra' = (ultra /\ m \in SupUltra)
    /\ last' = Result("model", m, TRUE, "none")

SetUnknown ==
    /\ last' = Result("unknown", "none", FALSE, "none")
    /\ UNCHANGED <<model, fast, ultra>>

Prompt ==
    /\ last' = Result("prompt", "none", TRUE, RequestSpeed)
    /\ UNCHANGED <<model, fast, ultra>>




Resume ==
    /\ last' = Result("resume", "none", TRUE, "none")
    /\ UNCHANGED <<model, fast, ultra>>

Next == \/ \E b \in BOOLEAN : SetFast(b) \/ SetUltra(b)
        \/ \E m \in Models : SetModel(m)
        \/ SetUnknown
        \/ Prompt
        \/ Resume

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------


TypeOK == /\ model \in Models
          /\ fast \in BOOLEAN
          /\ ultra \in BOOLEAN
          /\ last.op \in Ops
          /\ last.ok \in BOOLEAN
          /\ last.speed \in Speeds


Exclusive == ~(fast /\ ultra)


UltraValid == ultra => model \in SupUltra


SwitchClearsFast == last.op = "model" => (fast => model \in SupFast)


RequestHonored ==
    (last.ok /\ last.op = "fast") => Bool(fast) = last.arg
RequestHonoredUltra ==
    (last.ok /\ last.op = "ultrafast") => Bool(ultra) = last.arg


RejectOnlyUnsupported ==
    /\ (last.op = "fast" /\ ~last.ok) => (last.arg = "true" /\ model \notin SupFast)
    /\ (last.op = "ultrafast" /\ ~last.ok) => (last.arg = "true" /\ model \notin SupUltra)
AcceptOnlySupported ==
    /\ (last.op = "fast" /\ last.ok /\ last.arg = "true") => model \in SupFast
    /\ (last.op = "ultrafast" /\ last.ok /\ last.arg = "true") => model \in SupUltra


UnknownRejected == last.op = "unknown" => ~last.ok


PromptLaneSupported ==
    /\ (last.op = "prompt" /\ last.speed = "fast") => model \in SupFast
    /\ (last.op = "prompt" /\ last.speed = "ultrafast") => model \in SupUltra
=============================================================================
