---- MODULE HttpLegacy ----





























EXTENDS Naturals, FiniteSets

CONSTANTS
    Requests,
    MaxSessions,
    MaxEvents,
    MaxResumes

ASSUME MaxSessions \in Nat \ {0} /\ MaxEvents \in Nat /\ MaxResumes \in Nat

Phases == {"start", "initializing", "ready", "failed", "closed"}
States == {"idle", "posted", "broken", "resuming", "queued", "done"}
Outcomes == {"none", "result", "lost", "failed", "cancelled"}
Open == {"posted", "resuming"}
Pending == {"posted", "broken", "resuming", "queued"}

VARIABLES
    phase,
    sid,
    nextSid,
    seenEnd,
    req,
    nextEvent,
    listen,
    deleted,

    serverEnded,
    inits,
    sentClosed,
    refused405,
    listenAfter405,
    crossResume

session == <<phase, sid, nextSid, seenEnd>>
ghosts == <<serverEnded, inits, sentClosed, refused405, listenAfter405, crossResume>>
vars == <<session, req, nextEvent, listen, deleted, ghosts>>

Record == [st: States, sid: 0..MaxSessions, posts: Nat, after404: BOOLEAN,
           ev: BOOLEAN, resumes: 0..MaxResumes, outcome: Outcomes, stream: BOOLEAN]

Fresh == [st |-> "idle", sid |-> 0, posts |-> 0, after404 |-> FALSE,
          ev |-> FALSE, resumes |-> 0, outcome |-> "none", stream |-> FALSE]

Init ==
    /\ phase = "start"
    /\ sid = 0
    /\ nextSid = 1
    /\ seenEnd = {}
    /\ req = [r \in Requests |-> Fresh]
    /\ nextEvent = 1
    /\ listen = "off"
    /\ deleted = FALSE
    /\ serverEnded = {}
    /\ inits = 0
    /\ sentClosed = FALSE
    /\ refused405 = FALSE
    /\ listenAfter405 = FALSE
    /\ crossResume = FALSE


End(r, o) == [req[r] EXCEPT !.st = "done", !.outcome = o, !.stream = FALSE]


EndAll(o) == [r \in Requests |-> IF req[r].st \in Pending THEN End(r, o) ELSE req[r]]


Sent == sentClosed' = (sentClosed \/ phase = "closed")




SawEnd(s) ==
    /\ seenEnd' = seenEnd \cup {s}
    /\ IF s = sid /\ phase = "ready"
       THEN /\ phase' = "initializing"
            /\ inits' = inits + 1
       ELSE UNCHANGED <<phase, inits>>

---------------------------------------------------------------------------


Start ==
    /\ phase = "start"
    /\ phase' = "initializing"
    /\ inits' = inits + 1
    /\ Sent
    /\ UNCHANGED <<sid, nextSid, seenEnd, req, nextEvent, listen, deleted>>
    /\ UNCHANGED <<serverEnded, refused405, listenAfter405, crossResume>>



Post(r) ==
    /\ phase = "ready"
    /\ req[r].st \in {"idle", "queued"}
    /\ req' = [req EXCEPT ![r] = [@ EXCEPT !.st = "posted", !.sid = sid, !.posts = @ + 1,
                                           !.ev = FALSE, !.resumes = 0, !.stream = TRUE]]
    /\ Sent
    /\ UNCHANGED <<session, nextEvent, listen, deleted>>
    /\ UNCHANGED <<serverEnded, inits, refused405, listenAfter405, crossResume>>


Hold(r) ==
    /\ phase \in {"start", "initializing"}
    /\ req[r].st = "idle"
    /\ req' = [req EXCEPT ![r].st = "queued"]
    /\ UNCHANGED <<session, nextEvent, listen, deleted, ghosts>>


ResumeDue(r) ==
    /\ req[r].st = "broken"
    /\ IF phase = "ready" /\ req[r].sid = sid
       THEN /\ req' = [req EXCEPT ![r] = [@ EXCEPT !.st = "resuming", !.resumes = @ + 1, !.stream = TRUE]]
            /\ Sent
       ELSE /\ req' = [req EXCEPT ![r] = End(r, "lost")]
            /\ UNCHANGED sentClosed
    /\ crossResume' = (crossResume \/ (req'[r].st = "resuming" /\ req[r].sid # sid))
    /\ UNCHANGED <<session, nextEvent, listen, deleted>>
    /\ UNCHANGED <<serverEnded, inits, refused405, listenAfter405>>



