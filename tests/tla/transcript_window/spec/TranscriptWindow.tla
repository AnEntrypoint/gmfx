---- MODULE TranscriptWindow ----











EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    MaxSeq,
    Ids,
    MaxCycles,
    Window,
    Step,
    Slice,
    MaxTokens,
    Saved,
    OnlyOlder

None == MaxSeq + 1

VARIABLES
    cycle, cycleFirst, prevFirst, nextSeq, savedThrough, live, turnOpen,
    paintedThrough, reprinting,
    coOpen, coLo, coHi, coAtStart, pending, pendingDir, nextToken,
    out, act,
    alive, cycleStarts,
    painted

core == <<cycle, cycleFirst, prevFirst, nextSeq, savedThrough, live, turnOpen,
          paintedThrough, reprinting, coOpen, coLo, coHi, coAtStart, pending,
          pendingDir, nextToken>>
vars == <<core, out, act, alive, cycleStarts, painted>>

Min(a, b) == IF a < b THEN a ELSE b
Max(a, b) == IF a > b THEN a ELSE b
SetMax(S) == CHOOSE x \in S : \A y \in S : y <= x
HeldFirst == IF prevFirst = None THEN cycleFirst ELSE prevFirst
Range(s) == {s[i] : i \in DOMAIN s}
Effects == Range(out)

Init ==
    /\ cycle = 0 /\ cycleFirst = 0 /\ prevFirst = None /\ nextSeq = 0
    /\ savedThrough = 0 /\ live = {} /\ turnOpen = FALSE
    /\ paintedThrough = 0 /\ reprinting = FALSE
    /\ coOpen = FALSE /\ coLo = 0 /\ coHi = 0 /\ coAtStart = FALSE
    /\ pending = 0 /\ pendingDir = "older" /\ nextToken = 1
    /\ out = <<>> /\ act = [name |-> "Init"]
    /\ alive = TRUE /\ cycleStarts = {0}
    /\ painted = {}


CanDrop(po, cf, open, st) ==
    /\ po # None
    /\ ~open
    /\ (~Saved \/ st >= cf)


DropEffect(from, to) == IF from < to THEN <<[kind |-> "drop", from |-> from, to |-> to]>> ELSE <<>>


AfterDrop(pt, cf) == IF reprinting /\ pt < cf THEN cf ELSE pt

-----------------------------------------------------------------------------


TurnStarted ==
    /\ alive /\ ~turnOpen
    /\ turnOpen' = TRUE /\ out' = <<>> /\ act' = [name |-> "TurnStarted"]
    /\ UNCHANGED <<cycle, cycleFirst, prevFirst, nextSeq, savedThrough, live,
                   paintedThrough, reprinting, coOpen, coLo, coHi, coAtStart,
                   pending, pendingDir, nextToken, alive, cycleStarts>>

TurnEnded ==
    /\ alive /\ turnOpen /\ live = {}
    /\ turnOpen' = FALSE /\ act' = [name |-> "TurnEnded"]
    /\ IF CanDrop(prevFirst, cycleFirst, FALSE, savedThrough)
          THEN /\ out' = DropEffect(prevFirst, cycleFirst)
               /\ prevFirst' = None
               /\ paintedThrough' = AfterDrop(paintedThrough, cycleFirst)
          ELSE /\ out' = <<>> /\ UNCHANGED <<prevFirst, paintedThrough>>
    /\ UNCHANGED <<cycle, cycleFirst, nextSeq, savedThrough, live, reprinting,
                   coOpen, coLo, coHi, coAtStart, pending, pendingDir, nextToken,
                   alive, cycleStarts>>


BlockOpened(id) ==
    /\ alive /\ turnOpen /\ id \notin live
    /\ nextSeq + Cardinality(live) < MaxSeq
    /\ live' = live \cup {id} /\ out' = <<>> /\ act' = [name |-> "BlockOpened", id |-> id]
    /\ UNCHANGED <<cycle, cycleFirst, prevFirst, nextSeq, savedThrough, turnOpen,
                   paintedThrough, reprinting, coOpen, coLo, coHi, coAtStart,
                   pending, pendingDir, nextToken, alive, cycleStarts>>

BlockChanged(id) ==
    /\ alive /\ id \in live
    /\ out' = <<[kind |-> "repaint_block", id |-> id]>> /\ act' = [name |-> "BlockChanged", id |-> id]
    /\ UNCHANGED <<core, alive, cycleStarts>>



