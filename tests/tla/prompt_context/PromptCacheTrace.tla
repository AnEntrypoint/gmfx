-------------------------- MODULE PromptCacheTrace --------------------------


















EXTENDS PromptCacheObserved, Naturals, Sequences, FiniteSets, TLC

CONSTANTS Design, Family, Notes, Carrier

VARIABLES i, cache, log
vars == <<i, cache, log>>

PC == INSTANCE PromptCache WITH
  Mutation <- "none", Worktrees <- {}, RepoOf <- [w \in {} |-> "none"],
  MaxSessions <- 0, MaxSteps <- 0, Limit <- 4, PathScoped <- TRUE, Events <- {"switch", "deliver", "skill"},
  sessions <- 0, active <- 0, branchOf <- 0

Kinds == <<"tools", "base", "skills", "project", "mcp", "ctx", "rt">>

Has(req, kind) == \E j \in 1..Len(req) : req[j].k = kind


Carried(req) == Cardinality({j \in 1..Len(req) : req[j].k \in {"asstc", "userc"}})




Inserted == {"scoped", "skill"}
Noted == {"note", "skilltext", "skillnote"}
ConversationKinds ==
  CASE ~Notes -> {"user", "asst"}
    [] Carrier = "message" -> PC!MessageKinds
    [] OTHER -> {"user", "asst"} \cup Noted

Layout(req) ==
  /\ Has(req, "rt")
  /\ LET lead == SubSeq(req, 1, PC!NInstr(req))
         base == SelectSeq(lead, LAMBDA b : b.k \notin Inserted)
     IN /\ Len(base) = Len(Kinds)
        /\ \A j \in 1..Len(Kinds) : base[j].k = Kinds[j]
        /\ Notes => Len(base) = Len(lead)
  /\ Len(req) > PC!NInstr(req)
  /\ \A j \in (PC!NInstr(req) + 1)..Len(req) : req[j].k \in ConversationKinds
  /\ \E j \in (PC!NInstr(req) + 1)..Len(req) : req[j].k \in PC!UserKinds


Before(n) ==
  LET earlier == {j \in 1..(n - 1) : Observed[j].s = Observed[n].s}
  IN IF earlier = {} THEN 0 ELSE PC!Max(earlier)

Ctx(req) == IF Has(req, "ctx") THEN req[PC!PosOf(req, "ctx")] ELSE PC!Block("none", "none")






Keep(b, req) ==
  LET prev == Observed[b].req
  IN IF (Has(prev, "skill") \/ Has(prev, "skilltext") \/ Observed[b].skill > 0)
        /\ PC!LastUser(req) > PC!LastUser(prev)
     THEN PC!LastUser(prev) - 1
     ELSE PC!LastKept(prev)

Init ==
  /\ i = 0
  /\ cache = {}
  /\ log = <<>>

Next ==
  /\ i < Len(Observed)
  /\ LET n == i + 1
         o == Observed[n]
         b == Before(n)
         bps == PC!BpsWith(o.req, o.manual)
     IN /\ cache' = cache \cup {SubSeq(o.req, 1, m) : m \in PC!WritesWith(o.req, o.manual)}
        /\ log' = Append(log, [w |-> o.w, s |-> o.s, first |-> b = 0, req |-> o.req, bps |-> bps,
                               read |-> PC!ReadWith(o.req, o.manual, cache),
                               prev |-> IF b = 0 THEN <<>> ELSE Observed[b].req,
                               changed |-> b # 0 /\ (Ctx(o.req) # Ctx(Observed[b].req)
                                                       \/ Carried(o.req) > Carried(Observed[b].req)),
                               keep |-> IF b = 0 THEN 0 ELSE Keep(b, o.req),
                               repoSeen |-> \E j \in 1..i : Observed[j].repo = o.repo,
                               worktreeSeen |-> \E j \in 1..i : Observed[j].w = o.w,
                               anySeen |-> i > 0])
        /\ i' = n

Spec == Init /\ [][Next]_vars

Conforms ==
  \A j \in 1..i : Layout(Observed[j].req) /\ Observed[j].manual = PC!Manual(Observed[j].req)

Budget == PC!Budget
SessionReuse == PC!SessionReuse
CrossRepoReuse == PC!CrossRepoReuse
SameWorktreeReuse == PC!SameWorktreeReuse
WorktreeReuse == PC!WorktreeReuse
ContextChangeKeepsStable == PC!ContextChangeKeepsStable
ContextChangeKeepsHistory == PC!ContextChangeKeepsHistory
MidSessionKeepsHistory == PC!MidSessionKeepsHistory
PreviousFullyReused == PC!PreviousFullyReused

ReplayIncomplete == i < Len(Observed)
=============================================================================