Cancel(r) ==
    /\ req[r].st \in Pending
    /\ req' = [req EXCEPT ![r] = End(r, "cancelled")]
    /\ IF req[r].st # "queued" /\ phase = "ready" /\ req[r].sid = sid THEN Sent ELSE UNCHANGED sentClosed
    /\ UNCHANGED <<session, nextEvent, listen, deleted>>
    /\ UNCHANGED <<serverEnded, inits, refused405, listenAfter405, crossResume>>

ListenOpen ==
    /\ phase = "ready"
    /\ listen = "off"
    /\ listen' = "open"
    /\ listenAfter405' = (listenAfter405 \/ refused405)
    /\ Sent
    /\ UNCHANGED <<session, req, nextEvent, deleted>>
    /\ UNCHANGED <<serverEnded, inits, refused405, crossResume>>


ListenDue ==
    /\ listen = "waiting"
    /\ listen' = "off"
    /\ UNCHANGED <<session, req, nextEvent, deleted, ghosts>>

Close ==
    /\ phase \in {"start", "initializing", "ready"}
    /\ phase' = "closed"


    /\ deleted' = (phase = "ready" /\ sid # 0)
    /\ IF deleted' THEN Sent ELSE UNCHANGED sentClosed
    /\ req' = EndAll("cancelled")
    /\ listen' = IF listen = "none" THEN "none" ELSE "off"
    /\ UNCHANGED <<sid, nextSid, seenEnd, nextEvent>>
    /\ UNCHANGED <<serverEnded, inits, refused405, listenAfter405, crossResume>>

---------------------------------------------------------------------------




InitAnswered(withId) ==
    /\ phase = "initializing"
    /\ withId => nextSid <= MaxSessions
    /\ phase' = "ready"
    /\ sid' = IF withId THEN nextSid ELSE 0
    /\ nextSid' = IF withId THEN nextSid + 1 ELSE nextSid
    /\ listen' = IF listen = "none" THEN "none" ELSE "off"
    /\ UNCHANGED <<seenEnd, req, nextEvent, deleted, ghosts>>


InitFailed ==
    /\ phase = "initializing"
    /\ phase' = "failed"
    /\ req' = EndAll("failed")
    /\ listen' = IF listen = "none" THEN "none" ELSE "off"
    /\ UNCHANGED <<sid, nextSid, seenEnd, nextEvent, deleted, ghosts>>

EndSession ==
    /\ sid # 0
    /\ sid \notin serverEnded
    /\ serverEnded' = serverEnded \cup {sid}
    /\ UNCHANGED <<session, req, nextEvent, listen, deleted>>
    /\ UNCHANGED <<inits, sentClosed, refused405, listenAfter405, crossResume>>

Event(r) ==
    /\ req[r].st \in Open
    /\ nextEvent <= MaxEvents
    /\ req' = [req EXCEPT ![r].ev = TRUE]
    /\ nextEvent' = nextEvent + 1
    /\ UNCHANGED <<session, listen, deleted, ghosts>>

Answer(r) ==
    /\ req[r].st \in Open
    /\ req' = [req EXCEPT ![r] = End(r, "result")]
    /\ UNCHANGED <<session, nextEvent, listen, deleted, ghosts>>


Break(r) ==
    /\ req[r].st \in Open
    /\ req' = [req EXCEPT ![r] = IF req[r].ev /\ req[r].resumes < MaxResumes
                                 THEN [@ EXCEPT !.st = "broken", !.stream = FALSE]
                                 ELSE End(r, "lost")]
    /\ UNCHANGED <<session, nextEvent, listen, deleted, ghosts>>



TooLarge(r) ==
    /\ req[r].st \in Open
    /\ req' = [req EXCEPT ![r] = End(r, "lost")]
    /\ UNCHANGED <<session, nextEvent, listen, deleted, ghosts>>



Refused(r) ==
    /\ req[r].st \in Open
    /\ req' = [req EXCEPT ![r] = End(r, IF req[r].st = "posted" THEN "failed" ELSE "lost")]
    /\ UNCHANGED <<session, nextEvent, listen, deleted, ghosts>>