BlockFinished(id) ==
    /\ alive
    /\ IF id \in live THEN nextSeq < MaxSeq ELSE nextSeq + Cardinality(live) < MaxSeq
    /\ live' = live \ {id} /\ nextSeq' = nextSeq + 1 /\ act' = [name |-> "BlockFinished", id |-> id]
    /\ IF reprinting
          THEN /\ out' = <<>> /\ UNCHANGED paintedThrough
          ELSE /\ out' = <<[kind |-> "paint_final", seq |-> nextSeq]>>
               /\ paintedThrough' = nextSeq + 1
    /\ UNCHANGED <<cycle, cycleFirst, prevFirst, savedThrough, turnOpen,
                   reprinting, coOpen, coLo, coHi, coAtStart, pending,
                   pendingDir, nextToken, alive, cycleStarts>>



SavedThrough(through) ==
    /\ alive /\ Saved
    /\ through > savedThrough /\ through <= nextSeq
    /\ savedThrough' = Min(through, nextSeq) /\ act' = [name |-> "SavedThrough", through |-> through]
    /\ IF CanDrop(prevFirst, cycleFirst, turnOpen, Min(through, nextSeq))
          THEN /\ out' = DropEffect(prevFirst, cycleFirst)
               /\ prevFirst' = None
               /\ paintedThrough' = AfterDrop(paintedThrough, cycleFirst)
          ELSE /\ out' = <<>> /\ UNCHANGED <<prevFirst, paintedThrough>>
    /\ UNCHANGED <<cycle, cycleFirst, nextSeq, live, turnOpen, reprinting,
                   coOpen, coLo, coHi, coAtStart, pending, pendingDir, nextToken,
                   alive, cycleStarts>>






Compacted ==
    /\ alive /\ cycle < MaxCycles
    /\ LET po == IF prevFirst = None THEN cycleFirst ELSE prevFirst
       IN /\ cycle' = cycle + 1
          /\ cycleFirst' = nextSeq
          /\ cycleStarts' = cycleStarts \cup {nextSeq}
          /\ IF CanDrop(po, nextSeq, turnOpen, savedThrough)
                THEN /\ out' = DropEffect(po, nextSeq)
                     /\ prevFirst' = None
                     /\ paintedThrough' = AfterDrop(paintedThrough, nextSeq)
                ELSE /\ out' = <<>> /\ prevFirst' = po /\ UNCHANGED paintedThrough
    /\ act' = [name |-> "Compacted"]
    /\ UNCHANGED <<nextSeq, savedThrough, live, turnOpen, reprinting, coOpen,
                   coLo, coHi, coAtStart, pending, pendingDir, nextToken, alive>>

Resized ==
    /\ alive
    /\ reprinting' = TRUE /\ paintedThrough' = HeldFirst
    /\ out' = <<[kind |-> "reprint_begin"]>> /\ act' = [name |-> "Resized"]
    /\ UNCHANGED <<cycle, cycleFirst, prevFirst, nextSeq, savedThrough, live,
                   turnOpen, coOpen, coLo, coHi, coAtStart, pending, pendingDir,
                   nextToken, alive, cycleStarts>>

ReprintTick ==
    /\ alive /\ reprinting
    /\ act' = [name |-> "ReprintTick"]
    /\ IF paintedThrough >= nextSeq
          THEN /\ reprinting' = FALSE /\ out' = <<[kind |-> "repaint_live"]>>
               /\ UNCHANGED paintedThrough
          ELSE /\ out' = <<[kind |-> "reprint_slice", from |-> paintedThrough,
                            to |-> Min(paintedThrough + Slice, nextSeq)]>>
               /\ paintedThrough' = Min(paintedThrough + Slice, nextSeq)
               /\ UNCHANGED reprinting
    /\ UNCHANGED <<cycle, cycleFirst, prevFirst, nextSeq, savedThrough, live,
                   turnOpen, coOpen, coLo, coHi, coAtStart, pending, pendingDir,
                   nextToken, alive, cycleStarts>>

