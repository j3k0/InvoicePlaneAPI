#!/usr/bin/env bash
set -euo pipefail

BASE_URL="http://localhost:10080"
API_KEY="test-api-key"
COMPOSE_FILE="docker-compose.test.yml"
PASS=0
FAIL=0

pass() {
    echo "[PASS] $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "[FAIL] $1"
    FAIL=$((FAIL + 1))
}

# --- Lifecycle ---

cmd_up() {
    echo "Starting test stack..."
    docker compose -f "$COMPOSE_FILE" up -d
    echo "Waiting for API to be healthy..."
    local attempts=0
    while [ $attempts -lt 30 ]; do
        if curl -sf "$BASE_URL/api/v1/health" > /dev/null 2>&1; then
            local db_status
            db_status=$(curl -sf "$BASE_URL/api/v1/health" | jq -r '.db' 2>/dev/null || echo "")
            if [ "$db_status" = "connected" ]; then
                echo "API is healthy (attempt $((attempts + 1)))."
                return 0
            fi
        fi
        attempts=$((attempts + 1))
        sleep 2
    done
    echo "ERROR: API did not become healthy within 60 seconds."
    docker compose -f "$COMPOSE_FILE" logs --tail=50
    return 1
}

cmd_down() {
    echo "Tearing down test stack..."
    docker compose -f "$COMPOSE_FILE" down -v
}

# --- Tests ---

test_health() {
    local body
    body=$(curl -sf "$BASE_URL/api/v1/health")
    if echo "$body" | jq -e '.status == "ok" and .db == "connected"' > /dev/null 2>&1; then
        pass "Health check returns ok and db connected"
    else
        fail "Health check (body: $(echo "$body" | head -c 200))"
    fi
}

test_auth_no_key() {
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/api/v1/invoices")
    if [ "$status" = "401" ]; then
        pass "Auth: no key returns 401"
    else
        fail "Auth: no key (expected 401, got $status)"
    fi
}

test_auth_wrong_key() {
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer wrong-key" "$BASE_URL/api/v1/invoices")
    if [ "$status" = "401" ]; then
        pass "Auth: wrong key returns 401"
    else
        fail "Auth: wrong key (expected 401, got $status)"
    fi
}

test_list_invoices_default() {
    local body
    body=$(curl -sf -H "Authorization: Bearer $API_KEY" "$BASE_URL/api/v1/invoices")
    if echo "$body" | jq -e '.total == 2' > /dev/null 2>&1; then
        pass "List invoices default returns 2 (excludes drafts)"
    else
        fail "List invoices default (body: $(echo "$body" | head -c 200))"
    fi
}

test_list_all_statuses() {
    local body
    body=$(curl -sf -H "Authorization: Bearer $API_KEY" "$BASE_URL/api/v1/invoices?status=all")
    if echo "$body" | jq -e '.total == 3' > /dev/null 2>&1; then
        pass "List invoices status=all returns 3"
    else
        fail "List all statuses (body: $(echo "$body" | head -c 200))"
    fi
}

test_filter_status_paid() {
    local body
    body=$(curl -sf -H "Authorization: Bearer $API_KEY" "$BASE_URL/api/v1/invoices?status=paid")
    if echo "$body" | jq -e '.total == 1' > /dev/null 2>&1; then
        pass "Filter by status=paid returns 1"
    else
        fail "Filter status=paid (body: $(echo "$body" | head -c 200))"
    fi
}

test_filter_client() {
    local body
    body=$(curl -sf -H "Authorization: Bearer $API_KEY" "$BASE_URL/api/v1/invoices?client_id=1")
    if echo "$body" | jq -e '.total == 1' > /dev/null 2>&1; then
        pass "Filter by client_id=1 returns 1 (Acme, non-draft)"
    else
        fail "Filter client_id=1 (body: $(echo "$body" | head -c 200))"
    fi
}

test_search() {
    local body
    body=$(curl -sf -H "Authorization: Bearer $API_KEY" "$BASE_URL/api/v1/invoices?q=Consulting")
    if echo "$body" | jq -e '.total >= 1' > /dev/null 2>&1; then
        pass "Search q=Consulting returns at least 1"
    else
        fail "Search q=Consulting (body: $(echo "$body" | head -c 200))"
    fi
}

test_sort_amount_desc() {
    local body
    body=$(curl -sf -H "Authorization: Bearer $API_KEY" "$BASE_URL/api/v1/invoices?order=amount_desc")
    if echo "$body" | jq -e '(.total == 1) or (.invoices[0].total >= .invoices[1].total)' > /dev/null 2>&1; then
        pass "Sort by amount_desc highest first"
    else
        fail "Sort amount_desc (body: $(echo "$body" | head -c 200))"
    fi
}

