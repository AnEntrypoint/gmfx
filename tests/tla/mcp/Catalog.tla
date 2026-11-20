---- MODULE Catalog ----





















EXTENDS Naturals

CONSTANTS
    MaxPages,
    MaxGen,
    MaxProcesses

ASSUME MaxPages \in Nat \ {0} /\ MaxGen \in Nat /\ MaxProcesses \in Nat \ {0}

VARIABLES
    era,
    process,
    gen,
    cache,
    cacheGen,
    cachedZero,
    cachedLapsed,
    listing,
    startGen,
    page,
    restarts,
    zeroTtl,
    lapsed,
    pending,
    waiting,
    answer,



    servedStale,
    extraFetch

vars == <<era, process, gen, cache, cacheGen, cachedZero, cachedLapsed, listing,
          startGen, page, restarts, zeroTtl, lapsed, pending, waiting, answer,
          servedStale, extraFetch>>

listingVars == <<listing, startGen, page, restarts, zeroTtl, lapsed, pending, waiting, answer>>

Init ==
    /\ era = "none"
    /\ process = 0
    /\ gen = 0
    /\ cache = "none"
    /\ cacheGen = 0
    /\ cachedZero = FALSE
    /\ cachedLapsed = FALSE
    /\ listing = "idle"
    /\ startGen = 0
    /\ page = 0
    /\ restarts = 0
    /\ zeroTtl = FALSE
    /\ lapsed = FALSE
    /\ pending = "none"
    /\ waiting = FALSE
    /\ answer = "none"
    /\ servedStale = FALSE
    /\ extraFetch = FALSE


Invalidated ==
    /\ gen' = gen + 1
    /\ cache' = IF cache = "fresh" THEN "stale" ELSE cache




ProcessStarted(e) ==
    /\ process < MaxProcesses
    /\ gen < MaxGen
    /\ listing = "idle"
    /\ process' = process + 1
    /\ era' = e
    /\ Invalidated
    /\ UNCHANGED <<cacheGen, cachedZero, cachedLapsed, listingVars, servedStale, extraFetch>>

StartListing ==
    /\ listing' = "fetching"
    /\ startGen' = gen
    /\ page' = 0
    /\ restarts' = 0
    /\ zeroTtl' = FALSE
    /\ lapsed' = FALSE
    /\ pending' = "first"
    /\ waiting' = TRUE
    /\ UNCHANGED answer


Need ==
    /\ era # "none"
    /\ IF listing = "fetching"
          THEN /\ waiting' = TRUE
               /\ UNCHANGED <<listing, startGen, page, restarts, zeroTtl, lapsed, pending, answer, servedStale, extraFetch>>
       ELSE IF cache = "fresh"
          THEN /\ servedStale' = (servedStale \/ cacheGen # gen)
               /\ UNCHANGED <<listingVars, extraFetch>>
       ELSE /\ StartListing
            /\ extraFetch' = (extraFetch \/ listing = "fetching")
            /\ UNCHANGED servedStale
    /\ UNCHANGED <<era, process, gen, cache, cacheGen, cachedZero, cachedLapsed>>





Finish(z, l) ==
    /\ listing' = "idle"
    /\ pending' = "none"
    /\ waiting' = FALSE
    /\ answer' = "list"
    /\ cache' = IF startGen = gen /\ (era = "legacy" \/ (~z /\ ~l)) THEN "fresh" ELSE "stale"
    /\ cacheGen' = startGen
    /\ cachedZero' = z
    /\ cachedLapsed' = l
    /\ UNCHANGED <<startGen, restarts>>





