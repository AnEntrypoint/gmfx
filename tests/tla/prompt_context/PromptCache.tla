---------------------------- MODULE PromptCache ----------------------------
















































































































EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
  Design,
  Mutation,
  Worktrees,
  RepoOf,
  MaxSessions,
  MaxSteps,
  Limit,
  PathScoped,
  Family,
  Events,
  Notes,
  Carrier

ASSUME Design \in {"current", "proposed"}
ASSUME Family \in {"anthropic", "openai"}
ASSUME Mutation \in {"none", "mark_every_system", "fence_after_context", "no_auto",
                     "note_not_saved", "contract_late", "remind_old_result",
                     "stale_in_instructions", "overlay_rebuilt", "overlay_not_saved"}
ASSUME Carrier \in {"message", "note"}
ASSUME MaxSessions \in Nat /\ MaxSteps \in Nat /\ Limit \in Nat
ASSUME PathScoped \in BOOLEAN
ASSUME Events \subseteq {"switch", "deliver", "skill", "remind", "resume", "outside"} /\ Notes \in BOOLEAN

Block(k, v) == [k |-> k, v |-> v]















Scoped(w) == IF PathScoped THEN w ELSE RepoOf[w]

Stable(w) ==
  << Block("tools", "p"), Block("base", "p"), Block("skills", Scoped(w)),
     Block("project", Scoped(w)), Block("mcp", "p") >>

Overlay(w, br) == << Block("ctx", w \o "@" \o br), Block("rt", "p") >>

Instructions(w, br) == Stable(w) \o Overlay(w, br)

PosProfile == 2
PosStable  == 5



PosOf(req, kind) == CHOOSE i \in 1..Len(req) : req[i].k = kind
NInstr(req) == PosOf(req, "rt")

Max(S) == CHOOSE x \in S : \A y \in S : y <= x

UserKinds == {"user", "userc"}
MessageKinds == UserKinds \cup {"asst", "asstc"}

LastUser(req) == Max({i \in 1..Len(req) : req[i].k \in UserKinds})

Manual(req) ==
  CASE Mutation = "mark_every_system" -> {2, 3, 4, PosOf(req, "mcp")}
    [] Design = "current" -> {}
    [] Mutation = "fence_after_context" -> {PosProfile, PosOf(req, "ctx")}
    [] OTHER -> {PosProfile, PosOf(req, "mcp")}


Eligible(req) == {j \in (NInstr(req) + 1)..Len(req) : req[j].k \in MessageKinds}



Auto(req) ==
  CASE Mutation = "no_auto" -> {}
    [] Family = "anthropic" -> {Len(req), LastUser(req) - 1}
    [] OTHER -> {Max(Eligible(req) \cup {NInstr(req)})}


BpsWith(req, man) == man \cup Auto(req)

Breakpoints(req) == BpsWith(req, Manual(req))


WritesWith(req, man) ==
  IF Family = "openai" /\ Mutation # "no_auto"
  THEN BpsWith(req, man) \cup {NInstr(req)}
  ELSE BpsWith(req, man)



Hit(req, bps, c) ==
  IF bps = {} THEN 0 ELSE
    LET found == {n \in 1..Max(bps) : SubSeq(req, 1, n) \in c}
    IN IF found = {} THEN 0 ELSE Max(found)



Candidates(req, man) ==
  IF Mutation = "no_auto" THEN man
  ELSE BpsWith(req, man) \cup Eligible(req) \cup {NInstr(req)}

Lookup(req, man, c) ==
  LET found == {n \in Candidates(req, man) : SubSeq(req, 1, n) \in c}
  IN IF found = {} THEN 0 ELSE Max(found)



NoteBeforeUser(req) ==
  \E i \in 1..(Len(req) - 1) : req[i].k = "note" /\ req[i + 1].k \in UserKinds


ReadWith(req, man, c) ==
  IF Family = "anthropic"
  THEN LET h == Hit(req, BpsWith(req, man), c)
       IN IF NoteBeforeUser(req) /\ h > NInstr(req) THEN NInstr(req) ELSE h
  ELSE Lookup(req, man, c)

VARIABLES cache, sessions, active, log, branchOf
vars == <<cache, sessions, active, log, branchOf>>

NoSession == [on |-> FALSE, w |-> "none", s |-> 0, n |-> 0, br |-> "b1", br0 |-> "b1",
              hist |-> <<>>, last |-> <<>>, switched |-> FALSE, delivered |-> FALSE,
              skilled |-> FALSE, scopedTurn |-> FALSE, scopedStable |-> FALSE,
              skill |-> FALSE, skillUser |-> 0, skillText |-> 0,
              carrierAt |-> 0, remindable |-> FALSE, reminded |-> FALSE,
              resumed |-> FALSE, stale |-> FALSE, out |-> FALSE, out0 |-> FALSE]



OutInLead(a) == IF ~Notes \/ Mutation = "overlay_rebuilt" THEN a.out ELSE a.out0
LeadBranch(a) == IF ~Notes \/ Mutation = "overlay_rebuilt" THEN a.br ELSE a.br0



