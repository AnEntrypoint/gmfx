--------------------------- MODULE ShellContract ---------------------------





















EXTENDS Naturals, Sequences, TLC

CONSTANTS
  Design,
  AdmissionReads,
  GuessAmbiguous,
  MaxCalls

ASSUME Design \in {"current", "proposed"}
ASSUME AdmissionReads \in {"normalized", "raw"}
ASSUME GuessAmbiguous \in BOOLEAN
ASSUME MaxCalls \in Nat /\ MaxCalls >= 1








Intents == {"run", "run_eq", "run_bash", "run_bash_tty", "type", "observe", "stop"}












Shapes == {"flat_new", "flat_action", "wrapped", "wrapped_string", "wrapped_broken",
           "invalid_json", "legacy_names", "with_irrelevant", "both_input", "both_bare"}

Encodable(i, s) ==
  CASE s = "both_input" -> i = "type"
    [] s = "both_bare"  -> i = "observe"
    [] OTHER            -> TRUE

Emits == {e \in [intent : Intents, shape : Shapes] : Encodable(e.intent, e.shape)}
NoCall == [intent |-> "none", shape |-> "none"]

Unreadable == {"wrapped_broken", "invalid_json"}
Ambiguous  == {"both_bare"}


ExactlyReadable(e) == e.shape \notin (Unreadable \cup Ambiguous)






Inferred(e) ==
  /\ Design = "current"
  /\ \/ e.shape = "legacy_names"
     \/ e.shape = "flat_new" /\ e.intent \in {"run", "run_eq", "run_bash"}

CurrentReadable(e) == e.shape \in {"flat_action", "wrapped"} \/ Inferred(e)






Accepted(e) ==
  IF Design = "current"
  THEN CurrentReadable(e) /\ e.intent # "run_bash"
  ELSE \/ ExactlyReadable(e)
       \/ (GuessAmbiguous /\ e.shape \in Ambiguous)


Decoded(e) == IF e.shape \in Ambiguous THEN "run" ELSE e.intent






RawReadable(e) == e.shape \in {"flat_action", "flat_new", "with_irrelevant"}
NormalizedView(e) ==
  IF Design = "current"
  THEN IF CurrentReadable(e) THEN e.intent ELSE "unreadable"
  ELSE IF Accepted(e) THEN Decoded(e) ELSE "unreadable"
AdmissionView(e) ==
  IF AdmissionReads = "normalized" THEN NormalizedView(e)
  ELSE IF RawReadable(e) THEN e.intent ELSE "unreadable"










HistoryEntry(e, acc) ==
  IF acc THEN "canonical"
  ELSE IF e.shape = "invalid_json" THEN "placeholder"
  ELSE IF Design = "current" /\ e.shape = "wrapped" THEN "unwrapped:wrapped"
  ELSE IF Inferred(e) THEN "inferred:" \o e.shape
  ELSE "as_sent:" \o e.shape



ZshOutcome == IF Design = "current" THEN "zsh_divergent" ELSE "bash_equivalent"

Outcome(e) ==
  IF ~Accepted(e) THEN "rejected"
  ELSE IF Decoded(e) = "run_eq" THEN ZshOutcome
  ELSE "ok"



Record(e) ==
  [e        |-> e,
   accepted |-> Accepted(e),
   decoded  |-> IF Accepted(e) THEN Decoded(e) ELSE "none",
   checked  |-> AdmissionView(e),
   history  |-> HistoryEntry(e, Accepted(e)),
   outcome  |-> Outcome(e)]

VARIABLES phase, pending, calls, lastRejected
vars == <<phase, pending, calls, lastRejected>>

Init ==
  /\ phase = "model"
  /\ pending = NoCall
  /\ calls = << >>
  /\ lastRejected = NoCall

ModelEmit ==
  /\ phase = "model"
  /\ Len(calls) < MaxCalls
  /\ \E e \in Emits : pending' = e
  /\ phase' = "pipeline"
  /\ UNCHANGED <<calls, lastRejected>>

ModelFinish ==
  /\ phase = "model"
  /\ phase' = "done"
  /\ UNCHANGED <<pending, calls, lastRejected>>

Process ==
  /\ phase = "pipeline"
  /\ LET e   == pending
         acc == Accepted(e)
         repeatedInvalid == ~acc /\ e = lastRejected
     IN /\ calls' = Append(calls, Record(e))
        /\ lastRejected' = IF acc THEN NoCall ELSE e
        /\ pending' = NoCall
        /\ phase' = IF repeatedInvalid \/ Len(calls) + 1 = MaxCalls THEN "done" ELSE "model"

Finished == phase = "done" /\ UNCHANGED vars

Next == ModelEmit \/ ModelFinish \/ Process \/ Finished

Spec == Init /\ [][Next]_vars /\ WF_vars(Process) /\ WF_vars(ModelFinish)

-----------------------------------------------------------------------------


TypeOK ==
  /\ phase \in {"model", "pipeline", "done"}
  /\ pending \in Emits \cup {NoCall}
  /\ lastRejected \in Emits \cup {NoCall}
  /\ Len(calls) <= MaxCalls

Calls == 1..Len(calls)


Exactness == \A k \in Calls : calls[k].accepted => calls[k].decoded = calls[k].e.intent


AdmissionConsistency == \A k \in Calls : calls[k].accepted => calls[k].checked = calls[k].decoded


Completeness == \A k \in Calls : ExactlyReadable(calls[k].e) => calls[k].accepted



HistoryFidelity ==
  \A k \in Calls :
    IF calls[k].accepted THEN calls[k].history = "canonical"
    ELSE IF calls[k].e.shape = "invalid_json" THEN calls[k].history = "placeholder"
    ELSE calls[k].history = "as_sent:" \o calls[k].e.shape



ZshForgiving ==
  \A k \in Calls : (calls[k].accepted /\ calls[k].decoded = "run_eq") => calls[k].outcome = "bash_equivalent"


GuardBound ==
  \A k \in 1..(Len(calls) - 1) :
    (~calls[k].accepted /\ ~calls[k + 1].accepted /\ calls[k].e = calls[k + 1].e)
      => (k + 1 = Len(calls) /\ phase = "done")


OneResultPerCall == phase # "pipeline" => pending = NoCall


Termination == <>(phase = "done")
=============================================================================