CtrlOOpened ==
    /\ alive /\ ~coOpen
    /\ coOpen' = TRUE /\ coHi' = nextSeq
    /\ coLo' = Max(HeldFirst, IF nextSeq > Window THEN nextSeq - Window ELSE 0)
    /\ coAtStart' = (Max(HeldFirst, IF nextSeq > Window THEN nextSeq - Window ELSE 0) = 0)
    /\ pending' = 0
    /\ out' = <<[kind |-> "ctrlo_show",
                 lo |-> Max(HeldFirst, IF nextSeq > Window THEN nextSeq - Window ELSE 0),
                 hi |-> nextSeq]>>
    /\ act' = [name |-> "CtrlOOpened"]
    /\ UNCHANGED <<cycle, cycleFirst, prevFirst, nextSeq, savedThrough, live,
                   turnOpen, paintedThrough, reprinting, pendingDir, nextToken,
                   alive, cycleStarts>>

CtrlOScrolledOlder ==
    /\ alive /\ coOpen /\ pending = 0 /\ coLo > 0
    /\ act' = [name |-> "CtrlOScrolledOlder"]
    /\ IF coLo > HeldFirst
          THEN /\ coLo' = coLo - 1
               /\ coHi' = Min(coHi, coLo - 1 + Window)
               /\ coAtStart' = (coLo - 1 = 0)
               /\ out' = <<[kind |-> "ctrlo_show", lo |-> coLo - 1, hi |-> Min(coHi, coLo - 1 + Window)]>>
               /\ UNCHANGED <<pending, pendingDir, nextToken>>
          ELSE IF Saved


               THEN /\ nextToken <= MaxTokens
                    /\ pending' = nextToken /\ pendingDir' = "older"
                    /\ nextToken' = nextToken + 1
                    /\ out' = <<[kind |-> "read_log", token |-> nextToken, dir |-> "older",
                                 from |-> coLo, count |-> Step]>>
                    /\ UNCHANGED <<coLo, coHi, coAtStart>>
               ELSE /\ coAtStart' = TRUE
                    /\ out' = <<>>
                    /\ UNCHANGED <<coLo, coHi, pending, pendingDir, nextToken>>
    /\ UNCHANGED <<cycle, cycleFirst, prevFirst, nextSeq, savedThrough, live,
                   turnOpen, paintedThrough, reprinting, coOpen, alive, cycleStarts>>

CtrlOScrolledNewer ==
    /\ alive /\ coOpen /\ pending = 0 /\ coHi < nextSeq /\ ~OnlyOlder
    /\ act' = [name |-> "CtrlOScrolledNewer"]
    /\ IF coHi >= HeldFirst
          THEN /\ coHi' = coHi + 1
               /\ coLo' = Max(coLo, coHi + 1 - Window)
               /\ coAtStart' = (Max(coLo, coHi + 1 - Window) = 0)
               /\ out' = <<[kind |-> "ctrlo_show", lo |-> Max(coLo, coHi + 1 - Window), hi |-> coHi + 1]>>
               /\ UNCHANGED <<pending, pendingDir, nextToken>>
          ELSE IF ~Saved

               THEN /\ coLo' = HeldFirst /\ coHi' = Min(HeldFirst + 1, nextSeq)
                    /\ coAtStart' = (HeldFirst = 0)
                    /\ out' = <<[kind |-> "ctrlo_show", lo |-> HeldFirst, hi |-> Min(HeldFirst + 1, nextSeq)]>>
                    /\ UNCHANGED <<pending, pendingDir, nextToken>>
          ELSE /\ nextToken <= MaxTokens
               /\ pending' = nextToken /\ pendingDir' = "newer"
               /\ nextToken' = nextToken + 1
               /\ out' = <<[kind |-> "read_log", token |-> nextToken, dir |-> "newer",
                            from |-> coHi, count |-> Step]>>
               /\ UNCHANGED <<coLo, coHi, coAtStart>>
    /\ UNCHANGED <<cycle, cycleFirst, prevFirst, nextSeq, savedThrough, live,
                   turnOpen, paintedThrough, reprinting, coOpen, alive, cycleStarts>>

CtrlOClosed ==
    /\ alive /\ coOpen /\ ~OnlyOlder
    /\ coOpen' = FALSE /\ pending' = 0 /\ out' = <<>> /\ act' = [name |-> "CtrlOClosed"]
    /\ UNCHANGED <<cycle, cycleFirst, prevFirst, nextSeq, savedThrough, live,
                   turnOpen, paintedThrough, reprinting, coLo, coHi, coAtStart,
                   pendingDir, nextToken, alive, cycleStarts>>