PageReceived(more, ttlZero, lapse) ==
    /\ pending # "none"
    /\ lapse => (era = "modern" /\ page > 0)
    /\ LET p == page + 1
           z == zeroTtl \/ ttlZero
           l == lapsed \/ lapse
       IN IF more /\ p < MaxPages
             THEN /\ page' = p /\ zeroTtl' = z /\ lapsed' = l /\ pending' = "next"
                  /\ UNCHANGED <<listing, startGen, restarts, waiting, answer, cache, cacheGen,
                                 cachedZero, cachedLapsed>>
          ELSE /\ page' = p /\ zeroTtl' = z /\ lapsed' = l
               /\ Finish(z, l)
    /\ UNCHANGED <<era, process, gen, servedStale, extraFetch>>




Failed ==
    /\ listing' = "idle"
    /\ pending' = "none"
    /\ waiting' = FALSE
    /\ answer' = IF cache = "none" THEN "failure" ELSE "lastGood"



InvalidCursor ==
    /\ pending = "next"
    /\ IF restarts = 0
          THEN /\ restarts' = 1
               /\ startGen' = gen
               /\ page' = 0
               /\ zeroTtl' = FALSE
               /\ lapsed' = FALSE
               /\ pending' = "first"
               /\ UNCHANGED <<listing, waiting, answer>>
          ELSE /\ Failed
               /\ UNCHANGED <<startGen, page, restarts, zeroTtl, lapsed>>
    /\ UNCHANGED <<era, process, gen, cache, cacheGen, cachedZero, cachedLapsed, servedStale, extraFetch>>





PageFailed ==
    /\ pending # "none"
    /\ Failed
    /\ UNCHANGED <<era, process, gen, cache, cacheGen, cachedZero, cachedLapsed, startGen,
                   page, restarts, zeroTtl, lapsed, servedStale, extraFetch>>



Invalidate ==
    /\ gen < MaxGen
    /\ Invalidated
    /\ UNCHANGED <<era, process, cacheGen, cachedZero, cachedLapsed, listingVars, servedStale, extraFetch>>


Expired ==
    /\ cache = "fresh"
    /\ era = "modern"
    /\ cache' = "stale"
    /\ UNCHANGED <<era, process, gen, cacheGen, cachedZero, cachedLapsed, listingVars, servedStale, extraFetch>>

Answer == (\E m, z, l \in BOOLEAN : PageReceived(m, z, l)) \/ InvalidCursor \/ PageFailed

Next ==
    \/ \E e \in {"modern", "legacy"} : ProcessStarted(e)
    \/ Need
    \/ Answer
    \/ Invalidate
    \/ Expired



Spec == Init /\ [][Next]_vars /\ WF_vars(Answer)

TypeOK ==
    /\ era \in {"none", "modern", "legacy"}
    /\ process \in 0..MaxProcesses
    /\ gen \in 0..MaxGen
    /\ cache \in {"none", "fresh", "stale"}
    /\ cacheGen \in 0..MaxGen
    /\ cachedZero \in BOOLEAN
    /\ cachedLapsed \in BOOLEAN
    /\ listing \in {"idle", "fetching"}
    /\ startGen \in 0..MaxGen
    /\ page \in 0..MaxPages
    /\ restarts \in 0..1
    /\ zeroTtl \in BOOLEAN
    /\ lapsed \in BOOLEAN
    /\ pending \in {"none", "first", "next"}
    /\ waiting \in BOOLEAN
    /\ answer \in {"none", "list", "lastGood", "failure"}
    /\ servedStale \in BOOLEAN
    /\ extraFetch \in BOOLEAN



CacheCurrent == cache = "fresh" => cacheGen = gen


NoStaleServe == ~servedStale


ZeroTtlNotCached == (cache = "fresh" /\ era = "modern") => ~cachedZero



LapsedNotCached == (cache = "fresh" /\ era = "modern") => ~cachedLapsed



LastGoodOnFailure == answer = "failure" => cache = "none"



FallbackRetries == (answer = "lastGood" /\ listing = "idle") => cache = "stale"


OneListing == ~extraFetch


PagesBounded == page <= MaxPages /\ (pending # "none" => page < MaxPages)


WaitingMeansListing == waiting <=> listing = "fetching"


EveryNeedAnswered == waiting ~> ~waiting
====
