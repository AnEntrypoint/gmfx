---------------------------- MODULE MCPromptCache ----------------------------


EXTENDS PromptCache

MCWorktrees == {"w1", "w2", "w3"}
MCRepoOf == [w \in MCWorktrees |-> IF w = "w3" THEN "r2" ELSE "r1"]
=============================================================================
