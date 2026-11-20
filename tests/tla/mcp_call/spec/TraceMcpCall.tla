---------------------------- MODULE TraceMcpCall ----------------------------

















EXTENDS Naturals, Sequences, FiniteSets, TraceData

CONSTANTS MaxInFlight, MaxIds

VARIABLES open, registered, next, entries, out, act, trace, at

MC == INSTANCE McpCall

vars == <<open, registered, next, entries, out, act>>

ToSet(s) == {s[i] : i \in DOMAIN s}

Load(s) ==
    /\ open = s.open
    /\ registered = ToSet(s.registered)
    /\ next = s.next
    /\ entries = ToSet(s.entries)
    /\ out = ToSet(s.out)
    /\ act = s.act

LoadNext(s) ==
    /\ open' = s.open
    /\ registered' = ToSet(s.registered)
    /\ next' = s.next
    /\ entries' = ToSet(s.entries)
    /\ out' = ToSet(s.out)
    /\ act' = s.act

TraceInit == trace \in 1..Len(Traces) /\ at = 1 /\ Load(Traces[trace][1])

TraceNext ==
    /\ at < Len(Traces[trace])
    /\ at' = at + 1
    /\ trace' = trace
    /\ LoadNext(Traces[trace][at + 1])

TraceSpec == TraceInit /\ [][TraceNext]_<<vars, trace, at>>


StartsAtInit == at = 1 => MC!Init


ConformsToSpec == [][MC!Next]_vars

TypeOK == MC!TypeOK
Bounded == MC!Bounded
IdsBelowNext == MC!IdsBelowNext
EffectsCarryEntryOwner == MC!EffectsCarryEntryOwner
LiveWorkHasOwner == MC!LiveWorkHasOwner
ClosedIsQuiet == MC!ClosedIsQuiet
CrashResets == MC!CrashResets
AdmitOnlyValid == MC!AdmitOnlyValid
RefusalsAreQuiet == MC!RefusalsAreQuiet
FreshIds == MC!FreshIds
CallOnlyFromAuthorizing == MC!CallOnlyFromAuthorizing
StagesOnlyAdvance == MC!StagesOnlyAdvance
OneReplyPerRequest == MC!OneReplyPerRequest
ReplyMatchesOutcome == MC!ReplyMatchesOutcome
StaleIsQuiet == MC!StaleIsQuiet
DroppedStateIsLogged == MC!DroppedStateIsLogged
=============================================================================
