---------------------------- MODULE ShellOracle ----------------------------






EXTENDS ShellContract, FiniteSets

Line(e) ==
  LET r == Record(e) IN
  <<"FXT_PREDICT", e.intent, e.shape, r.accepted, r.decoded, r.history, r.outcome>>


ASSUME PrintT(<<"FXT_EMITS", Cardinality(Emits)>>)
ASSUME \A e \in Emits : PrintT(Line(e))

OracleNext == UNCHANGED vars
=============================================================================
