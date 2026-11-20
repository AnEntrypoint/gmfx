------------------------------ MODULE ImageStore ------------------------------




















































EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    N,
    Imgs,
    Old,
    Durable,
    MaxFaults,
    MaxCrashes,
    MaxLoss,
    StoreFirst,
    MarkOnlyStored,
    FailOnMissing,
    MaxRetries,
    DropRepeats,
    Window,
    LiveWindow,
    WindowAtOpen,
    CountInline,
    Tools,
    ToolStoreFirst

ASSUME N \in Nat /\ MaxFaults \in Nat /\ MaxCrashes \in Nat /\ MaxLoss \in Nat
ASSUME Old \in BOOLEAN /\ Durable \in BOOLEAN /\ StoreFirst \in BOOLEAN
ASSUME MarkOnlyStored \in BOOLEAN /\ FailOnMissing \in BOOLEAN
ASSUME MaxRetries \in Nat /\ DropRepeats \in BOOLEAN
ASSUME Window \in Nat \ {0} /\ LiveWindow \in BOOLEAN /\ WindowAtOpen \in BOOLEAN
ASSUME CountInline \in BOOLEAN
ASSUME Tools \in BOOLEAN /\ ToolStoreFirst \in BOOLEAN
ASSUME "o" \notin Imgs

Prompts == 1..N
None == "none"
OldImg == "o"
AllImgs == Imgs \cup {OldImg}
Phases == {"unmade", "putting", "put", "queued", "sent", "started", "ended", "failed", "lost"}
CoreStates == {"open", "down", "opening", "failed"}


ToolPhases == {"none", "called", "put", "refused", "given", "lost"}

VARIABLES
    made,
    img,
    ph,
    putting,
    store,
    lostImgs,
    saved,
    inputs,
    mem,
    up,
    staged,
    dirty,
    faults,
    crashes,
    retries,
    repeats,
    tool,
    tph,
    tputting,
    turnAt,
    act

tools == <<tool, tph, tputting, turnAt>>
vars == <<made, img, ph, putting, store, lostImgs, saved, inputs, mem, up, staged, dirty, faults, crashes, retries, repeats, tools, act>>

TypeOK ==
    /\ made \in 0..N
    /\ img \in [Prompts -> Imgs \cup {None}]
    /\ ph \in [Prompts -> Phases]
    /\ putting \subseteq Prompts
    /\ store \subseteq AllImgs
    /\ lostImgs \subseteq AllImgs
    /\ saved \in Seq([i : AllImgs, ref : BOOLEAN, dropped : BOOLEAN, named : BOOLEAN])
    /\ inputs \in Seq(Prompts)
    /\ mem \in Seq([i : AllImgs, stored : BOOLEAN, dropped : BOOLEAN, named : BOOLEAN])
    /\ up \in CoreStates
    /\ staged \subseteq AllImgs
    /\ dirty \in BOOLEAN
    /\ faults \in 0..MaxFaults
    /\ crashes \in 0..MaxCrashes
    /\ retries \in 0..MaxRetries
    /\ repeats \subseteq Imgs
    /\ tool \in [Prompts -> Imgs \cup {None}]
    /\ tph \in [Prompts -> ToolPhases]
    /\ tputting \subseteq Prompts
    /\ turnAt \in Nat

Init ==
    /\ made = 0
    /\ img = [p \in Prompts |-> None]
    /\ ph = [p \in Prompts |-> "unmade"]
    /\ putting = {}
    /\ store = {}
    /\ lostImgs = {}
    /\ saved = IF Old THEN << [i |-> OldImg, ref |-> FALSE, dropped |-> FALSE, named |-> TRUE] >> ELSE << >>
    /\ inputs = << >>
    /\ mem = << >>
    /\ up = "down"
    /\ staged = {}
    /\ dirty = FALSE
    /\ faults = 0
    /\ crashes = 0
    /\ retries = 0
    /\ repeats = {}
    /\ tool = [p \in Prompts |-> None]
    /\ tph = [p \in Prompts |-> "none"]
    /\ tputting = {}
    /\ turnAt = 0
    /\ act = << "Init" >>


