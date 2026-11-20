------------------------------ MODULE TurnStream ------------------------------



































EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS Calls, MaxBuilds, MissedPaths, Compactions, Recovery, Faults, Mutant

Mutants == {"none", "restamp", "lose_on_recover", "share_stamp", "bytes_only",
            "loose_compare", "mix_on_mismatch", "prefix_only"}

ASSUME Mutant \in Mutants
ASSUME MaxBuilds \in Nat
ASSUME {MissedPaths, Compactions, Recovery, Faults} \subseteq BOOLEAN

None == "none"

VARIABLES
  done,
  cut,
  changed,
  dropped,
  builds,
  streamed,
  open,
  log,
  committed,
  final,
  birthOf,
  stampedAt,
  recovered,
  shifted,
  supersedes,
  unexplained,
  reparsed,
  anyParsed,
  last

vars == <<done, cut, changed, dropped, builds, streamed, open, log, committed,
          final, birthOf, stampedAt, recovered, shifted, supersedes,
          unexplained, reparsed, anyParsed, last>>

Range(s) == {s[i] : i \in DOMAIN s}

Stamp(n, c) == [at |-> n, of |-> c]
NoStamp == Stamp(0, None)
Piece(c, body, stamp) == [call |-> c, body |-> body, stamp |-> stamp]
NoPiece == Piece(None, 0, NoStamp)
Stamps == [at : 0..MaxBuilds, of : Calls]
Pieces == [call : Calls, body : {0, 1}, stamp : Stamps]
Results == [call : Calls, birth : Stamps, stamped : BOOLEAN]

Line(kind, p) == [kind |-> kind, piece |-> p]
Superseded == Line("superseded", NoPiece)
Interrupted == Line("interrupted", NoPiece)
End == Line("end", NoPiece)
AsLines(s) == [i \in 1..Len(s) |-> Line("piece", s[i])]

Decision(phase, stood, results, count) ==
  [phase |-> phase, stood |-> stood, results |-> results, reparsed |-> count]


View ==
  SelectSeq(SubSeq(done, cut + 1, Len(done)), LAMBDA r : r.call \notin dropped)


StampFor(r, n) ==
  IF r.stamped /\ Mutant # "restamp" THEN r.birth ELSE Stamp(n, r.call)


Fresh(n) ==
  LET v == View
  IN [i \in 1..Len(v) |->
        Piece(v[i].call, IF v[i].call \in changed THEN 1 ELSE 0, StampFor(v[i], n))]

SameBytes(x, y) == x = y


SameButStamp(x, y) == x.call = y.call /\ x.body = y.body

SamePiece(x, y) ==
  CASE Mutant = "bytes_only"    -> SameBytes(x, y)
    [] Mutant = "loose_compare" -> x.call = y.call
    [] OTHER                    -> SameBytes(x, y) \/ SameButStamp(x, y)


Stands(b) ==
  /\ Mutant = "prefix_only" \/ Len(streamed) <= Len(b)
  /\ \A i \in 1..Len(streamed) : i <= Len(b) => SamePiece(streamed[i], b[i])

Mixes == Mutant = "mix_on_mismatch"

After(b) == SubSeq(b, Len(streamed) + 1, Len(b))
NewPieces(b) == IF Len(streamed) <= Len(b) THEN After(b) ELSE <<>>

Held(b) ==
  IF ~open THEN b
  ELSE IF Stands(b) \/ Mixes THEN streamed \o NewPieces(b)
  ELSE b

Lines(b) ==
  IF ~open THEN AsLines(b)
  ELSE IF Stands(b) \/ Mixes THEN AsLines(NewPieces(b))
  ELSE <<Superseded>> \o AsLines(b)

Faultless == changed \cup dropped = {}



Parsed(b) ==
  {i \in 1..Len(streamed) : i <= Len(b) /\ ~SameBytes(streamed[i], b[i])}
StampedParsed(b) ==
  {i \in Parsed(b) : \E r \in Range(done) : r.call = b[i].call /\ r.stamped}

