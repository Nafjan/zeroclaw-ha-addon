#!/usr/bin/env bash
set -euo pipefail

REPORT_FILE="${1:?provider contract report is required}"
EXPECTED_SHA256="${2:?provider contract report SHA256 is required}"
EXPECTED_COMMIT="${3:?candidate commit is required}"

[ -s "$REPORT_FILE" ] || {
    echo "provider contract report is missing or empty" >&2
    exit 1
}
printf '%s' "$EXPECTED_SHA256" | grep -Eq '^[0-9a-f]{64}$' || {
    echo "provider contract report SHA256 has an invalid format" >&2
    exit 1
}
printf '%s' "$EXPECTED_COMMIT" | grep -Eq '^[0-9a-f]{40}$' || {
    echo "provider contract report candidate commit has an invalid format" >&2
    exit 1
}
printf '%s  %s\n' "$EXPECTED_SHA256" "$REPORT_FILE" | sha256sum --check --status - || {
    echo "provider contract report SHA256 mismatch" >&2
    exit 1
}

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SUITE_FILE="${SCRIPT_DIR}/../../zeroclaw/tests/provider_profile_fallback_smoke.sh"
[ -f "$SUITE_FILE" ] && [ ! -L "$SUITE_FILE" ] || {
    echo "provider contract smoke suite is missing or not a regular file" >&2
    exit 1
}
SUITE_SHA256="$(sha256sum "$SUITE_FILE" | awk '{print $1}')"

jq -e \
    --arg expected_commit "$EXPECTED_COMMIT" \
    --arg suite_sha256 "$SUITE_SHA256" \
    '
    type == "object" and
    (.schema_version == 1) and
    (.status == "passed") and
    (.candidate_commit == $expected_commit) and
    (.tested_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
    (.suite.name == "provider_profile_fallback_smoke.sh") and
    (.suite.sha256 == $suite_sha256) and
    (.routes.primary.profile == "openrouter") and
    (.routes.primary.model == "~deepseek/deepseek-v4-flash-latest") and
    (.routes.primary.tier == "paid") and
    (.routes.complex.profile == "openrouter") and
    (.routes.complex.model == "openrouter/fusion") and
    (.routes.complex.tier == "paid") and
    (.routes.complex.preset == "general-budget") and
    (.routes.complex_auto.profile == "openrouter") and
    (.routes.complex_auto.model == "openrouter/auto") and
    (.routes.complex_auto.tier == "paid") and
    (.routes.complex_auto.cost_tier == "medium") and
    (.routes.complex_pro.profile == "openrouter") and
    (.routes.complex_pro.model == "deepseek/deepseek-v4-pro") and
    (.routes.complex_pro.tier == "paid") and
    (.routes.free_model.profile == "openrouter") and
    (.routes.free_model.model == "nvidia/nemotron-3.5-lightning:free") and
    (.routes.free_model.tier == "free") and
    (.routes.free_router.profile == "openrouter") and
    (.routes.free_router.model == "openrouter/free") and
    (.routes.free_router.tier == "free") and
    all([
        .classification.credit_exhausted_402,
        .classification.network_timeout,
        .classification.transient_5xx,
        .classification.credential_401_blocks_same_profile_fallback,
        .safety.free_route_no_tools_only,
        .safety.tool_capable_never_free,
        .accounting.reservation_recorded,
        .accounting.success_settlement_recorded,
        .accounting.failure_settlement_recorded,
        .accounting.budget_denied_before_upstream
    ][]; . == true) and
    (.accounting.ledger_schema == 1) and
    (.accounting.ledger_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
    ' "$REPORT_FILE" >/dev/null || {
    echo "provider contract report does not satisfy the required machine-checked contract" >&2
    exit 1
}

printf 'provider contract report verified: %s\n' "$REPORT_FILE"
