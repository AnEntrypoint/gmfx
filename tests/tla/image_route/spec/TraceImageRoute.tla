--------------------------- MODULE TraceImageRoute ---------------------------















EXTENDS Naturals, Sequences, TraceData

VARIABLES support, resolved, notified, pending, out, act, trace, at

IR == INSTANCE ImageRoute

vars == <<support, resolved, notified, pending, out, act>>

Load(s) ==
    /\ support = s.support
    /\ resolved = s.resolved
    /\ notified = s.notified
    /\ pending = s.pending
    /\ out = s.out
    /\ act = s.act

LoadNext(s) ==
    /\ support' = s.support
    /\ resolved' = s.resolved
    /\ notified' = s.notified
    /\ pending' = s.pending
    /\ out' = s.out
    /\ act' = s.act

TraceInit == trace \in 1..Len(Traces) /\ at = 1 /\ Load(Traces[trace][1])

TraceNext ==
    /\ at < Len(Traces[trace])
    /\ at' = at + 1
    /\ trace' = trace
    /\ LoadNext(Traces[trace][at + 1])

TraceSpec == TraceInit /\ [][TraceNext]_<<vars, trace, at>>


StartsAtInit == at = 1 => IR!Init


ConformsToSpec == [][IR!Next]_vars

TypeOK == IR!TypeOK
Bounded == IR!Bounded
VisionImpliesNative == IR!VisionImpliesNative
UnknownNeverInline == IR!UnknownNeverInline
OneSnapshot == IR!OneSnapshot
RouteModeCoherent == IR!RouteModeCoherent
NativeExcludesFallback == IR!NativeExcludesFallback
NoSilentWithhold == IR!NoSilentWithhold
RequiredWhenPending == IR!RequiredWhenPending
FailExactlyWhenUnroutable == IR!FailExactlyWhenUnroutable
ResolveOnlyWhenNeeded == IR!ResolveOnlyWhenNeeded
AskedBeforeUnknown == IR!AskedBeforeUnknown
NotifyOnlyWhenDown == IR!NotifyOnlyWhenDown
DecideOnlyWhenReady == IR!DecideOnlyWhenReady
TurnResets == IR!TurnResets
PendingWaitsForReply == IR!PendingWaitsForReply
ResolveOncePerTurn == IR!ResolveOncePerTurn
NotifyOncePerTurn == IR!NotifyOncePerTurn
DuplicateRequestIsQuiet == IR!DuplicateRequestIsQuiet
StaleReplyIsQuiet == IR!StaleReplyIsQuiet
=============================================================================
