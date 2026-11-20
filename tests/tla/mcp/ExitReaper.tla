---- MODULE ExitReaper ----
















EXTENDS Naturals, Sequences

CONSTANTS Inst

VARIABLES
    fx,
    st,
    stubborn,
    termed,
    told,
    pipe,
    list,
    helper,
    stranger,
    stray

vars == <<fx, st, stubborn, termed, told, pipe, list, helper, stranger, stray>>

TypeOK ==
    /\ fx \in {"up", "exiting", "gone"}
    /\ st \in [Inst -> {"unborn", "alive", "zombie", "reaped"}]
    /\ stubborn \in [Inst -> BOOLEAN]
    /\ termed \in [Inst -> BOOLEAN]
    /\ told \in [Inst -> BOOLEAN]
    /\ list \subseteq Inst
    /\ helper \in {"none", "reading", "grace", "done"}
    /\ stranger \in [Inst -> BOOLEAN]
    /\ stray \in BOOLEAN

Init ==
    /\ fx = "up"
    /\ st = [i \in Inst |-> "unborn"]
    /\ stubborn = [i \in Inst |-> FALSE]
    /\ termed = [i \in Inst |-> FALSE]
    /\ told = [i \in Inst |-> FALSE]
    /\ pipe = <<>>
    /\ list = {}
    /\ helper = "none"
    /\ stranger = [i \in Inst |-> FALSE]
    /\ stray = FALSE

Running == fx \in {"up", "exiting"}


StartHelper ==
    /\ Running /\ helper = "none"
    /\ helper' = "reading"
    /\ UNCHANGED <<fx, st, stubborn, termed, told, pipe, list, stranger, stray>>


Spawn(i) ==
    /\ Running /\ helper # "none" /\ st[i] = "unborn"
    /\ st' = [st EXCEPT ![i] = "alive"]
    /\ \E b \in BOOLEAN : stubborn' = [stubborn EXCEPT ![i] = b]
    /\ termed' = [termed EXCEPT ![i] = (fx = "exiting")]
    /\ UNCHANGED <<fx, told, pipe, list, helper, stranger, stray>>




Tell(i) ==
    /\ Running /\ st[i] # "unborn" /\ ~told[i]
    /\ told' = [told EXCEPT ![i] = TRUE]
    /\ pipe' = IF helper = "none" THEN pipe ELSE Append(pipe, <<"+", i>>)
    /\ UNCHANGED <<fx, st, stubborn, termed, list, helper, stranger, stray>>



Die(i) ==
    /\ st[i] = "alive" /\ ~stubborn[i]
    /\ st' = [st EXCEPT ![i] = "zombie"]
    /\ UNCHANGED <<fx, stubborn, termed, told, pipe, list, helper, stranger, stray>>



Reap(i) ==
    /\ Running /\ st[i] = "zombie" /\ told[i]
    /\ st' = [st EXCEPT ![i] = "reaped"]
    /\ pipe' = Append(pipe, <<"-", i>>)
    /\ UNCHANGED <<fx, stubborn, termed, told, list, helper, stranger, stray>>


InitReaps(i) ==
    /\ fx = "gone" /\ st[i] = "zombie"
    /\ st' = [st EXCEPT ![i] = "reaped"]
    /\ UNCHANGED <<fx, stubborn, termed, told, pipe, list, helper, stranger, stray>>


Reuse(i) ==
    /\ fx = "up" /\ st[i] = "reaped" /\ ~stranger[i]
    /\ stranger' = [stranger EXCEPT ![i] = TRUE]
    /\ UNCHANGED <<fx, st, stubborn, termed, told, pipe, list, helper, stray>>


ExitSignal ==
    /\ fx = "up"
    /\ fx' = "exiting"
    /\ termed' = [i \in Inst |-> termed[i] \/ st[i] = "alive"]
    /\ UNCHANGED <<st, stubborn, told, pipe, list, helper, stranger, stray>>

Exit ==
    /\ fx = "exiting"
    /\ fx' = "gone"
    /\ UNCHANGED <<st, stubborn, termed, told, pipe, list, helper, stranger, stray>>


Crash ==
    /\ Running
    /\ fx' = "gone"
    /\ UNCHANGED <<st, stubborn, termed, told, pipe, list, helper, stranger, stray>>


Read ==
    /\ helper = "reading" /\ pipe # <<>>
    /\ LET m == Head(pipe) IN
         list' = IF m[1] = "+" THEN list \cup {m[2]} ELSE list \ {m[2]}
    /\ pipe' = Tail(pipe)
    /\ UNCHANGED <<fx, st, stubborn, termed, told, helper, stranger, stray>>



Closed ==
    /\ helper = "reading" /\ fx = "gone" /\ pipe = <<>>
    /\ helper' = "grace"
    /\ termed' = [i \in Inst |-> termed[i] \/ (i \in list /\ st[i] = "alive")]
    /\ stray' = (stray \/ \E i \in list : stranger[i])
    /\ UNCHANGED <<fx, st, stubborn, told, pipe, list, stranger>>


GraceOver ==
    /\ helper = "grace"
    /\ helper' = "done"
    /\ st' = [i \in Inst |-> IF i \in list /\ st[i] = "alive" THEN "zombie" ELSE st[i]]
    /\ stray' = (stray \/ \E i \in list : stranger[i])
    /\ UNCHANGED <<fx, stubborn, termed, told, pipe, list, stranger>>

Next ==
    \/ StartHelper \/ ExitSignal \/ Exit \/ Crash \/ Read \/ Closed \/ GraceOver
    \/ \E i \in Inst : Spawn(i) \/ Tell(i) \/ Die(i) \/ Reap(i) \/ InitReaps(i) \/ Reuse(i)

Fairness ==
    /\ WF_vars(Exit) /\ WF_vars(Read) /\ WF_vars(Closed) /\ WF_vars(GraceOver)
    /\ \A i \in Inst : WF_vars(Tell(i)) /\ WF_vars(Die(i)) /\ WF_vars(InitReaps(i))

Spec == Init /\ [][Next]_vars /\ Fairness


NoStrayKill == ~stray


KillOnlyAfterTerm ==
    [][helper = "grace" /\ helper' = "done" => \A i \in list : st[i] = "alive" => termed[i]]_vars


NoSurvivor == fx = "gone" ~> \A i \in Inst : told[i] => st[i] # "alive"
====
