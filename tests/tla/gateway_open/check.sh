#!/bin/sh























set -eu
cd "$(dirname "$0")"
. ../lib/tlc.sh
tlc_verdicts "$@" <<'VERDICTS'
OpenCancel open-cancel -
OpenCancel open-cancel-today temporal
OpenCancel open-cancel-mutation-no-close temporal
OpenCancel open-cancel-mutation-not-atomic temporal
OpenCancel open-cancel-mutation-no-stop-connect temporal
OpenCancel open-cancel-mutation-free-on-return NoFreeUnderJob
VERDICTS
