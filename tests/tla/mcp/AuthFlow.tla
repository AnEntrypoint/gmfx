---- MODULE AuthFlow ----





















EXTENDS Naturals

CONSTANTS
    Issuers,
    None,
    Scopes,
    MaxFlows,
    MaxAuthorizations

ASSUME MaxFlows \in Nat \ {0} /\ MaxAuthorizations \in Nat \ {0} /\ None \notin Issuers

Flows == {"idle", "discovering", "registering", "authorizing", "redeeming"}

VARIABLES
    flow,
    flows,
    flowIssuer,
    flowScopes,
    regs,
    tokenIssuer,
    granted,
    challenge,
    auths,

    asIssuer,
    migrated,

    known,
    validated,
    checked,
    asked,
    shown,
    redemptions,
    used

vars == <<flow, flows, flowIssuer, flowScopes, regs, tokenIssuer, granted, challenge, auths,
          asIssuer, migrated, known, validated, checked, asked, shown, redemptions, used>>

Init ==
    /\ flow = "idle"
    /\ flows = 0
    /\ flowIssuer = None
    /\ flowScopes = {}
    /\ regs = {}
    /\ tokenIssuer = None




    /\ granted \in SUBSET Scopes
    /\ challenge \in SUBSET Scopes
    /\ auths = 0
    /\ asIssuer \in Issuers
    /\ migrated = FALSE
    /\ known = None
    /\ validated = FALSE
    /\ checked = FALSE
    /\ asked = {}
    /\ shown = FALSE
    /\ redemptions = [f \in 1..MaxFlows |-> 0]
    /\ used = {}




SignIn ==
    /\ flow = "idle"
    /\ flows < MaxFlows
    /\ auths < MaxAuthorizations
    /\ flow' = "discovering"
    /\ flows' = flows + 1
    /\ flowScopes' = granted \cup challenge
    /\ asked' = granted \cup challenge
    /\ validated' = FALSE
    /\ checked' = FALSE
    /\ UNCHANGED <<flowIssuer, regs, tokenIssuer, granted, challenge, auths, asIssuer, migrated, known, shown, redemptions, used>>


Authorize(reg, i) ==
    /\ flow' = "authorizing"
    /\ auths' = auths + 1
    /\ used' = used \cup {<<reg, i>>}





Discovered(metaOk, pkceOk, defaults) ==
    /\ flow = "discovering"
    /\ LET usable == metaOk /\ pkceOk IN
       IF usable
       THEN /\ flowIssuer' = asIssuer
            /\ known' = asIssuer
            /\ validated' = (metaOk /\ pkceOk)
            /\ flowScopes' = IF flowScopes = {} THEN defaults ELSE flowScopes
            /\ IF tokenIssuer \notin {None, asIssuer}
               THEN tokenIssuer' = None /\ granted' = {}
               ELSE UNCHANGED <<tokenIssuer, granted>>
            /\ IF asIssuer \in regs
               THEN Authorize(asIssuer, asIssuer) /\ UNCHANGED regs
               ELSE flow' = "registering" /\ UNCHANGED <<regs, auths, used>>
       ELSE /\ flow' = "idle"
            /\ UNCHANGED <<flowIssuer, flowScopes, known, validated, tokenIssuer, granted, regs, auths, used>>
    /\ UNCHANGED <<flows, challenge, asIssuer, migrated, checked, asked, shown, redemptions>>


Registered(ok) ==
    /\ flow = "registering"
    /\ IF ok
       THEN regs' = regs \cup {flowIssuer} /\ Authorize(flowIssuer, flowIssuer)
       ELSE flow' = "idle" /\ UNCHANGED <<regs, auths, used>>
    /\ UNCHANGED <<flows, flowIssuer, flowScopes, tokenIssuer, granted, challenge, asIssuer, migrated, known, validated, checked, asked, shown, redemptions>>