Named == {saved[k].i : k \in {j \in 1..Len(saved) : saved[j].ref}}




WindowKeeps(s, k, n) ==
    IF CountInline THEN Cardinality(k..n) <= Window
    ELSE ~s[k].named \/ Cardinality({j \in k..n : s[j].named}) <= Window


OpenTurn == \E p \in Prompts : ph[p] = "started"
Counted == IF OpenTurn THEN turnAt - 1 ELSE Len(saved)


Needed == {saved[k].i : k \in {j \in 1..Len(saved) : saved[j].ref /\ (WindowKeeps(saved, j, Counted) \/ ~WindowAtOpen)}}


Windowed(s) ==
    IF ~LiveWindow THEN s
    ELSE [k \in 1..Len(s) |-> IF WindowKeeps(s, k, Len(s)) THEN s[k] ELSE [i |-> s[k].i, stored |-> FALSE, dropped |-> TRUE, named |-> TRUE]]
Images(s) == [k \in 1..Len(s) |-> s[k].i]
Running == \E p \in Prompts : ph[p] \in {"sent", "started"}
Queued(p) == \E k \in 1..Len(inputs) : inputs[k] = p

NextInput(p) ==
    /\ ph[p] = "queued"
    /\ \E k \in 1..Len(inputs) :
        /\ inputs[k] = p
        /\ \A j \in 1..(k - 1) : ph[inputs[j]] # "queued"

Set(f, p, v) == [f EXCEPT ![p] = v]

----------------------------------------------------------------------------



Make(p, i) ==
    /\ made + 1 = p
    /\ Durable \/ up = "open"
    /\ made' = p
    /\ img' = Set(img, p, i)
    /\ ph' = Set(ph, p, "putting")
    /\ putting' = putting \cup {p}
    /\ act' = << "Make", p, i >>
    /\ UNCHANGED <<store, lostImgs, saved, inputs, mem, up, staged, dirty, faults, crashes, retries, repeats, tools>>


PutLand(p) ==
    /\ p \in putting
    /\ store' = store \cup {img[p]}
    /\ putting' = putting \ {p}
    /\ ph' = IF ph[p] = "putting" THEN Set(ph, p, "put") ELSE ph
    /\ act' = << "PutLand", p >>
    /\ UNCHANGED <<made, img, lostImgs, saved, inputs, mem, up, staged, dirty, faults, crashes, retries, repeats, tools>>



PutFail(p) ==
    /\ p \in putting
    /\ faults < MaxFaults
    /\ faults' = faults + 1
    /\ putting' = putting \ {p}
    /\ ph' = IF ph[p] = "putting" THEN Set(ph, p, "failed") ELSE ph
    /\ act' = << "PutFail", p >>
    /\ UNCHANGED <<made, img, store, lostImgs, saved, inputs, mem, up, staged, dirty, crashes, retries, repeats, tools>>

----------------------------------------------------------------------------



Send(p) ==
    /\ ~Durable
    /\ up = "open"
    /\ ~Running
    /\ IF StoreFirst THEN ph[p] = "put" ELSE ph[p] \in {"putting", "put"}
    /\ ph' = Set(ph, p, "sent")
    /\ act' = << "Send", p >>
    /\ UNCHANGED <<made, img, putting, store, lostImgs, saved, inputs, mem, up, staged, dirty, faults, crashes, retries, repeats, tools>>


Enqueue(p) ==
    /\ Durable
    /\ ph[p] = "put"
    /\ inputs' = Append(inputs, p)
    /\ ph' = Set(ph, p, "queued")
    /\ act' = << "Enqueue", p >>
    /\ UNCHANGED <<made, img, putting, store, lostImgs, saved, mem, up, staged, dirty, faults, crashes, retries, repeats, tools>>



