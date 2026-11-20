----------------------------- MODULE EmptyReply -----------------------------





























EXTENDS Naturals, Sequences

CONSTANTS Limits, MaxRequests, Bug

Kinds == {"tool", "tool_silent", "text", "text_other", "empty_other"}
Carries == {"prompt", "tools", "nudge", "summarize"}
Outcomes == {"none", "answered", "failed_empty", "step_limit", "placeholder"}

VARIABLES
    phase,
    limit,
    nudged,
    silent,
    summarized,
    sent,
    replies,
    outcome

vars == <<phase, limit, nudged, silent, summarized, sent, replies, outcome>>

InitWith(l) ==
    /\ phase = "waiting"
    /\ limit = l
    /\ nudged = FALSE
    /\ silent = 0
    /\ summarized = FALSE
    /\ sent = <<"prompt">>
    /\ replies = <<>>
    /\ outcome = "none"

Init == \E l \in Limits : InitWith(l)


Reset(l) ==
    /\ phase' = "waiting"
    /\ limit' = l
    /\ nudged' = FALSE
    /\ silent' = 0
    /\ summarized' = FALSE
    /\ sent' = <<"prompt">>
    /\ replies' = <<>>
    /\ outcome' = "none"


Allows(n) == limit = 0 \/ n < limit


Effect(k) == IF Bug = "nudge_text" /\ k = "text_other" THEN "empty_other" ELSE k

Continue(carry) == /\ sent' = Append(sent, carry)
                   /\ phase' = "waiting"
                   /\ UNCHANGED outcome

Finish(o) == /\ phase' = "done"
             /\ outcome' = o
             /\ UNCHANGED sent



SummarizeFirst ==
    Bug \in {"summarize_first", "today"} /\ silent >= 2 /\ ~summarized /\ Allows(Len(sent))

CanNudge ==
    /\ ~nudged \/ Bug = "double_nudge"
    /\ Allows(Len(sent)) \/ Bug = "ignore_limit"

EmptyReply ==
    /\ UNCHANGED silent
    /\ IF SummarizeFirst
         THEN /\ summarized' = TRUE
              /\ UNCHANGED nudged
              /\ Continue("summarize")
       ELSE IF Bug = "today"
         THEN /\ UNCHANGED <<nudged, summarized>>
              /\ Finish("placeholder")
       ELSE IF CanNudge
         THEN /\ nudged' = TRUE
              /\ UNCHANGED summarized
              /\ Continue("nudge")
       ELSE /\ UNCHANGED <<nudged, summarized>>
            /\ Finish(IF Bug = "placeholder" THEN "placeholder" ELSE "failed_empty")

ToolReply(e) ==
    /\ silent' = IF e = "tool_silent" THEN IF silent < 2 THEN silent + 1 ELSE 2 ELSE 0

    /\ nudged' = (Bug = "no_reset" /\ nudged)
    /\ UNCHANGED summarized
    /\ IF Allows(Len(sent)) THEN Continue("tools") ELSE Finish("step_limit")

Reply(k) ==
    /\ phase = "waiting"
    /\ replies' = Append(replies, k)
    /\ UNCHANGED limit
    /\ LET e == Effect(k) IN
         CASE e \in {"text", "text_other"} ->
                /\ UNCHANGED <<nudged, silent, summarized>>
                /\ Finish("answered")
           [] e \in {"tool", "tool_silent"} -> ToolReply(e)
           [] e = "empty_other" -> EmptyReply

Ended == phase = "done" /\ UNCHANGED vars

Next == (\E k \in Kinds : Reply(k)) \/ Ended

Spec == Init /\ [][Next]_vars

Bounded == Len(sent) <= MaxRequests

-----------------------------------------------------------------------------

TypeOK ==
    /\ phase \in {"waiting", "done"}
    /\ limit \in Limits
    /\ nudged \in BOOLEAN
    /\ silent \in 0..2
    /\ summarized \in BOOLEAN
    /\ sent \in Seq(Carries)
    /\ replies \in Seq(Kinds)
    /\ outcome \in Outcomes


NoPlaceholder == outcome # "placeholder"


NudgeOnlyAfterEmptyOther ==
    \A i \in 2..Len(sent) : sent[i] = "nudge" => replies[i - 1] = "empty_other"



NoDoubleNudge ==
    \A i \in 2..(Len(sent) - 1) : ~(sent[i] = "nudge" /\ sent[i + 1] = "nudge")



EverySeparateEmptyNudged ==
    \A i \in 1..Len(replies) :
        (/\ replies[i] = "empty_other"
         /\ sent[i] # "nudge"
         /\ (limit = 0 \/ i < limit))
            => (Len(sent) > i /\ sent[i + 1] = "nudge")


StepsBounded == limit # 0 => Len(sent) <= limit
=============================================================================