Decide(b, phase) ==
  LET stands     == ~open \/ Stands(b)
      supersede  == ~stands /\ ~Mixes
      count      == IF open /\ Stands(b) THEN Cardinality(Parsed(b)) ELSE 0
      stampedOne == IF open /\ Stands(b) THEN Cardinality(StampedParsed(b)) ELSE 0
  IN /\ supersedes' = supersedes + (IF supersede THEN 1 ELSE 0)
     /\ unexplained' = unexplained + (IF supersede /\ Faultless /\ ~shifted THEN 1 ELSE 0)
     /\ reparsed' = reparsed + stampedOne
     /\ anyParsed' = anyParsed + count
     /\ last' = Decision(phase, stands, Len(b), count)
     /\ shifted' = FALSE

Init ==
  /\ done = <<>>
  /\ cut = 0
  /\ changed = {}
  /\ dropped = {}
  /\ builds = 0
  /\ streamed = <<>>
  /\ open = FALSE
  /\ log = <<>>
  /\ committed = FALSE
  /\ final = <<>>
  /\ birthOf = [c \in Calls |-> NoStamp]
  /\ stampedAt = {}
  /\ recovered = FALSE
  /\ shifted = FALSE
  /\ supersedes = 0
  /\ unexplained = 0
  /\ reparsed = 0
  /\ anyParsed = 0
  /\ last = Decision(None, TRUE, 0, 0)



RunTool(c, stamped) ==
  /\ ~committed

  /\ birthOf[c] = NoStamp
  /\ stamped \/ MissedPaths
  /\ LET own   == Stamp(builds, c)
         prior == done[Len(done)].birth
         birth == IF Mutant = "share_stamp" /\ Len(done) > 0 /\ prior.at = builds
                  THEN prior ELSE own
     IN /\ done' = Append(done, [call |-> c, birth |-> birth, stamped |-> stamped])
        /\ birthOf' = [birthOf EXCEPT ![c] = birth]
  /\ stampedAt' = IF stamped THEN stampedAt \cup {c} ELSE stampedAt
  /\ UNCHANGED <<cut, changed, dropped, builds, streamed, open, log, committed,
                 final, recovered, shifted, supersedes, unexplained, reparsed,
                 anyParsed, last>>


Compact(k) ==
  /\ Compactions
  /\ ~committed
  /\ k \in 1..(Len(done) - cut)
  /\ cut' = cut + k
  /\ shifted' = TRUE
  /\ UNCHANGED <<done, changed, dropped, builds, streamed, open, log, committed,
                 final, birthOf, stampedAt, recovered, supersedes, unexplained,
                 reparsed, anyParsed, last>>