Take(p) ==
    /\ Durable
    /\ up = "open"
    /\ ~Running
    /\ NextInput(p)
    /\ ph' = Set(ph, p, IF img[p] \in store THEN "sent" ELSE "failed")
    /\ act' = << "Take", p >>
    /\ UNCHANGED <<made, img, putting, store, lostImgs, saved, inputs, mem, up, staged, dirty, faults, crashes, retries, repeats, tools>>


TurnStart(p) ==
    /\ ph[p] = "sent"
    /\ up = "open"
    /\ mem' = Append(mem, [i |-> img[p], stored |-> TRUE, dropped |-> FALSE, named |-> TRUE])
    /\ saved' = Append(saved, [i |-> img[p], ref |-> TRUE, dropped |-> FALSE, named |-> TRUE])
    /\ turnAt' = Len(saved) + 1
    /\ dirty' = TRUE
    /\ ph' = Set(ph, p, "started")
    /\ act' = << "TurnStart", p >>
    /\ UNCHANGED <<made, img, putting, store, lostImgs, inputs, up, staged, faults, crashes, retries, repeats, tool, tph, tputting>>



TurnEnd(p) ==
    /\ ph[p] = "started"
    /\ tph[p] \in {"none", "given", "lost"}
    /\ up = "open"
    /\ mem' = Windowed(mem)
    /\ ph' = Set(ph, p, "ended")
    /\ dirty' = TRUE
    /\ act' = << "TurnEnd", p >>
    /\ UNCHANGED <<made, img, putting, store, lostImgs, saved, inputs, up, staged, faults, crashes, retries, repeats, tools>>



Checkpoint ==
    /\ up = "open"
    /\ dirty
    /\ ~Running
    /\ saved' = [k \in 1..Len(mem) |->
                   [i |-> mem[k].i,
                    ref |-> ~mem[k].dropped /\ (mem[k].stored \/ ~MarkOnlyStored),
                    dropped |-> mem[k].dropped,
                    named |-> mem[k].named]]
    /\ dirty' = FALSE
    /\ act' = << "Checkpoint" >>
    /\ UNCHANGED <<made, img, ph, putting, store, lostImgs, inputs, mem, up, staged, faults, crashes, retries, repeats, tools>>




Crash ==
    /\ crashes < MaxCrashes
    /\ up \in {"open", "opening"}
    /\ crashes' = crashes + 1
    /\ up' = "down"
    /\ mem' = << >>
    /\ staged' = {}
    /\ putting' = {}
    /\ ph' = [p \in Prompts |->
                CASE ph[p] \in {"putting", "put"} -> "lost"
                  [] ph[p] = "sent" -> IF Durable THEN "queued" ELSE "lost"
                  [] OTHER -> ph[p]]
    /\ tputting' = {}
    /\ tph' = [p \in Prompts |-> IF tph[p] \in {"called", "put", "refused"} THEN "lost" ELSE tph[p]]
    /\ act' = << "Crash" >>
    /\ UNCHANGED <<made, img, store, lostImgs, saved, inputs, dirty, faults, retries, repeats, tool, turnAt>>



OpenBegin ==
    /\ up = "down"
    /\ up' = "opening"
    /\ staged' = {}
    /\ act' = << "OpenBegin" >>
    /\ UNCHANGED <<made, img, ph, putting, store, lostImgs, saved, inputs, mem, dirty, faults, crashes, retries, repeats, tools>>


Stage(i) ==
    /\ up = "opening"
    /\ i \in Needed \ staged
    /\ i \in store
    /\ staged' = staged \cup {i}
    /\ act' = << "Stage", i >>
    /\ UNCHANGED <<made, img, ph, putting, store, lostImgs, saved, inputs, mem, up, dirty, faults, crashes, retries, repeats, tools>>


OpenMissing ==
    /\ up = "opening"
    /\ FailOnMissing
    /\ \E i \in Needed \ staged : i \notin store
    /\ up' = "failed"
    /\ act' = << "OpenMissing" >>
    /\ UNCHANGED <<made, img, ph, putting, store, lostImgs, saved, inputs, mem, staged, dirty, faults, crashes, retries, repeats, tools>>





