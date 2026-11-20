---- MODULE GitAdmission ----









EXTENDS Naturals, Sequences

CONSTANT HoldEnabled

Modes == {"auto", "ask"}
Envs == {"clean", "user"}
Cmds == {"status", "status_other", "diff", "log"}
Repos == {"clean", "poisoned", "unreadable", "mismatch", "notrepo"}

Poisoned == {"poisoned", "unreadable", "mismatch"}


Allowlisted == {"status", "diff", "log"}


Refuses == {"unreadable", "mismatch"}

Reversible == {"status", "status_other"}



FiresInPlain == {"status", "status_other", "diff"}
Verdicts == {"clear", "caution"}

VARIABLES mode, env, cmd, repo, verdict, plan, route, fired, pc, history
vars == <<mode, env, cmd, repo, verdict, plan, route, fired, pc, history>>

Init ==
    /\ mode \in Modes /\ env \in Envs /\ cmd \in Cmds /\ repo \in Repos

    /\ verdict \in Verdicts
    /\ plan = "none" /\ route = "none" /\ fired = FALSE
    /\ pc = "plan" /\ history = <<>>


PlanResult ==
    IF env = "user" \/ mode # "auto" THEN "dynamic_shell"
    ELSE IF repo \in Refuses THEN "unsafe_git"
    ELSE IF cmd \notin Allowlisted THEN "unsupported_argument"
    ELSE "direct"

AdmitResult ==
    IF plan = "direct" THEN "direct"
    ELSE IF mode = "ask" THEN "prompt"
    ELSE IF plan = "unsafe_git" /\ HoldEnabled THEN "held"
    ELSE IF cmd \in Reversible THEN "approved_shell"
    ELSE "review"

Plan ==
    /\ pc = "plan" /\ plan' = PlanResult /\ pc' = "admit"
    /\ history' = Append(history, "Plan")
    /\ UNCHANGED <<mode, env, cmd, repo, verdict, route, fired>>

Admit ==
    /\ pc = "admit" /\ route' = AdmitResult /\ pc' = "execute"
    /\ history' = Append(history, "Admit")
    /\ UNCHANGED <<mode, env, cmd, repo, verdict, plan, fired>>




RunsPlainGit == route = "approved_shell" \/ (route = "review" /\ verdict = "clear")
Execute ==
    /\ pc = "execute"
    /\ fired' = (RunsPlainGit /\ repo \in Poisoned /\ cmd \in FiresInPlain)
    /\ pc' = "done" /\ history' = Append(history, "Execute")
    /\ UNCHANGED <<mode, env, cmd, repo, verdict, plan, route>>

Next == Plan \/ Admit \/ Execute
Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ mode \in Modes /\ env \in Envs /\ cmd \in Cmds /\ repo \in Repos /\ verdict \in Verdicts
    /\ pc \in {"plan", "admit", "execute", "done"}
    /\ fired \in BOOLEAN


HoldSafety == (pc = "done" /\ mode = "auto" /\ plan = "unsafe_git") => route # "approved_shell"

DirectNeverFires == route = "direct" => ~fired

ExposureOnlyDocumented == fired => (route \in {"approved_shell", "review"} /\ (env = "user" \/ cmd \notin Allowlisted))
====
