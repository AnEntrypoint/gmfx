--------------------- MODULE AcpPermissionModesTrace ---------------------









EXTENDS AcpPermissionModes, AcpPermissionModesObs, Sequences

VARIABLE i

traceVars == <<vars, i>>

Match(o) ==
    /\ last.op = o.op
    /\ last.arg = o.arg
    /\ last.ok = o.ok
    /\ last.hasView = o.hasView
    /\ o.hasView => (last.view = o.view)
    /\ last.enforce = o.enforce
    /\ last.stored = o.stored

StepFor(o) ==
    CASE o.op = "set"    -> SetConfig(o.arg)
      [] o.op = "legacy" -> SetLegacy(o.arg)
      [] o.op = "prompt" -> Prompt
      [] o.op = "resume" -> Resume
      [] o.op = "fresh"  -> Fresh
      [] o.op = "new"    -> NewSession
      [] o.op = "other"  -> External(o.arg)
      [] o.op = "status" -> Status
      [] OTHER           -> FALSE

ASSUME Len(TraceLog) >= 1 /\ TraceLog[1].op = "new"

TraceInit == /\ i = 1
             /\ Init
             /\ Match(TraceLog[1])

TraceNext == /\ i < Len(TraceLog)
             /\ \E o \in {TraceLog[i + 1]} :
                    /\ StepFor(o)
                    /\ Match(o)'
             /\ i' = i + 1

NotDone == i < Len(TraceLog)
=============================================================================