OpenOk ==
    /\ up = "opening"
    /\ \/ Needed \subseteq staged
       \/ ~FailOnMissing /\ \A i \in Needed \ staged : i \notin store
    /\ LET marked == [k \in 1..Len(saved) |->
                        [saved[k] EXCEPT !.dropped = @ \/ (saved[k].ref /\ saved[k].i \notin staged /\ ~WindowKeeps(saved, k, Counted))]]
           Kept(s) == SelectSeq(s, LAMBDA e : e.dropped \/ ~e.ref \/ e.i \in staged)
           AsCore(s) == [k \in 1..Len(s) |-> [i |-> s[k].i, stored |-> s[k].ref /\ ~s[k].dropped, dropped |-> s[k].dropped, named |-> s[k].named]]
       IN mem' = Windowed(AsCore(Kept(SubSeq(marked, 1, Counted)))) \o AsCore(Kept(SubSeq(marked, Counted + 1, Len(saved))))
    /\ up' = "open"
    /\ staged' = {}
    /\ act' = << "OpenOk" >>
    /\ UNCHANGED <<made, img, ph, putting, store, lostImgs, saved, inputs, dirty, faults, crashes, retries, repeats, tools>>




Retry(p, i) ==
    /\ Durable
    /\ retries < MaxRetries
    /\ Queued(p)
    /\ retries' = retries + 1
    /\ repeats' = IF DropRepeats THEN repeats ELSE repeats \cup {i}
    /\ act' = << "Retry", p, i >>
    /\ UNCHANGED <<made, img, ph, putting, store, lostImgs, saved, inputs, mem, up, staged, dirty, faults, crashes, tools>>



ToolCall(p, i) ==
    /\ Tools
    /\ up = "open"
    /\ ph[p] = "started"
    /\ tph[p] = "none"
    /\ tool' = Set(tool, p, i)
    /\ tph' = Set(tph, p, "called")
    /\ tputting' = tputting \cup {p}
    /\ act' = << "ToolCall", p, i >>
    /\ UNCHANGED <<made, img, ph, putting, store, lostImgs, saved, inputs, mem, up, staged, dirty, faults, crashes, retries, repeats, turnAt>>

ToolPutLand(p) ==
    /\ p \in tputting
    /\ store' = store \cup {tool[p]}
    /\ tputting' = tputting \ {p}
    /\ tph' = IF tph[p] = "called" THEN Set(tph, p, "put") ELSE tph
    /\ act' = << "ToolPutLand", p >>
    /\ UNCHANGED <<made, img, ph, putting, lostImgs, saved, inputs, mem, up, staged, dirty, faults, crashes, retries, repeats, tool, turnAt>>


ToolPutFail(p) ==
    /\ p \in tputting
    /\ faults < MaxFaults
    /\ faults' = faults + 1
    /\ tputting' = tputting \ {p}
    /\ tph' = IF tph[p] = "called" THEN Set(tph, p, "refused") ELSE tph
    /\ act' = << "ToolPutFail", p >>
    /\ UNCHANGED <<made, img, ph, putting, store, lostImgs, saved, inputs, mem, up, staged, dirty, crashes, retries, repeats, tool, turnAt>>



ToolResult(p) ==
    /\ up = "open"
    /\ ph[p] = "started"
    /\ tph[p] \in IF ToolStoreFirst THEN {"put", "refused"} ELSE {"called", "put", "refused"}
    /\ LET named == tph[p] # "refused"
       IN /\ mem' = Append(mem, [i |-> tool[p], stored |-> named, dropped |-> FALSE, named |-> named])
          /\ saved' = Append(saved, [i |-> tool[p], ref |-> named, dropped |-> FALSE, named |-> named])
    /\ tph' = Set(tph, p, "given")
    /\ dirty' = TRUE
    /\ act' = << "ToolResult", p >>
    /\ UNCHANGED <<made, img, ph, putting, store, lostImgs, inputs, up, staged, faults, crashes, retries, repeats, tool, tputting, turnAt>>


