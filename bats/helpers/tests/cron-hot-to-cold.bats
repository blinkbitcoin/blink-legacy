#!/usr/bin/env bats

# Run the real cron test with service boundaries stubbed. No Docker or sleeps.
setup() {
  local repo_root
  repo_root="$(git rev-parse --show-toplevel)"
  export STUB_DIR="$BATS_TEST_TMPDIR/state"
  mkdir -p "$STUB_DIR"
  export STUB_CASE=delayed
  export STUB_TX_ID=1d080abd7c56054a8d48dc61cc8a8bae0d8bbb9af1cd09a79828714ae56665e7
  export STUB_PAYOUT_ID=dc1563fb-05a3-4390-8f21-0526cff17a8b
  export STUB_UNRELATED_TX_ID=7f3c1e0a9b2d4c6e8f0a1b3c5d7e9f1a2b4c6d8e0f1a3b5c7d9e1f2a4b6c8d0e
  fixture="$BATS_TEST_TMPDIR/cron.bats"
  awk -v helpers="$repo_root/bats/helpers" '
    /^load / { sub(/\.\.\/\.\.\/helpers/, helpers) }
    { print }
  ' "$repo_root/bats/core/api/cron.bats" > "$fixture"
  cat >> "$fixture" <<'STUBS'
setup_file() { :; }
teardown_file() { :; }
setup() {
  TILT_LOG_FILE="$STUB_DIR/trigger.log"
  printf '0\n' > "$STUB_DIR/tick"
  printf 'api-trigger │ {"sequence":1,"type":"payout_submitted","id":"old"}\n' > "$TILT_LOG_FILE"
  printf 'api-trigger │ {"sequence":2,"type":"payout_broadcast","id":"old"}\n' >> "$TILT_LOG_FILE"
}
read_value() { printf 'wallet\n'; }
exec_graphql() { :; }
graphql_output() { printf 'address\n'; }
wait_for_bria_hot_balance_at_least() { return 0; }
balance_for_check() { printf '0\n'; }
# A fail-closed boundary: an accidentally unstubbed service must not run.
docker() { echo 'Unexpected Docker call' >&2; return 1; }
run_cron() {
  touch "$STUB_DIR/cron"
  printf 'api-trigger │ {"sequence":3,"type":"payout_submitted","id":"unrelated"}\n' >> "$TILT_LOG_FILE"
  printf 'api-trigger │ {"sequence":4,"type":"payout_broadcast","id":"unrelated"}\n' >> "$TILT_LOG_FILE"
  printf 'api-trigger │ {"sequence":5,"type":"payout_submitted","id":"%s"}\n' "$STUB_PAYOUT_ID" >> "$TILT_LOG_FILE"
}
sleep() {
  local tick
  tick=$(< "$STUB_DIR/tick")
  tick=$((tick + 1))
  printf '%s\n' "$tick" > "$STUB_DIR/tick"
  if [[ "$tick" == 2 && "$STUB_CASE" != never_event ]]; then
    printf 'api-trigger │ {"sequence":6,"type":"payout_broadcast","id":"%s"}\n' "$STUB_PAYOUT_ID" >> "$TILT_LOG_FILE"
    touch "$STUB_DIR/broadcast"
  fi
}
bria_cli() {
  case "$*" in
    'import-xpub '*|'create-wallet '*) return 0 ;;
    'watch-events -o') printf '{"sequence":1}\n' ;;
    'get-payout -i old') echo 'Stale payout must not be selected' >&2; return 1 ;;
    # A broadcast payout with a valid txId that is not a cold-wallet rebalance.
    'get-payout -i unrelated')
      printf '{"payout":{"id":"unrelated","txId":"%s","metadata":{"galoy":{"rebalance":true}}}}\n' "$STUB_UNRELATED_TX_ID"
      ;;
    "get-payout -i $STUB_PAYOUT_ID")
      printf '{"payout":{"id":"%s","txId":"%s","metadata":{"galoy":{"rebalanceToColdWallet":true}}}}\n' "$STUB_PAYOUT_ID" "$STUB_TX_ID"
      ;;
    'wallet-balance -w cold')
      local amount=0
      if [[ -e "$STUB_DIR/cron" && ! -e "$STUB_DIR/second-mine" ]]; then amount=1003000000; fi
      printf '{"effectivePendingIncome":%s}\n' "$amount"
      ;;
    *) echo "Unexpected Bria call: $*" >&2; return 1 ;;
  esac
}
mongo_cli() {
  [[ "$*" == *"type:'to_cold_storage'"* && "$*" == *'pending:false'* && "$*" == *'voided:{$ne:true}'* ]] || {
    echo "Wrong ledger query: $*" >&2; return 1;
  }
  # A complete journal for the wrong payout must not release mining.
  [[ "$*" == *"hash:'$STUB_UNRELATED_TX_ID'"* ]] && { printf '3\n'; return 0; }
  [[ "$*" == *"hash:'$STUB_TX_ID'"* ]] || { echo "Wrong ledger hash: $*" >&2; return 1; }
  local tick
  tick=$(< "$STUB_DIR/tick")
  if [[ "$tick" -ge 4 && "$STUB_CASE" != never_journal ]]; then
    touch "$STUB_DIR/journal"
    printf '3\n'
  else
    # A partial journal is not enough.
    printf '2\n'
  fi
}
bitcoin_cli() {
  [[ -e "$STUB_DIR/cron" ]] || return 0
  printf '%s\n' "$*" >> "$STUB_DIR/mining"
  [[ -e "$STUB_DIR/broadcast" && -e "$STUB_DIR/journal" ]] || {
    echo 'Mined before the payout broadcast and ledger journal' >&2; return 1;
  }
  if [[ -e "$STUB_DIR/first-mine" ]]; then
    touch "$STUB_DIR/second-mine"
  else
    touch "$STUB_DIR/first-mine"
  fi
}
STUBS
}

@test "hot-to-cold: mining waits for this payout's broadcast and complete journal" {
  run bats --formatter tap --filter '^cron: rebalance hot to cold storage$' "$fixture"
  echo "$output"
  [[ "$status" == 0 ]] || return 1
  [[ "$(< "$STUB_DIR/tick")" == 4 ]] || return 1
  [[ "$(< "$STUB_DIR/mining")" == $'-generate 1\n-generate 1' ]]
}

@test "hot-to-cold: missing broadcast fails within the retry bound without mining" {
  export STUB_CASE=never_event
  run bats --formatter tap --filter '^cron: rebalance hot to cold storage$' "$fixture"
  echo "$output"
  [[ "$status" != 0 ]] || return 1
  [[ ! -e "$STUB_DIR/mining" ]] || return 1
  [[ "$(< "$STUB_DIR/tick")" == 30 ]]
}

@test "hot-to-cold: missing complete journal fails within the retry bound without mining" {
  export STUB_CASE=never_journal
  run bats --formatter tap --filter '^cron: rebalance hot to cold storage$' "$fixture"
  echo "$output"
  [[ "$status" != 0 ]] || return 1
  [[ ! -e "$STUB_DIR/mining" ]] || return 1
  [[ "$(< "$STUB_DIR/tick")" == 30 ]]
}