Expired(r) ==
    /\ req[r].st \in Open
    /\ req[r].sid \in serverEnded
    /\ req' = [req EXCEPT ![r] = IF req[r].st = "resuming" \/ req[r].after404
                                 THEN End(r, IF req[r].st = "resuming" THEN "lost" ELSE "failed")
                                 ELSE [@ EXCEPT !.st = "queued", !.after404 = TRUE, !.stream = FALSE]]
    /\ SawEnd(req[r].sid)
    /\ UNCHANGED <<sid, nextSid, nextEvent, listen, deleted>>
    /\ UNCHANGED <<serverEnded, sentClosed, refused405, listenAfter405, crossResume>>

ListenRefused ==
    /\ listen = "open"
    /\ listen' = "none"
    /\ refused405' = TRUE
    /\ UNCHANGED <<session, req, nextEvent, deleted>>
    /\ UNCHANGED <<serverEnded, inits, sentClosed, listenAfter405, crossResume>>

ListenBroke ==
    /\ listen = "open"
    /\ listen' = "waiting"
    /\ UNCHANGED <<session, req, nextEvent, deleted, ghosts>>

ListenExpired ==
    /\ listen = "open"
    /\ sid \in serverEnded
    /\ listen' = "off"
    /\ SawEnd(sid)
    /\ UNCHANGED <<sid, nextSid, req, nextEvent, deleted>>
    /\ UNCHANGED <<serverEnded, sentClosed, refused405, listenAfter405, crossResume>>

---------------------------------------------------------------------------

Client ==
    \/ Start
    \/ \E r \in Requests : Post(r) \/ Hold(r) \/ ResumeDue(r) \/ Cancel(r)
    \/ ListenOpen \/ ListenDue \/ Close

Server ==
    \/ InitAnswered(TRUE) \/ InitAnswered(FALSE) \/ InitFailed \/ EndSession
    \/ \E r \in Requests : Event(r) \/ Answer(r) \/ Break(r) \/ TooLarge(r) \/ Refused(r) \/ Expired(r)
    \/ ListenRefused \/ ListenBroke \/ ListenExpired

Next == Client \/ Server




Fairness ==
    /\ WF_vars(Start)
    /\ \A r \in Requests : WF_vars(Post(r)) /\ WF_vars(ResumeDue(r))
    /\ WF_vars(InitAnswered(TRUE) \/ InitAnswered(FALSE) \/ InitFailed)
    /\ \A r \in Requests : WF_vars(Answer(r) \/ Break(r) \/ TooLarge(r) \/ Refused(r) \/ Expired(r))

Spec == Init /\ [][Next]_vars /\ Fairness

---------------------------------------------------------------------------


TypeOK ==
    /\ phase \in Phases
    /\ sid \in 0..MaxSessions
    /\ nextSid \in 1..(MaxSessions + 1)
    /\ seenEnd \subseteq 1..MaxSessions
    /\ req \in [Requests -> Record]
    /\ nextEvent \in 1..(MaxEvents + 1)
    /\ listen \in {"off", "open", "waiting", "none"}
    /\ deleted \in BOOLEAN
    /\ serverEnded \subseteq 1..MaxSessions


OneInitPerEnd == inits <= 1 + Cardinality(seenEnd)
SeenOnlyEnded == seenEnd \subseteq serverEnded


NoReplayOfLostPost == \A r \in Requests :
    /\ req[r].posts <= 2
    /\ req[r].posts = 2 => req[r].after404



ResumeAfterEventId == \A r \in Requests :
    req[r].st \in {"broken", "resuming"} => req[r].ev /\ req[r].resumes <= MaxResumes
ResumeSameSession == ~crossResume



TooLargeEnds == [][\A r \in Requests : TooLarge(r) => req'[r].st = "done" /\ req'[r].outcome = "lost"]_vars


NothingAfterClose == ~sentClosed
DeleteOnlyLive == deleted => phase = "closed" /\ sid # 0 /\ sid \notin seenEnd


ListenRespects405 == ~listenAfter405


StreamOnlyWhileOpen == \A r \in Requests : req[r].stream => req[r].st \in Open



EveryRequestEnds == \A r \in Requests : (req[r].st # "idle") ~> (req[r].st = "done")
ExpiryReinits == \A s \in 1..MaxSessions :
    (s \in seenEnd) ~> (sid # s \/ phase \in {"failed", "closed"})
====