Available(dir) == IF dir = "older" THEN coLo ELSE nextSeq - coHi
LogReadDone(token, count) ==
    /\ alive /\ token \in 1..(nextToken - 1) /\ count \in 0..(Step + 1)

    /\ OnlyOlder => (coOpen /\ token = pending /\ count = Min(Step, Available(pendingDir)))
    /\ act' = [name |-> "LogReadDone", token |-> token, count |-> count]
    /\ IF coOpen /\ pending = token
          THEN LET n == Min(Min(count, Step), Available(pendingDir))
                   lo2 == IF pendingDir = "older" THEN coLo - n ELSE Max(coLo, coHi + n - Window)
                   hi2 == IF pendingDir = "older" THEN Min(coHi, coLo - n + Window) ELSE coHi + n
               IN /\ coLo' = lo2 /\ coHi' = hi2
                  /\ coAtStart' = (lo2 = 0 \/ (pendingDir = "older" /\ n = 0))
                  /\ pending' = 0
                  /\ out' = <<[kind |-> "ctrlo_show", lo |-> lo2, hi |-> hi2]>>
          ELSE /\ out' = <<>> /\ UNCHANGED <<coLo, coHi, coAtStart, pending>>
    /\ UNCHANGED <<cycle, cycleFirst, prevFirst, nextSeq, savedThrough, live,
                   turnOpen, paintedThrough, reprinting, coOpen, pendingDir,
                   nextToken, alive, cycleStarts>>


LogReadFailed(token) ==
    /\ alive /\ ~OnlyOlder /\ token \in 1..(nextToken - 1)
    /\ act' = [name |-> "LogReadFailed", token |-> token]
    /\ IF coOpen /\ pending = token THEN pending' = 0 ELSE UNCHANGED pending
    /\ out' = <<>>
    /\ UNCHANGED <<cycle, cycleFirst, prevFirst, nextSeq, savedThrough, live,
                   turnOpen, paintedThrough, reprinting, coOpen, coLo, coHi,
                   coAtStart, pendingDir, nextToken, alive, cycleStarts>>



Crash ==
    /\ alive /\ Saved /\ ~OnlyOlder
    /\ alive' = FALSE /\ out' = <<>> /\ act' = [name |-> "Crash"]
    /\ UNCHANGED <<core, cycleStarts>>





Resumed ==
    /\ Saved /\ (~alive \/ ~OnlyOlder)
    /\ LET last == SetMax({c \in cycleStarts : c <= savedThrough}) IN
       /\ alive' = TRUE
       /\ nextSeq' = savedThrough /\ cycleFirst' = last /\ prevFirst' = None
       /\ cycleStarts' = {c \in cycleStarts : c <= savedThrough}
       /\ live' = {} /\ turnOpen' = FALSE
       /\ reprinting' = TRUE /\ paintedThrough' = last
       /\ coOpen' = FALSE /\ coLo' = 0 /\ coHi' = 0 /\ coAtStart' = FALSE
       /\ pending' = 0
       /\ out' = <<[kind |-> "reprint_begin"]>> /\ act' = [name |-> "Resumed"]

       /\ nextToken' = 1 /\ pendingDir' = "older"
    /\ UNCHANGED <<cycle, savedThrough>>

-----------------------------------------------------------------------------

UserMoves ==
    \/ TurnStarted \/ TurnEnded
    \/ \E id \in Ids : BlockOpened(id) \/ BlockChanged(id) \/ BlockFinished(id)
    \/ Compacted \/ Resized \/ ReprintTick
    \/ CtrlOOpened \/ CtrlOScrolledOlder \/ CtrlOScrolledNewer \/ CtrlOClosed

EnvMoves ==
    \/ \E t \in 1..MaxSeq : SavedThrough(t)
    \/ \E t \in 1..MaxTokens, c \in 0..(Step + 1) : LogReadDone(t, c)
    \/ \E t \in 1..MaxTokens : LogReadFailed(t)
    \/ Crash \/ Resumed



PaintedBy(o) ==
    UNION {IF o[i].kind = "paint_final" THEN {o[i].seq}
           ELSE IF o[i].kind = "reprint_slice" THEN o[i].from..(o[i].to - 1)
           ELSE {} : i \in DOMAIN o}