WithRt(a, lead) ==
  IF a.stale \/ OutInLead(a)
  THEN [lead EXCEPT ![PosOf(lead, "rt")] =
          Block("rt", "p" \o (IF a.stale THEN "+stale" ELSE "")
                          \o (IF OutInLead(a) THEN "+out" ELSE ""))]
  ELSE lead

LeadBlocks(a) ==
  IF Notes THEN
    IF Mutation = "contract_late" /\ a.delivered
    THEN [Instructions(a.w, LeadBranch(a)) EXCEPT ![2] = Block("base", "p+contract")]
    ELSE Instructions(a.w, LeadBranch(a))
  ELSE SubSeq(Stable(a.w), 1, 4)
         \o (IF a.scopedStable THEN << Block("scoped", Scoped(a.w)) >> ELSE << >>)
         \o << Block("mcp", "p") >>
         \o (IF a.scopedTurn THEN << Block("scoped", Scoped(a.w)) >> ELSE << >>)
         \o (IF a.skill THEN << Block("skill", "k") >> ELSE << >>)
         \o Overlay(a.w, LeadBranch(a))




Lead(a) == WithRt(a, LeadBlocks(a))




LastKept(prev) ==
  Max({i \in 1..Len(prev) : prev[i].k \notin {"note", "skilltext"}} \cup {0})

Init ==
  /\ cache = {}
  /\ sessions = 0
  /\ active = NoSession
  /\ log = <<>>
  /\ branchOf = [w \in Worktrees |-> "b1"]


Send(w, s, req, first, prev, changed, keep) ==
  LET bps == Breakpoints(req)
  IN /\ cache' = cache \cup {SubSeq(req, 1, n) : n \in WritesWith(req, Manual(req))}
     /\ log' = Append(log, [w |-> w, s |-> s, first |-> first, req |-> req, bps |-> bps,
                            read |-> ReadWith(req, Manual(req), cache), prev |-> prev, changed |-> changed,
                            keep |-> keep,
                            repoSeen |-> \E i \in 1..Len(log) : RepoOf[log[i].w] = RepoOf[w],
                            worktreeSeen |-> \E i \in 1..Len(log) : log[i].w = w,
                            anySeen |-> Len(log) > 0])


Start(w) ==
  LET s == sessions + 1
      br == branchOf[w]
      hist == << Block("user", ToString(s) \o ".0") >>
      a == [NoSession EXCEPT !.on = TRUE, !.w = w, !.s = s, !.br = br, !.br0 = br,
                             !.hist = hist]
      req == Lead(a) \o hist
  IN /\ ~active.on
     /\ sessions < MaxSessions
     /\ sessions' = s
     /\ active' = [a EXCEPT !.last = req]
     /\ Send(w, s, req, TRUE, <<>>, FALSE, 0)
     /\ UNCHANGED branchOf


Uncarried(b) ==
  CASE b.k = "asstc" -> Block("asst", b.v)
    [] b.k = "userc" -> Block("user", b.v)
    [] OTHER -> b










