---------------------------- MODULE Resumption ----------------------------






















EXTENDS Naturals

CONSTANTS MaxCrashes, MaxTurns

VARIABLES
    proc,
    turn,
    turns,
    crashesInTurn,
    autoResumes,
    asked,
    notices,
    delivered,
    badResume,
    crashes,
    reply,
    ending,
    resolved,
    replySaved,
    askedAgain,
    earlyResult

vars == <<proc, turn, turns, crashesInTurn, autoResumes, asked, notices,
          delivered, badResume, crashes, reply, ending, resolved, replySaved,
          askedAgain, earlyResult>>

TypeOK ==
    /\ proc \in {"running", "down"}
    /\ turn \in {"none", "open", "committed", "user_stopped"}
    /\ turns \in 0..MaxTurns
    /\ crashesInTurn \in 0..MaxCrashes
    /\ autoResumes \in 0..MaxCrashes
    /\ asked \in BOOLEAN
    /\ notices \in 0..MaxCrashes
    /\ delivered \in 0..MaxCrashes
    /\ badResume \in BOOLEAN
    /\ crashes \in 0..MaxCrashes
    /\ reply \in {"none", "saved"}
    /\ ending \in BOOLEAN
    /\ resolved \in BOOLEAN
    /\ replySaved \in BOOLEAN
    /\ askedAgain \in BOOLEAN
    /\ earlyResult \in BOOLEAN

Init ==
    /\ proc = "running"
    /\ turn = "none"
    /\ turns = 0
    /\ crashesInTurn = 0
    /\ autoResumes = 0
    /\ asked = FALSE
    /\ notices = 0
    /\ delivered = 0
    /\ badResume = FALSE
    /\ crashes = 0
    /\ reply = "none"
    /\ ending = FALSE
    /\ resolved = FALSE
    /\ replySaved = FALSE
    /\ askedAgain = FALSE
    /\ earlyResult = FALSE

StartTurn ==
    /\ proc = "running"
    /\ turn \in {"none", "committed", "user_stopped"}
    /\ turns < MaxTurns
    /\ turn' = "open"
    /\ turns' = turns + 1
    /\ crashesInTurn' = 0
    /\ autoResumes' = 0
    /\ asked' = FALSE
    /\ notices' = 0
    /\ delivered' = 0
    /\ reply' = "none"
    /\ ending' = FALSE
    /\ resolved' = FALSE
    /\ replySaved' = FALSE
    /\ UNCHANGED <<proc, badResume, crashes, askedAgain, earlyResult>>



Request ==
    /\ proc = "running"
    /\ turn = "open"
    /\ ~ending
    /\ reply = "none"
    /\ askedAgain' = (askedAgain \/ replySaved)
    /\ UNCHANGED <<proc, turn, turns, crashesInTurn, autoResumes, asked,
                   notices, delivered, badResume, crashes, reply, ending,
                   resolved, replySaved, earlyResult>>


FinishReply ==
    /\ proc = "running"
    /\ turn = "open"
    /\ ~ending
    /\ reply = "none"
    /\ reply' = "saved"
    /\ replySaved' = TRUE
    /\ UNCHANGED <<proc, turn, turns, crashesInTurn, autoResumes, asked,
                   notices, delivered, badResume, crashes, ending, resolved,
                   askedAgain, earlyResult>>


SendEnd ==
    /\ proc = "running"
    /\ turn = "open"
    /\ reply = "saved"
    /\ ~ending
    /\ ending' = TRUE
    /\ UNCHANGED <<proc, turn, turns, crashesInTurn, autoResumes, asked,
                   notices, delivered, badResume, crashes, reply, resolved,
                   replySaved, askedAgain, earlyResult>>


EndLands ==
    /\ proc = "running"
    /\ ending
    /\ turn' = "committed"
    /\ ending' = FALSE
    /\ UNCHANGED <<proc, turns, crashesInTurn, autoResumes, asked, notices,
                   delivered, badResume, crashes, reply, resolved, replySaved,
                   askedAgain, earlyResult>>


ResolveResult ==
    /\ proc = "running"
    /\ ~resolved
    /\ turns > 0
    /\ turn = "committed"
    /\ resolved' = TRUE
    /\ earlyResult' = (earlyResult \/ turn # "committed")
    /\ UNCHANGED <<proc, turn, turns, crashesInTurn, autoResumes, asked,
                   notices, delivered, badResume, crashes, reply, ending,
                   replySaved, askedAgain>>


UserStop ==
    /\ proc = "running"
    /\ turn = "open"
    /\ ~ending
    /\ turn' = "user_stopped"
    /\ UNCHANGED <<proc, turns, crashesInTurn, autoResumes, asked, notices,
                   delivered, badResume, crashes, reply, ending, resolved,
                   replySaved, askedAgain, earlyResult>>



Crash ==
    /\ proc = "running"
    /\ crashes < MaxCrashes
    /\ proc' = "down"
    /\ crashes' = crashes + 1
    /\ crashesInTurn' = IF turn = "open" THEN crashesInTurn + 1 ELSE crashesInTurn
    /\ ending' = FALSE
    /\ UNCHANGED <<turn, turns, autoResumes, asked, notices, delivered,
                   badResume, reply, resolved, replySaved, askedAgain,
                   earlyResult>>


CleanExit ==
    /\ proc = "running"
    /\ turn # "open"
    /\ proc' = "down"
    /\ UNCHANGED <<turn, turns, crashesInTurn, autoResumes, asked, notices,
                   delivered, badResume, crashes, reply, ending, resolved,
                   replySaved, askedAgain, earlyResult>>




Reopen ==
    /\ proc = "down"
    /\ proc' = "running"
    /\ IF turn = "open"
       THEN /\ autoResumes' = autoResumes + 1
            /\ IF reply = "saved"
               THEN /\ delivered' = delivered + 1
                    /\ UNCHANGED notices
               ELSE /\ notices' = notices + 1
                    /\ UNCHANGED delivered
            /\ UNCHANGED asked
       ELSE UNCHANGED <<autoResumes, notices, delivered, asked>>
    /\ badResume' = (badResume \/ (autoResumes' > autoResumes /\ turn # "open"))
    /\ UNCHANGED <<turn, turns, crashesInTurn, crashes, reply, ending,
                   resolved, replySaved, askedAgain, earlyResult>>

Next ==
    \/ StartTurn
    \/ Request
    \/ FinishReply
    \/ SendEnd
    \/ EndLands
    \/ ResolveResult
    \/ UserStop
    \/ Crash
    \/ CleanExit
    \/ Reopen

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------



NeverAsks == ~asked



EveryCrashResumed == proc = "running" /\ turn = "open" => autoResumes = crashesInTurn



ModelToldEveryTime == notices + delivered = autoResumes


NeverResumeFinishedTurn == ~badResume


AutoResumeOnlyAfterCrash == autoResumes <= crashesInTurn


SavedAnswerNotRequested == ~askedAgain


ResultOnlyAfterDurableEnd == ~earlyResult



NoDelivery == delivered = 0

=============================================================================