PaintedUpdate ==
    painted' = IF act'.name \in {"Resized", "Resumed"} THEN {} ELSE painted \cup PaintedBy(out')

Next == (UserMoves \/ EnvMoves) /\ PaintedUpdate


GoodReply == LogReadDone(pending, Min(Step, Available(pendingDir)))


Fairness ==
    /\ WF_vars(ReprintTick /\ PaintedUpdate)
    /\ WF_vars((\E t \in 1..MaxSeq : SavedThrough(t)) /\ PaintedUpdate)
    /\ WF_vars(TurnEnded /\ PaintedUpdate)
    /\ WF_vars((\E id \in Ids : BlockFinished(id)) /\ PaintedUpdate)

    /\ WF_vars(~alive /\ Resumed /\ PaintedUpdate)
    /\ SF_vars(GoodReply /\ PaintedUpdate)
    /\ (OnlyOlder => WF_vars(CtrlOScrolledOlder /\ PaintedUpdate))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------


TypeOK ==
    /\ cycle \in 0..MaxCycles
    /\ cycleFirst \in 0..MaxSeq /\ nextSeq \in 0..MaxSeq /\ savedThrough \in 0..MaxSeq
    /\ prevFirst \in 0..MaxSeq \cup {None}
    /\ live \subseteq Ids /\ turnOpen \in BOOLEAN
    /\ paintedThrough \in 0..MaxSeq /\ reprinting \in BOOLEAN
    /\ coOpen \in BOOLEAN /\ coLo \in 0..MaxSeq /\ coHi \in 0..MaxSeq
    /\ pending \in 0..MaxTokens /\ nextToken \in 1..(MaxTokens + 1)
    /\ alive \in BOOLEAN


HeldIsRecentCycles ==
    (alive /\ ~turnOpen /\ (~Saved \/ savedThrough >= cycleFirst)) => prevFirst = None


LiveNeverDropped ==
    \A e \in Effects : e.kind = "drop" => (e.from < e.to /\ e.to <= cycleFirst)


DropOnlySaved == Saved => \A e \in Effects : e.kind = "drop" => e.to <= savedThrough


PaintOnceInOrder ==
    /\ (alive /\ ~reprinting) => paintedThrough = nextSeq
    /\ \A e \in Effects : e.kind = "paint_final" => e.seq = nextSeq - 1


ReprintInOrder == (alive /\ reprinting) => (HeldFirst <= paintedThrough /\ paintedThrough <= nextSeq)


ReprintSliceBound ==
    \A e \in Effects : e.kind = "reprint_slice" => (e.from < e.to /\ e.to - e.from <= Slice)


CtrlOWindowBound ==
    coOpen => (coLo <= coHi /\ coHi <= nextSeq /\ coHi - coLo <= Window)


OneReadInFlight == pending # 0 => coOpen


NoReadWhenUnsaved == ~Saved => \A e \in Effects : e.kind # "read_log"


DropBetweenTurns == \A e \in Effects : e.kind = "drop" => ~turnOpen


ScreenHoldsHeld == (alive /\ ~reprinting) => (HeldFirst..(nextSeq - 1)) \subseteq painted


RecoveredFromLog ==
    act.name = "Resumed" =>
        /\ nextSeq = savedThrough /\ cycleFirst \in cycleStarts

        /\ prevFirst = None /\ live = {} /\ ~turnOpen /\ ~coOpen /\ pending = 0


UpdateIsLocal ==
    [][(act'.name = "BlockChanged") =>
        (UNCHANGED core /\ Len(out') = 1 /\ out'[1].kind = "repaint_block")]_vars


OpenReadsNothing ==
    [][(act'.name = "CtrlOOpened") =>
        /\ \A i \in DOMAIN out' : out'[i].kind # "read_log"
        /\ coHi' = nextSeq /\ coLo' >= HeldFirst]_vars


ReadBounded ==
    [][(act'.name = "LogReadDone") => (coLo - coLo' <= Step /\ coHi' - coHi <= Step)]_vars


StaleReadIgnored ==
    [][((act'.name = "LogReadDone" \/ act'.name = "LogReadFailed") /\ ~(coOpen /\ pending # 0 /\ act'.token = pending))
        => UNCHANGED core]_vars


PaintedOnce == [][PaintedBy(out') \cap (IF act'.name \in {"Resized", "Resumed"} THEN {} ELSE painted) = {}]_vars


PreviousCycleDropped == (alive /\ prevFirst # None) ~> (prevFirst = None \/ ~alive)


ReprintFinishes == (alive /\ reprinting) ~> (~reprinting \/ ~alive \/ act.name \in {"Resized", "Resumed"})




CtrlOReachesStart == (OnlyOlder /\ coOpen) ~> (coLo = 0)
====