Responded(stateOk, iss, advertised, err) ==
    /\ flow = "authorizing"
    /\ LET
           passes == stateOk /\ (iss = "match" \/ (iss = "none" /\ ~advertised))

           accept == stateOk /\ CASE iss = "match" -> TRUE
                                    [] iss = "wrong" -> FALSE
                                    [] iss = "none" -> ~advertised
           display == err /\ accept
       IN /\ checked' = passes
          /\ shown' = (shown \/ (display /\ ~passes))
          /\ flow' = IF accept /\ ~err THEN "redeeming" ELSE "idle"
    /\ UNCHANGED <<flows, flowIssuer, flowScopes, regs, tokenIssuer, granted, challenge, auths, asIssuer, migrated, known, validated, asked, redemptions, used>>


Redeemed(ok) ==
    /\ flow = "redeeming"
    /\ redemptions' = [redemptions EXCEPT ![flows] = @ + 1]
    /\ flow' = "idle"
    /\ IF ok
       THEN tokenIssuer' = flowIssuer /\ granted' = flowScopes
       ELSE UNCHANGED <<tokenIssuer, granted>>
    /\ UNCHANGED <<flows, flowIssuer, flowScopes, regs, challenge, auths, asIssuer, migrated, known, validated, checked, asked, shown, used>>


Cancel ==
    /\ flow # "idle"
    /\ flow' = "idle"
    /\ UNCHANGED <<flows, flowIssuer, flowScopes, regs, tokenIssuer, granted, challenge, auths, asIssuer, migrated, known, validated, checked, asked, shown, redemptions, used>>

SignOut ==
    /\ tokenIssuer' = None
    /\ granted' = {}
    /\ UNCHANGED <<flow, flows, flowIssuer, flowScopes, regs, challenge, auths, asIssuer, migrated, known, validated, checked, asked, shown, redemptions, used>>




Challenged(sc) ==
    /\ challenge' = sc
    /\ UNCHANGED <<flow, flows, flowIssuer, flowScopes, regs, tokenIssuer, granted, auths, asIssuer, migrated, known, validated, checked, asked, shown, redemptions, used>>


Accepted ==
    /\ tokenIssuer # None
    /\ auths' = 0
    /\ UNCHANGED <<flow, flows, flowIssuer, flowScopes, regs, tokenIssuer, granted, challenge, asIssuer, migrated, known, validated, checked, asked, shown, redemptions, used>>


Migrate ==
    /\ ~migrated
    /\ \E i \in Issuers \ {asIssuer} : asIssuer' = i
    /\ migrated' = TRUE
    /\ UNCHANGED <<flow, flows, flowIssuer, flowScopes, regs, tokenIssuer, granted, challenge, auths, known, validated, checked, asked, shown, redemptions, used>>

Progress ==
    \/ \E m, p \in BOOLEAN, d \in SUBSET Scopes : Discovered(m, p, d)
    \/ \E ok \in BOOLEAN : Registered(ok)
    \/ \E s, a, e \in BOOLEAN, i \in {"none", "match", "wrong"} : Responded(s, i, a, e)
    \/ \E ok \in BOOLEAN : Redeemed(ok)
    \/ Cancel

Next ==
    \/ SignIn
    \/ Progress
    \/ SignOut
    \/ \E sc \in SUBSET Scopes : Challenged(sc)
    \/ Accepted
    \/ Migrate


Spec == Init /\ [][Next]_vars /\ WF_vars(Progress)



TypeOK ==
    /\ flow \in Flows
    /\ flows \in 0..MaxFlows
    /\ regs \subseteq Issuers
    /\ tokenIssuer \in Issuers \cup {None}
    /\ granted \subseteq Scopes /\ challenge \subseteq Scopes /\ flowScopes \subseteq Scopes
    /\ auths \in Nat



MetaValidated == flow \in {"registering", "authorizing", "redeeming"} => validated



RedeemGuard == flow = "redeeming" => checked


VerifierOnce == \A f \in 1..MaxFlows : redemptions[f] <= 1


ErrSuppress == ~shown


CredIsolation == \A p \in used : p[1] = p[2]



TokenAudience == tokenIssuer \in {None, known}


ScopeUnion == flow # "idle" => asked \subseteq flowScopes


StepUpBound == auths <= MaxAuthorizations


EverySignInEnds == flow # "idle" ~> flow = "idle"
====
