----------------------------- MODULE FuzzyMatch -----------------------------
























EXTENDS Naturals, Sequences, TLC

Tiers == {"none", "fuzzy", "words", "substring", "prefix", "exact"}


TierRank == [none |-> 0, fuzzy |-> 1, words |-> 2, substring |-> 3, prefix |-> 4, exact |-> 5]

UpperLetters == <<"A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
                  "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z">>
LowerLetters == <<"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m",
                  "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z">>
Digits == {"0", "1", "2", "3", "4", "5", "6", "7", "8", "9"}
HexDigits == Digits \cup {"a", "b", "c", "d", "e", "f"}


Separators == {"s+" \o hi \o lo : hi \in HexDigits, lo \in HexDigits}


Whitespace == {"s+20", "s+09", "s+0a", "s+0d"}

FoldMap == [c \in {UpperLetters[i] : i \in 1..26} |->
              LowerLetters[CHOOSE i \in 1..26 : UpperLetters[i] = c]]


Fold(c) == IF c \in DOMAIN FoldMap THEN FoldMap[c] ELSE c
Same(a, b) == Fold(a) = Fold(b)

IsSep(c) == c \in Separators
IsWordChar(c) == ~IsSep(c)
IsDigit(c) == c \in Digits

SameSeq(a, b) == Len(a) = Len(b) /\ \A i \in 1..Len(a) : Same(a[i], b[i])
StartsWith(s, p) == Len(p) <= Len(s) /\ SameSeq(SubSeq(s, 1, Len(p)), p)


RECURSIVE ContainsFrom(_, _, _)
ContainsFrom(s, n, i) ==
    IF i + Len(n) - 1 > Len(s) THEN FALSE
    ELSE IF SameSeq(SubSeq(s, i, i + Len(n) - 1), n) THEN TRUE
    ELSE ContainsFrom(s, n, i + 1)
Contains(s, n) == ContainsFrom(s, n, 1)


RECURSIVE TrimStart(_)
TrimStart(s) == IF s # <<>> /\ Head(s) \in Whitespace THEN TrimStart(Tail(s)) ELSE s
RECURSIVE TrimEnd(_)
TrimEnd(s) == IF s # <<>> /\ s[Len(s)] \in Whitespace THEN TrimEnd(SubSeq(s, 1, Len(s) - 1)) ELSE s
Trim(s) == TrimEnd(TrimStart(s))


RECURSIVE WordsFrom(_, _)
WordsFrom(s, current) ==
    IF s = <<>> THEN (IF current = <<>> THEN <<>> ELSE <<current>>)
    ELSE IF Head(s) \in Whitespace
         THEN (IF current = <<>> THEN WordsFrom(Tail(s), <<>>)
               ELSE <<current>> \o WordsFrom(Tail(s), <<>>))
         ELSE WordsFrom(Tail(s), Append(current, Head(s)))
Words(s) == WordsFrom(s, <<>>)

HasWordChar(s) == \E i \in 1..Len(s) : IsWordChar(s[i])


Compact(s) == SelectSeq(s, IsWordChar)


WordStart(f, i) ==
    /\ IsWordChar(f[i])
    /\ \/ i = 1
       \/ IsSep(f[i - 1])
       \/ IsDigit(f[i - 1]) # IsDigit(f[i])



RunIn(f, w) == Compact(w) # <<>> /\ Contains(Compact(f), Compact(w))





RECURSIVE AnchorFrom(_, _, _)
AnchorFrom(f, c, i) ==
    IF i > Len(f) THEN 0
    ELSE IF WordStart(f, i) /\ Same(f[i], c) THEN i
    ELSE AnchorFrom(f, c, i + 1)

RECURSIVE GreedyFrom(_, _, _)
GreedyFrom(f, w, i) ==
    IF w = <<>> THEN TRUE
    ELSE IF i > Len(f) THEN FALSE
    ELSE IF Same(f[i], Head(w)) THEN GreedyFrom(f, Tail(w), i + 1)
    ELSE GreedyFrom(f, w, i + 1)

