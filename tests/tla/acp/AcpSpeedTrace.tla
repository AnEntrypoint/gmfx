---------------------------- MODULE AcpSpeedTrace ----------------------------













EXTENDS AcpSpeed, AcpSpeedObs, Sequences

VARIABLE i

traceVars == <<vars, i>>

Match(o) ==
    /\ last.op = o.op
    /\ last.arg = o.arg
    /\ last.ok = o.ok
    /\ last.speed = o.speed
    /\ o.hasView => (View = o.view)

StepFor(o) ==
    CASE o.op = "fast"      -> SetFast(o.arg = "true")
      [] o.op = "ultrafast" -> SetUltra(o.arg = "true")
      [] o.op = "model"     -> SetModel(o.arg)
      [] o.op = "unknown"   -> SetUnknown
      [] o.op = "prompt"    -> Prompt
      [] o.op = "resume"    -> Resume
      [] OTHER              -> FALSE

ASSUME Len(TraceLog) >= 1 /\ TraceLog[1].op = "new"

TraceInit == /\ i = 1
             /\ Init
             /\ Match(TraceLog[1])

TraceNext == /\ i < Len(TraceLog)
             /\ \E o \in {TraceLog[i + 1]} :
                    /\ StepFor(o)
                    /\ Match(o)'
             /\ i' = i + 1

TraceSpec == TraceInit /\ [][TraceNext]_traceVars

NotDone == i < Len(TraceLog)
=============================================================================