Continue(kind) ==
  LET a == active
      n == a.n + 1
      isTurn == kind \in {"turn", "skill", "resume", "outside"}
      staleInLead == kind = "resume" /\ (~Notes \/ Mutation = "stale_in_instructions")

      inLead == staleInLead \/ (kind \in {"switch", "outside"} /\ (~Notes \/ Mutation = "overlay_rebuilt"))
      event == kind \in {"switch", "deliver", "skill", "resume", "outside"} \/ (kind = "remind" /\ Notes)
      carried == Notes /\ Carrier = "message"
      recapture == kind = "resume" /\ Mutation = "overlay_not_saved"
      misplaced == kind = "remind" /\ carried /\ Mutation = "remind_old_result"
      br == IF kind = "switch" THEN "b2" ELSE a.br
      swapped == IF isTurn /\ Notes /\ a.skillText > 0
                 THEN [a.hist EXCEPT ![a.skillText] =
                         IF carried THEN Block("userc", @.v \o "short")
                         ELSE Block("skillnote", "k")]
                 ELSE a.hist
      kept == IF isTurn /\ Notes /\ Mutation = "note_not_saved"
              THEN IF carried THEN [i \in 1..Len(swapped) |-> Uncarried(swapped[i])]
                   ELSE SelectSeq(swapped, LAMBDA b : b.k # "note")
              ELSE swapped
      reminded == IF misplaced
                  THEN [kept EXCEPT ![a.carrierAt] = Block(@.k, @.v \o "+remind")]
                  ELSE kept
      msgKind == CASE isTurn /\ carried /\ event /\ ~inLead -> "userc"
                   [] isTurn -> "user"
                   [] carried /\ event /\ ~misplaced /\ ~inLead -> "asstc"
                   [] OTHER -> "asst"
      withMsg == Append(reminded, Block(msgKind, ToString(a.s) \o "." \o ToString(n)))
      hist == CASE ~Notes \/ carried -> withMsg
                [] kind = "switch" /\ ~inLead -> Append(withMsg, Block("note", "branch"))
                [] kind = "deliver" -> Append(withMsg, Block("note", "scoped"))
                [] kind = "skill" -> Append(withMsg, Block("skilltext", "k"))
                [] kind = "remind" -> Append(withMsg, Block("note", "remind"))
                [] kind = "resume" /\ ~staleInLead -> Append(withMsg, Block("note", "stale"))
                [] kind = "outside" /\ ~inLead -> Append(withMsg, Block("note", "outside"))
                [] OTHER -> withMsg
      next == [a EXCEPT !.n = n, !.br = br, !.hist = hist,
                        !.switched = a.switched \/ kind = "switch",
                        !.delivered = a.delivered \/ kind = "deliver",
                        !.skilled = a.skilled \/ kind = "skill",
                        !.scopedStable = a.scopedStable \/ (isTurn /\ a.scopedTurn),
                        !.scopedTurn = (IF isTurn THEN FALSE
                                        ELSE a.scopedTurn \/ (~Notes /\ kind = "deliver")),
                        !.skill = (IF isTurn THEN ~Notes /\ kind = "skill" ELSE a.skill),
                        !.skillUser = (IF kind = "skill" THEN Len(withMsg)
                                       ELSE IF isTurn THEN 0 ELSE a.skillUser),
                        !.skillText = (IF Notes /\ kind = "skill" THEN Len(hist)
                                       ELSE IF isTurn THEN 0 ELSE a.skillText),
                        !.carrierAt = (IF kind = "deliver" /\ carried THEN Len(withMsg)
                                       ELSE a.carrierAt),
                        !.remindable = a.remindable \/ (isTurn /\ a.delivered),
                        !.reminded = a.reminded \/ kind = "remind",
                        !.resumed = a.resumed \/ kind = "resume",
                        !.stale = a.stale \/ staleInLead,
                        !.out = a.out \/ kind = "outside",
                        !.br0 = IF recapture THEN a.br ELSE a.br0,
                        !.out0 = IF recapture THEN a.out ELSE a.out0]
      req == Lead(next) \o hist


      keep == IF isTurn /\ a.skillUser > 0
              THEN Len(a.last) - Len(a.hist) + a.skillUser - 1
              ELSE LastKept(a.last)
  IN /\ a.on
     /\ a.n < MaxSteps
     /\ kind \in {"switch", "deliver", "skill", "remind", "resume", "outside"} => kind \in Events
     /\ kind = "switch" => ~a.switched
     /\ kind = "deliver" => ~a.delivered
     /\ kind = "skill" => ~a.skilled
     /\ kind = "remind" => a.remindable /\ ~a.reminded
     /\ kind = "resume" => ~a.resumed
     /\ kind = "outside" => ~a.out
     /\ active' = [next EXCEPT !.last = req]
     /\ Send(a.w, a.s, req, FALSE, a.last, event, keep)
     /\ branchOf' = [branchOf EXCEPT ![a.w] = br]
     /\ UNCHANGED sessions

End ==
  /\ active.on
  /\ active' = NoSession
  /\ UNCHANGED <<cache, sessions, log, branchOf>>



ExternalSwitch(w) ==
  /\ ~active.on
  /\ branchOf[w] = "b1"
  /\ branchOf' = [branchOf EXCEPT ![w] = "b2"]
  /\ UNCHANGED <<cache, sessions, active, log>>

Next ==
  \/ \E w \in Worktrees : Start(w)
  \/ \E kind \in {"step", "turn", "switch", "deliver", "skill", "remind", "resume", "outside"} : Continue(kind)
  \/ End
  \/ \E w \in Worktrees : ExternalSwitch(w)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------


TypeOK ==
  /\ sessions \in 0..MaxSessions
  /\ \A i \in 1..Len(log) : log[i].read \in 0..Len(log[i].req)


Budget == \A i \in 1..Len(log) : Cardinality(log[i].bps) <= Limit



SameWorktreeReuse ==
  \A i \in 1..Len(log) : log[i].first /\ log[i].worktreeSeen => log[i].read >= PosStable



WorktreeReuse ==
  \A i \in 1..Len(log) : log[i].first /\ log[i].repoSeen => log[i].read >= PosStable



CrossRepoReuse ==
  \A i \in 1..Len(log) : log[i].first /\ log[i].anySeen => log[i].read >= PosProfile



SessionReuse ==
  \A i \in 1..Len(log) : ~log[i].first /\ ~log[i].changed => log[i].read >= Len(log[i].prev)



ContextChangeKeepsStable ==
  \A i \in 1..Len(log) : log[i].changed => log[i].read >= PosStable







ContextChangeKeepsHistory ==
  \A i \in 1..Len(log) :
    log[i].changed /\ log[i].keep = LastKept(log[i].prev) => log[i].read >= Len(log[i].prev)





MidSessionKeepsHistory ==
  \A i \in 1..Len(log) : ~log[i].first => log[i].read >= log[i].keep




PreviousFullyReused ==
  \A i \in 1..Len(log) :
    ~log[i].first /\ log[i].keep = LastKept(log[i].prev) => log[i].read >= Len(log[i].prev)
=============================================================================