FuzzyIn(f, w) ==
    LET cw == Compact(w)
    IN /\ cw # <<>>
       /\ LET anchor == AnchorFrom(f, Head(cw), 1)
          IN anchor > 0 /\ GreedyFrom(f, Tail(cw), anchor + 1)


WholeTier(fd, t) ==
    IF fd.kind = "name" /\ SameSeq(fd.text, t) THEN "exact"
    ELSE IF fd.kind = "name" /\ StartsWith(fd.text, t) THEN "prefix"
    ELSE IF Contains(fd.text, t) THEN "substring"
    ELSE "none"


WordTier(fd, w) ==
    IF fd.kind = "name"
    THEN (IF RunIn(fd.text, w) THEN "words"
          ELSE IF FuzzyIn(fd.text, w) THEN "fuzzy"
          ELSE "none")
    ELSE (IF Contains(fd.text, w) THEN "words" ELSE "none")

Range(s) == {s[i] : i \in DOMAIN s}
MaxTier(ts) == CHOOSE t \in Range(ts) : \A u \in Range(ts) : TierRank[t] >= TierRank[u]
MinTier(ts) == CHOOSE t \in Range(ts) : \A u \in Range(ts) : TierRank[t] <= TierRank[u]

FirstWith(ts, t) == CHOOSE i \in DOMAIN ts : ts[i] = t /\ \A j \in 1..(i - 1) : ts[j] # t
MinOf(S) == CHOOSE x \in S : \A y \in S : x <= y

NoMatch == [tier |-> "none", field |-> 0]



MaxFuzzyChars == 64




Match(q, fs) ==
    LET t == Trim(q)
    IN IF t = <<>> THEN [tier |-> "exact", field |-> 1]
       ELSE
         LET whole == [i \in 1..Len(fs) |-> WholeTier(fs[i], t)]
             best == MaxTier(whole)
         IN IF TierRank[best] >= TierRank["substring"]
            THEN [tier |-> best, field |-> FirstWith(whole, best)]
            ELSE IF Len(t) > MaxFuzzyChars THEN NoMatch
            ELSE
              LET ws == SelectSeq(Words(t), HasWordChar)
              IN IF ws = <<>> THEN NoMatch
                 ELSE
                   LET per == [j \in 1..Len(ws) |-> [i \in 1..Len(fs) |-> WordTier(fs[i], ws[j])]]
                       level == [j \in 1..Len(ws) |-> MaxTier(per[j])]
                   IN IF \E j \in 1..Len(ws) : level[j] = "none" THEN NoMatch
                      ELSE [tier |-> MinTier(level),
                            field |-> MinOf({FirstWith(per[j], level[j]) : j \in 1..Len(ws)})]

Matches(q, fs) == Match(q, fs).tier # "none"



Better(items, q, i, j) ==
    LET a == Match(q, items[i])
        b == Match(q, items[j])
    IN \/ TierRank[a.tier] > TierRank[b.tier]
       \/ /\ TierRank[a.tier] = TierRank[b.tier]
          /\ \/ a.field < b.field
             \/ a.field = b.field /\ i < j

MatchingIndexes(items, q) ==
    SelectSeq([i \in 1..Len(items) |-> i], LAMBDA i : Matches(q, items[i]))



AsTyped(items, q, i) == TierRank[Match(q, items[i]).tier] >= TierRank["substring"]
FilteredIndexes(items, q) ==
    IF \E i \in 1..Len(items) : AsTyped(items, q, i)
    THEN SelectSeq([i \in 1..Len(items) |-> i], LAMBDA i : AsTyped(items, q, i))
    ELSE MatchingIndexes(items, q)

Listing(items, q, mode) ==
    IF mode = "filtered" THEN FilteredIndexes(items, q)
    ELSE SortSeq(MatchingIndexes(items, q), LAMBDA i, j : Better(items, q, i, j))

=============================================================================