test_pagination() {
    local body
    body=$(curl -sf -H "Authorization: Bearer $API_KEY" "$BASE_URL/api/v1/invoices?limit=1&offset=1")
    if echo "$body" | jq -e '.invoices | length == 1' > /dev/null 2>&1; then
        pass "Pagination limit=1 offset=1 returns 1 result"
    else
        fail "Pagination (body: $(echo "$body" | head -c 200))"
    fi
}

test_get_single_invoice() {
    local body
    body=$(curl -sf -H "Authorization: Bearer $API_KEY" "$BASE_URL/api/v1/invoices/2")
    if echo "$body" | jq -e '.id == 2 and .client.name == "Goliath BV"' > /dev/null 2>&1; then
        pass "Get single invoice 2 returns full detail"
    else
        fail "Get single invoice 2 (body: $(echo "$body" | head -c 200))"
    fi
}

test_get_unknown_invoice() {
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $API_KEY" "$BASE_URL/api/v1/invoices/9999")
    if [ "$status" = "404" ]; then
        pass "Get unknown invoice returns 404"
    else
        fail "Get unknown invoice (expected 404, got $status)"
    fi
}

test_copy_invoice() {
    local body
    body=$(curl -sf -X POST -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" "$BASE_URL/api/v1/invoices/2/copy")
    if echo "$body" | jq -e '.status == "draft" and .id != null' > /dev/null 2>&1; then
        pass "Copy invoice 2 returns new draft"
    else
        fail "Copy invoice 2 (body: $(echo "$body" | head -c 200))"
    fi
}

test_patch_draft_date() {
    local body
    body=$(curl -sf -X PATCH -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d '{"date":"2026-06-01"}' "$BASE_URL/api/v1/invoices/1")
    if echo "$body" | jq -e '.date == "2026-06-01"' > /dev/null 2>&1; then
        pass "Patch draft invoice 1 date"
    else
        fail "Patch draft date (body: $(echo "$body" | head -c 200))"
    fi
}

test_patch_draft_item() {
    local body
    body=$(curl -sf -X PATCH -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d '{"items":[{"item_id":1,"quantity":6}]}' "$BASE_URL/api/v1/invoices/1")
    if echo "$body" | jq -e '.items[0].quantity == 6' > /dev/null 2>&1; then
        pass "Patch draft invoice 1 item quantity"
    else
        fail "Patch draft item quantity (body: $(echo "$body" | head -c 200))"
    fi
}

test_status_draft_to_sent() {
    local body
    body=$(curl -sf -X POST -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d '{"status":"sent"}' "$BASE_URL/api/v1/invoices/1/status")
    if echo "$body" | jq -e '.status == "sent"' > /dev/null 2>&1; then
        pass "Transition draft to sent"
    else
        fail "Transition draft to sent (body: $(echo "$body" | head -c 200))"
    fi
}

test_status_backwards() {
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d '{"status":"draft"}' "$BASE_URL/api/v1/invoices/2/status")
    if [ "$status" = "409" ]; then
        pass "Backwards transition returns 409"
    else
        fail "Backwards transition (expected 409, got $status)"
    fi
}

test_patch_non_draft() {
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d '{"date":"2026-01-01"}' "$BASE_URL/api/v1/invoices/2")
    if [ "$status" = "409" ]; then
        pass "Patch non-draft invoice returns 409"
    else
        fail "Patch non-draft (expected 409, got $status)"
    fi
}

# --- Runner ---

cmd_run() {
    echo ""
    echo "Running integration tests..."
    echo "============================"
    echo ""

    test_health
    test_auth_no_key
    test_auth_wrong_key
    test_list_invoices_default
    test_list_all_statuses
    test_filter_status_paid
    test_filter_client
    test_search
    test_sort_amount_desc
    test_pagination
    test_get_single_invoice
    test_get_unknown_invoice
    test_copy_invoice
    test_patch_draft_date
    test_patch_draft_item
    test_status_draft_to_sent
    test_status_backwards
    test_patch_non_draft

    echo ""
    echo "============================"
    echo "Results: $PASS passed, $FAIL failed"
    echo "============================"

    if [ "$FAIL" -gt 0 ]; then
        return 1
    fi
    return 0
}

# --- Main ---

case "${1:-}" in
    --up)
        cmd_up
        ;;
    --down)
        cmd_down
        ;;
    --run)
        cmd_run
        ;;
    "")
        cmd_up
        cmd_run
        cmd_down
        ;;
    *)
        echo "Usage: $0 [--up|--down|--run]"
        echo ""
        echo "  (default)  Start stack, run tests, tear down"
        echo "  --up       Start stack and wait for health"
        echo "  --down      Tear down stack and remove volumes"
        echo "  --run       Run tests against running stack"
        exit 1
        ;;
esac