Recover ==
  /\ Recovery
  /\ ~recovered
  /\ ~committed
  /\ open
  /\ LET v == View
     IN done' = [i \in 1..Len(v) |->
                   [call    |-> v[i].call,
                    birth   |-> StampFor(v[i], builds),
                    stamped |-> Mutant # "lose_on_recover"]]
  /\ cut' = 0
  /\ dropped' = {}
  /\ recovered' = TRUE
  /\ open' = FALSE
  /\ streamed' = <<>>
  /\ log' = log \o <<Interrupted>>
  /\ UNCHANGED <<changed, builds, committed, final, birthOf, stampedAt, shifted,
                 supersedes, unexplained, reparsed, anyParsed, last>>


Change(c) ==
  /\ Faults
  /\ ~committed
  /\ Faultless
  /\ c \in {p.call : p \in Range(streamed)}
  /\ changed' = {c}
  /\ UNCHANGED <<done, cut, dropped, builds, streamed, open, log, committed,
                 final, birthOf, stampedAt, recovered, shifted, supersedes,
                 unexplained, reparsed, anyParsed, last>>


Drop(c) ==
  /\ Faults
  /\ ~committed
  /\ Faultless
  /\ c \in {p.call : p \in Range(streamed)}
  /\ dropped' = {c}
  /\ UNCHANGED <<done, cut, changed, builds, streamed, open, log, committed,
                 final, birthOf, stampedAt, recovered, shifted, supersedes,
                 unexplained, reparsed, anyParsed, last>>


Stream ==
  /\ ~committed
  /\ builds < MaxBuilds
  /\ builds' = builds + 1
  /\ LET b == Fresh(builds + 1)
     IN /\ log' = log \o Lines(b)
        /\ streamed' = Held(b)
        /\ Decide(b, "stream")
  /\ open' = TRUE
  /\ UNCHANGED <<done, cut, changed, dropped, committed, final, birthOf,
                 stampedAt, recovered>>


Commit ==
  /\ ~committed
  /\ builds < MaxBuilds
  /\ builds' = builds + 1
  /\ LET b == Fresh(builds + 1)
     IN /\ log' = log \o Lines(b) \o <<End>>
        /\ Decide(b, "commit")
        /\ final' = b
  /\ streamed' = <<>>
  /\ committed' = TRUE
  /\ open' = FALSE
  /\ UNCHANGED <<done, cut, changed, dropped, birthOf, stampedAt, recovered>>

Next ==
  \/ \E c \in Calls, stamped \in BOOLEAN : RunTool(c, stamped)
  \/ \E c \in Calls : Change(c) \/ Drop(c)
  \/ \E k \in 1..Cardinality(Calls) : Compact(k)
  \/ Recover
  \/ Stream
  \/ Commit

Spec == Init /\ [][Next]_vars

----------------------------------------------------------------------------


LastMark ==
  LET marks == {i \in 1..Len(log) : log[i].kind \in {"superseded", "interrupted"}}
  IN IF marks = {} THEN 0 ELSE CHOOSE i \in marks : \A j \in marks : j <= i

LiveTurn ==
  LET lines == SelectSeq(SubSeq(log, LastMark + 1, Len(log)), LAMBDA l : l.kind = "piece")
  IN [i \in 1..Len(lines) |-> lines[i].piece]

LiveCalls == [i \in 1..Len(LiveTurn) |-> LiveTurn[i].call]

Content(s) == [i \in 1..Len(s) |-> <<s[i].call, s[i].body>>]

AllStamped == \A r \in Range(done) : r.stamped

TypeOK ==
  /\ done \in Seq(Results)
  /\ cut \in 0..Cardinality(Calls)
  /\ changed \subseteq Calls
  /\ dropped \subseteq Calls
  /\ builds \in 0..MaxBuilds
  /\ streamed \in Seq(Pieces)
  /\ open \in BOOLEAN
  /\ committed \in BOOLEAN
  /\ \A i \in 1..Len(log) :
       \/ log[i].kind = "piece" /\ log[i].piece \in Pieces
       \/ log[i].kind \in {"superseded", "interrupted", "end"} /\ log[i].piece = NoPiece
  /\ stampedAt \subseteq Calls
  /\ {supersedes, unexplained, reparsed, anyParsed} \subseteq Nat



CommitIsFinal == committed => Content(LiveTurn) = Content(final)



CommitIsWritten == committed /\ AllStamped => LiveTurn = final



SupersedeExplained == unexplained = 0


NoReparseOfStamped == reparsed = 0


StampIsOwn ==
  \A i \in 1..Len(log) :
    log[i].kind = "piece" => log[i].piece.stamp.of = log[i].piece.call



StampIsBirth ==
  \A i \in 1..Len(log) :
    /\ log[i].kind = "piece"
    /\ log[i].piece.call \in stampedAt
    => log[i].piece.stamp = birthOf[log[i].piece.call]


NeverSuperseded == supersedes = 0
NeverCommittedWhole == ~(committed /\ Len(final) = Cardinality(Calls) /\ builds >= 3)
NeverCommittedAfterCut == ~(committed /\ cut > 0 /\ Len(final) > 0)
NeverCommittedAfterRecovery == ~(committed /\ recovered /\ Len(final) > 0)
MissedPathsNeverParse == anyParsed = 0
=============================================================================