Lose(i) ==
    /\ Cardinality(lostImgs) < MaxLoss
    /\ i \in store
    /\ store' = store \ {i}
    /\ lostImgs' = lostImgs \cup {i}
    /\ act' = << "Lose", i >>
    /\ UNCHANGED <<made, img, ph, putting, saved, inputs, mem, up, staged, dirty, faults, crashes, retries, repeats, tools>>


Finished ==
    \/ up = "failed"
    \/ /\ up = "open"
       /\ made = N
       /\ putting = {}
       /\ tputting = {}
       /\ ~dirty
       /\ \A p \in Prompts : ph[p] \in {"ended", "failed", "lost"}

Done == Finished /\ UNCHANGED vars

Next ==
    \/ \E p \in Prompts, i \in Imgs : Make(p, i)
    \/ \E p \in Prompts : PutLand(p) \/ PutFail(p) \/ Send(p) \/ Enqueue(p) \/ Take(p) \/ TurnStart(p) \/ TurnEnd(p)
    \/ Checkpoint
    \/ Crash
    \/ OpenBegin
    \/ \E i \in AllImgs : Stage(i)
    \/ OpenMissing
    \/ OpenOk
    \/ \E i \in AllImgs : Lose(i)
    \/ \E p \in Prompts, i \in Imgs : Retry(p, i)
    \/ \E p \in Prompts, i \in Imgs : ToolCall(p, i)
    \/ \E p \in Prompts : ToolPutLand(p) \/ ToolPutFail(p) \/ ToolResult(p)
    \/ Done

Spec == Init /\ [][Next]_vars





Idle == \A p \in Prompts : ph[p] \notin {"putting", "put", "sent", "started"}
Auto ==
    \/ \E p \in Prompts : Send(p) \/ TurnStart(p) \/ ToolResult(p)
    \/ Checkpoint
    \/ \E i \in AllImgs : Stage(i)
    \/ OpenMissing
    \/ OpenOk
Quiet == ~ENABLED Auto
DriverStep ==
    \/ \E p \in Prompts, i \in Imgs : Idle /\ Make(p, i)
    \/ \E p \in Prompts : PutLand(p) \/ PutFail(p) \/ TurnEnd(p)
    \/ \E p \in Prompts, i \in Imgs : ToolCall(p, i)
    \/ \E p \in Prompts : ToolPutLand(p) \/ ToolPutFail(p)
    \/ Crash
    \/ OpenBegin
    \/ \E i \in AllImgs : Lose(i)
DriveSpec == Init /\ [][(Quiet /\ DriverStep) \/ Auto \/ Done]_vars

----------------------------------------------------------------------------




NoDanglingRef ==
    lostImgs = {} =>
        /\ Named \subseteq store
        /\ Durable => \A k \in 1..Len(inputs) : img[inputs[k]] \in store
        /\ repeats \subseteq store



OneCopy == \A k \in 1..Len(saved) : ~saved[k].ref /\ ~saved[k].dropped /\ saved[k].named => saved[k].i = OldImg


OpenExact == up = "open" => Images(mem) = Images(saved)


KnownStoredIsStored ==
    (lostImgs = {} /\ up = "open") => \A k \in 1..Len(mem) : mem[k].stored => mem[k].i \in store


FailsOnlyOnLoss == up = "failed" => lostImgs # {}


FailsOnlyOnLossInWindow ==
    up = "failed" =>
        \E k \in 1..Len(saved) : saved[k].ref /\ WindowKeeps(saved, k, Counted) /\ saved[k].i \in lostImgs



WindowBound ==
    (up = "open" /\ ~OpenTurn) => Cardinality({k \in 1..Len(mem) : ~mem[k].dropped}) <= Window




WindowHeld ==
    (up = "open" /\ ~OpenTurn) => \A k \in 1..Len(mem) : mem[k].dropped = ~WindowKeeps(mem, k, Len(mem))

=============================================================================
