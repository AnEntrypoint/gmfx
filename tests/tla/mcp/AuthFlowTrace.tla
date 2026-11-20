---- MODULE AuthFlowTrace ----














EXTENDS AuthFlow, TraceObs, Integers, Sequences, FiniteSets

VARIABLE i

Recs == {ObsTrace[n] : n \in 1..Len(ObsTrace)}
ObsIssuerSet == {r.data.issuer : r \in Recs} \cup {r.data.flow_issuer : r \in Recs} \cup {r.data.token_issuer : r \in Recs} \cup {1}
ObsMaxIssuer == CHOOSE m \in ObsIssuerSet : \A x \in ObsIssuerSet : x <= m
ObsIssuers == 1..ObsMaxIssuer
ObsNone == 0
ObsMasks == {r.data.scopes : r \in Recs} \cup {r.data.flow_scopes : r \in Recs} \cup {r.data.granted : r \in Recs} \cup {r.data.challenge : r \in Recs}
ObsMaxMask == CHOOSE m \in ObsMasks : \A x \in ObsMasks : x <= m


ObsScopes == {b \in 0..30 : 2^b <= ObsMaxMask}
ObsFlowSet == {r.data.flows : r \in Recs} \cup {1}
ObsMaxFlows == CHOOSE m \in ObsFlowSet : \A x \in ObsFlowSet : x <= m

Bits(m) == {b \in Scopes : (m \div (2^b)) % 2 = 1}
Regs(m) == {x \in Issuers : (m \div (2^(x - 1))) % 2 = 1}

Step(r) ==
    CASE r.event = "sign_in" -> SignIn
      [] r.event = "discovered" ->
            IF r.data.issuer = 0
            THEN \E m, p \in BOOLEAN : ~(m /\ p) /\ Discovered(m, p, Bits(r.data.scopes))
            ELSE asIssuer = r.data.issuer /\ Discovered(TRUE, TRUE, Bits(r.data.scopes))
      [] r.event = "registered" -> Registered(r.data.ok)
      [] r.event = "responded" -> Responded(r.data.state_ok, r.data.iss, r.data.advertised, r.data.err)
      [] r.event = "redeemed" -> Redeemed(r.data.ok)
      [] r.event = "cancel" -> Cancel
      [] r.event = "signed_out" -> SignOut
      [] r.event = "challenged" -> Challenged(Bits(r.data.scopes))
      [] r.event = "accepted" -> Accepted
      [] OTHER -> FALSE

Matches(r) ==
    /\ flow' = r.to
    /\ flows' = r.data.flows
    /\ flowIssuer' = r.data.flow_issuer
    /\ flowScopes' = Bits(r.data.flow_scopes)
    /\ regs' = Regs(r.data.regs)
    /\ tokenIssuer' = r.data.token_issuer
    /\ granted' = Bits(r.data.granted)
    /\ challenge' = Bits(r.data.challenge)
    /\ auths' = r.data.auths

TraceInit ==
    /\ Init
    /\ i = 0

TraceNext ==
    \/ /\ i < Len(ObsTrace)
       /\ LET r == ObsTrace[i + 1]
          IN /\ flow = r.from
             /\ IF r.data.ignored THEN ~ENABLED Step(r) /\ UNCHANGED vars ELSE Step(r)
             /\ Matches(r)
       /\ i' = i + 1
    \/ /\ Migrate
       /\ UNCHANGED i


NotDone == i < Len(ObsTrace)
====
