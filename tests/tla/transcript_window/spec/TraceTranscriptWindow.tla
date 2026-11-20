---- MODULE TraceTranscriptWindow ----















EXTENDS Integers, Sequences, FiniteSets, TraceData

CONSTANTS MaxSeq, Ids, MaxCycles, Window, Step, Slice, MaxTokens, Saved, OnlyOlder

VARIABLES
    cycle, cycleFirst, prevFirst, nextSeq, savedThrough, live, turnOpen,
    paintedThrough, reprinting,
    coOpen, coLo, coHi, coAtStart, pending, pendingDir, nextToken,
    out, act,
    alive, cycleStarts, painted,
    trace, at

TW == INSTANCE TranscriptWindow

vars == <<cycle, cycleFirst, prevFirst, nextSeq, savedThrough, live, turnOpen,
          paintedThrough, reprinting, coOpen, coLo, coHi, coAtStart, pending,
          pendingDir, nextToken, out, act, alive, cycleStarts, painted>>

Load(s) ==
    /\ cycle = s.cycle /\ cycleFirst = s.cycleFirst /\ prevFirst = s.prevFirst
    /\ nextSeq = s.nextSeq /\ savedThrough = s.savedThrough /\ live = s.live
    /\ turnOpen = s.turnOpen /\ paintedThrough = s.paintedThrough
    /\ reprinting = s.reprinting /\ coOpen = s.coOpen /\ coLo = s.coLo
    /\ coHi = s.coHi /\ coAtStart = s.coAtStart /\ pending = s.pending
    /\ pendingDir = s.pendingDir /\ nextToken = s.nextToken /\ out = s.out
    /\ act = s.act /\ alive = s.alive /\ cycleStarts = s.cycleStarts
    /\ painted = s.painted

LoadNext(s) ==
    /\ cycle' = s.cycle /\ cycleFirst' = s.cycleFirst /\ prevFirst' = s.prevFirst
    /\ nextSeq' = s.nextSeq /\ savedThrough' = s.savedThrough /\ live' = s.live
    /\ turnOpen' = s.turnOpen /\ paintedThrough' = s.paintedThrough
    /\ reprinting' = s.reprinting /\ coOpen' = s.coOpen /\ coLo' = s.coLo
    /\ coHi' = s.coHi /\ coAtStart' = s.coAtStart /\ pending' = s.pending
    /\ pendingDir' = s.pendingDir /\ nextToken' = s.nextToken /\ out' = s.out
    /\ act' = s.act /\ alive' = s.alive /\ cycleStarts' = s.cycleStarts
    /\ painted' = s.painted

TraceInit == trace \in 1..Len(Traces) /\ at = 1 /\ Load(Traces[trace][1])

TraceNext ==
    /\ at < Len(Traces[trace])
    /\ at' = at + 1
    /\ trace' = trace
    /\ LoadNext(Traces[trace][at + 1])

TraceSpec == TraceInit /\ [][TraceNext]_<<vars, trace, at>>


StartsAtInit == at = 1 => TW!Init


ConformsToSpec == [][TW!Next]_vars

TypeOK == TW!TypeOK
HeldIsRecentCycles == TW!HeldIsRecentCycles
LiveNeverDropped == TW!LiveNeverDropped
DropOnlySaved == TW!DropOnlySaved
PaintOnceInOrder == TW!PaintOnceInOrder
ReprintInOrder == TW!ReprintInOrder
ReprintSliceBound == TW!ReprintSliceBound
CtrlOWindowBound == TW!CtrlOWindowBound
OneReadInFlight == TW!OneReadInFlight
NoReadWhenUnsaved == TW!NoReadWhenUnsaved
RecoveredFromLog == TW!RecoveredFromLog
DropBetweenTurns == TW!DropBetweenTurns
ScreenHoldsHeld == TW!ScreenHoldsHeld
PaintedOnce == TW!PaintedOnce
ReadBounded == TW!ReadBounded
UpdateIsLocal == TW!UpdateIsLocal
OpenReadsNothing == TW!OpenReadsNothing
StaleReadIgnored == TW!StaleReadIgnored
====
