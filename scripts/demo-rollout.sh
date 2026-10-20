#!/usr/bin/env bash
# Exercise the canary: watch a good release promote, then watch a bad one abort.
#
# This is the script to run in front of someone. It proves the automated gate
# works, rather than asking them to take the README's word for it.
#
# Usage:
#   ./scripts/demo-rollout.sh             # interactive, prompts between phases
#   ./scripts/demo-rollout.sh --no-pause  # run straight through

set -euo pipefail

KUBECTL="${KUBECTL:-k3s kubectl}"
ROLLOUTS="${ROLLOUTS:-$KUBECTL argo rollouts}"
NAMESPACE="${NAMESPACE:-demo}"
APP="${APP:-demo-app}"
NO_PAUSE=0
[[ "${1:-}" == "--no-pause" ]] && NO_PAUSE=1

pause() {
  if [[ "$NO_PAUSE" -eq 0 ]]; then
    echo
    read -rp "  [enter to continue] " _
  fi
}

banner() {
  echo
  echo "=============================================================="
  echo "  $*"
  echo "=============================================================="
}

banner "1. Current state"
$ROLLOUTS get rollout "$APP" -n "$NAMESPACE"
echo
$KUBECTL get pods -n "$NAMESPACE" -L role

banner "2. Release version 2.0.0 (healthy) — expect promotion to 100%"
$KUBECTL set image rollout/"$APP" \
  "demo-app=ghcr.io/nivedmahendran/gitops-rollouts-demo:2.0.0" \
  -n "$NAMESPACE"

echo "Watching the rollout progress. It should pause at 20% and 50%"
echo "while the AnalysisRun queries Prometheus."
pause

# --watch blocks until the rollout settles, so this needs a timeout guard.
timeout 600 $ROLLOUTS watch rollout "$APP" -n "$NAMESPACE" --timeout 10m || {
  echo "watch ended (timeout or completion)"
}

echo
$ROLLOUTS get rollout "$APP" -n "$NAMESPACE"
echo
echo "AnalysisRuns recorded:"
$KUBECTL get analysisrun -n "$NAMESPACE" || true

banner "3. Release version 3.0.0 (broken) — expect automatic abort"
$KUBECTL set image rollout/"$APP" \
  "demo-app=ghcr.io/nivedmahendran/gitops-rollouts-demo:3.0.0" \
  -n "$NAMESPACE"

echo "Watching. Once the canary receives traffic it will start returning 500s,"
echo "the analysis will fail, and the rollout should abort and revert."
pause

timeout 600 $ROLLOUTS watch rollout "$APP" -n "$NAMESPACE" --timeout 10m || {
  echo "watch ended (likely aborted)"
}

echo
$ROLLOUTS get rollout "$APP" -n "$NAMESPACE"
echo
echo "Expected: status 'Degraded' or 'Paused' with reason 'AnalysisRunFailed',"
echo "and the image reverted. Confirm with:"
echo "  $KUBECTL get rollout $APP -n $NAMESPACE -o jsonpath='{.spec.template.spec.containers[0].image}'"

banner "4. Manual control (what you do at 3am)"
cat <<EOF
  Watch the live view:      $ROLLOUTS get rollout $APP -n $NAMESPACE --watch
  Promote past a pause:     $ROLLOUTS promote $APP -n $NAMESPACE
  Abort immediately:        $ROLLOUTS abort $APP -n $NAMESPACE
  Undo to last good:        $ROLLOUTS undo $APP -n $NAMESPACE
  Retry after a fix:        $ROLLOUTS retry $APP -n $NAMESPACE
EOF
