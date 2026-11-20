#!/bin/sh





































set -eu

cd "$(dirname "$0")"

. ../lib/tlc.sh

tlc_verdicts "$@" <<'EOT'
MCPromptCache proposed - -deadlock
MCPromptCache current-holds - -deadlock
MCPromptCache current-cross-repo CrossRepoReuse -deadlock
MCPromptCache current-same-worktree SameWorktreeReuse -deadlock
MCPromptCache current-context ContextChangeKeepsStable -deadlock
MCPromptCache gap-history ContextChangeKeepsHistory -deadlock
MCPromptCache mutant-every-system Budget -deadlock
MCPromptCache mutant-fence-after-context SameWorktreeReuse -deadlock
MCPromptCache mutant-no-auto SessionReuse -deadlock
MCPromptCache mutant-absolute-paths WorktreeReuse -deadlock
MCPromptCache openai-proposed - -deadlock
MCPromptCache openai-current-holds - -deadlock
MCPromptCache openai-current-cross-repo CrossRepoReuse -deadlock
MCPromptCache openai-current-same-worktree SameWorktreeReuse -deadlock
MCPromptCache openai-current-context ContextChangeKeepsStable -deadlock
MCPromptCache openai-mutant-every-system Budget -deadlock
MCPromptCache openai-mutant-fence-after-context SameWorktreeReuse -deadlock
MCPromptCache openai-mutant-explicit-only SessionReuse -deadlock
MCPromptCache p6-proposed - -deadlock
MCPromptCache p6-proposed-sessions - -deadlock
MCPromptCache p6-openai-proposed - -deadlock
MCPromptCache p6-openai-proposed-sessions - -deadlock
MCPromptCache p6-current-switch MidSessionKeepsHistory -deadlock
MCPromptCache p6-current-deliver MidSessionKeepsHistory -deadlock
MCPromptCache p6-current-skill MidSessionKeepsHistory -deadlock
MCPromptCache p6-openai-current-deliver MidSessionKeepsHistory -deadlock
MCPromptCache p6-mutant-note-not-saved MidSessionKeepsHistory -deadlock
MCPromptCache p6-mutant-contract-late ContextChangeKeepsStable -deadlock
MCPromptCache p6-note-claude MidSessionKeepsHistory -deadlock
MCPromptCache p6-note-openai PreviousFullyReused -deadlock
MCPromptCache p6-implicit-proposed - -deadlock
MCPromptCache p6-implicit-context - -deadlock
MCPromptCache p6-implicit-current-deliver MidSessionKeepsHistory -deadlock
MCPromptCache p6-remind - -deadlock
MCPromptCache p6-openai-remind - -deadlock
MCPromptCache p6-mutant-remind-old-result PreviousFullyReused -deadlock
MCPromptCache p6-resume - -deadlock
MCPromptCache p6-openai-resume - -deadlock
MCPromptCache p6-mutant-stale-in-instructions MidSessionKeepsHistory -deadlock
MCPromptCache p6-overlay - -deadlock
MCPromptCache p6-openai-overlay - -deadlock
MCPromptCache p6-mutant-overlay-rebuilt MidSessionKeepsHistory -deadlock
MCPromptCache p6-mutant-overlay-not-saved MidSessionKeepsHistory -deadlock
EOT
