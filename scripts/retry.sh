#!/usr/bin/env bash
# Retries the Resource Manager Apply job that creates the Always Free ARM VM.
#
# Exit codes:
#   0  VM exists / was created, an Apply is already running, there was no capacity,
#      or OCI rate-limited the request (HTTP 429)
#   1  any other failure (bad credentials, wrong OCID, Terraform error, ...)
#
# Writes "vm_ready=true" to $GITHUB_OUTPUT once the VM exists.

set -euo pipefail

: "${OCI_TENANCY_OCID:?missing}"
: "${OCI_STACK_OCID:?missing}"

INSTANCE_NAME="${INSTANCE_NAME:-ashif-free-arm}"
ATTEMPTS="${ATTEMPTS:-2}"
ATTEMPT_GAP_SECONDS="${ATTEMPT_GAP_SECONDS:-60}"
JOB_MAX_WAIT_SECONDS="${JOB_MAX_WAIT_SECONDS:-480}"
POLL_SECONDS=15

OUTPUT_FILE="${GITHUB_OUTPUT:-/dev/null}"
SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-/dev/null}"
RATE_LIMIT_FLAG="${TMPDIR:-/tmp}/oci-rate-limited.$$"
RATE_LIMIT_EXIT=75

ist_now() { TZ=Asia/Kolkata date '+%d %b %Y, %I:%M %p IST'; }

log() { echo "[$(TZ=Asia/Kolkata date '+%H:%M:%S')] $*"; }

# Hide every OCID in text that is printed to the (possibly public) log.
redact() { sed -E 's/ocid1\.[A-Za-z0-9._-]+/ocid1.<redacted>/g'; }

summary() {
  {
    echo "### OCI ARM retry"
    echo ""
    echo "| | |"
    echo "|---|---|"
    echo "| Time | $(ist_now) |"
    echo "| Result | $1 |"
  } >> "$SUMMARY_FILE"
}

# Runs an oci command. On HTTP 429 (TooManyRequests) it records the fact and exits
# with RATE_LIMIT_EXIT, which the EXIT trap turns into a clean "retry next run".
# Any other error is printed (redacted) and returned as a failure.
oci_call() {
  local out err rc=0
  err=$(mktemp)
  out=$(oci "$@" 2>"$err") || rc=$?
  if (( rc == 0 )); then
    rm -f "$err"
    printf '%s' "$out"
    return 0
  fi
  if grep -qE 'TooManyRequests|"status": 429' "$err"; then
    rm -f "$err"
    touch "$RATE_LIMIT_FLAG"
    exit "$RATE_LIMIT_EXIT"
  fi
  redact <"$err" >&2
  rm -f "$err"
  return "$rc"
}

on_exit() {
  local rc=$?
  if [[ -f "$RATE_LIMIT_FLAG" ]]; then
    rm -f "$RATE_LIMIT_FLAG"
    log "Rate-limited by OCI (429 TooManyRequests) – will retry next run."
    summary "🚦 Rate-limited by OCI, will retry next run"
    exit 0
  fi
  exit "$rc"
}
trap on_exit EXIT

instance_count() {
  local out
  out=$(oci_call compute instance list \
    --compartment-id "$OCI_TENANCY_OCID" \
    --display-name "$INSTANCE_NAME" \
    --all) || return
  if [[ -z "$out" ]]; then
    echo 0
    return
  fi
  jq '[.data[] | select(."lifecycle-state" != "TERMINATED" and ."lifecycle-state" != "TERMINATING")] | length' <<<"$out"
}

active_job_count() {
  local out
  out=$(oci_call resource-manager job list --stack-id "$OCI_STACK_OCID" --all) || return
  if [[ -z "$out" ]]; then
    echo 0
    return
  fi
  jq '[.data[] | select(."lifecycle-state" == "ACCEPTED" or ."lifecycle-state" == "IN_PROGRESS")] | length' <<<"$out"
}

mark_ready() {
  echo "vm_ready=true" >> "$OUTPUT_FILE"
}

# Runs one Apply job and waits for it. Sets JOB_ID and JOB_STATE.
run_apply() {
  local waited=0
  JOB_ID=$(oci_call resource-manager job create-apply-job \
    --stack-id "$OCI_STACK_OCID" \
    --execution-plan-strategy AUTO_APPROVED \
    --query 'data.id' --raw-output) || return
  echo "::add-mask::$JOB_ID"

  while :; do
    JOB_STATE=$(oci_call resource-manager job get --job-id "$JOB_ID" \
      --query 'data."lifecycle-state"' --raw-output) || return
    case "$JOB_STATE" in
      SUCCEEDED|FAILED|CANCELED) return ;;
    esac
    if (( waited >= JOB_MAX_WAIT_SECONDS )); then
      JOB_STATE="TIMED_OUT"
      return
    fi
    sleep "$POLL_SECONDS"
    waited=$(( waited + POLL_SECONDS ))
  done
}

job_logs() {
  oci_call resource-manager job get-job-logs --job-id "$JOB_ID" --all \
    | jq -r '.data[]?.message // empty'
}

# 1. Already created?
count=$(instance_count)
if (( count > 0 )); then
  log "Instance already exists."
  summary "✅ Instance already exists"
  mark_ready
  exit 0
fi

# 2. Another Apply still running?
count=$(active_job_count)
if (( count > 0 )); then
  log "An Apply job is already running on the stack, skipping this run."
  summary "⏳ Apply already running, skipped"
  exit 0
fi

# 3. Try the Apply.
for (( attempt = 1; attempt <= ATTEMPTS; attempt++ )); do
  log "Apply attempt $attempt of $ATTEMPTS..."
  run_apply
  state="$JOB_STATE"
  log "Job finished with state: $state"

  case "$state" in
    SUCCEEDED)
      log "VM created."
      summary "🎉 VM created (attempt $attempt)"
      mark_ready
      exit 0
      ;;
    FAILED)
      logs=$(job_logs)
      if grep -qi "out of host capacity" <<<"$logs"; then
        if (( attempt < ATTEMPTS )); then
          log "No capacity – trying again in ${ATTEMPT_GAP_SECONDS}s."
          sleep "$ATTEMPT_GAP_SECONDS"
          continue
        fi
        log "No capacity – will retry next run."
        summary "🔁 No capacity, will retry next run"
        exit 0
      fi
      log "Apply failed for a reason other than capacity. Last log lines:"
      tail -n 40 <<<"$logs" | redact
      summary "❌ Apply failed (not a capacity error), check the run log"
      exit 1
      ;;
    TIMED_OUT)
      log "Job still running after ${JOB_MAX_WAIT_SECONDS}s, the next run will check on it."
      summary "⏳ Apply still running when this run stopped waiting"
      exit 0
      ;;
    *)
      log "Job ended in unexpected state: $state"
      summary "❌ Apply ended as $state"
      exit 1
      ;;
  esac
done
