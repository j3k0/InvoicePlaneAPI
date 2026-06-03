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
            local db_ok
            db_ok=$(curl -sf "$BASE_URL/api/v1/health" | jq -r '.ok' 2>/dev/null || echo "")
            if [ "$db_ok" = "true" ]; then
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
    if echo "$body" | jq -e '.ok == true' > /dev/null 2>&1; then
        pass "Health check returns ok true"
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
    body=$(curl -sf -X PATCH -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d '{"date":"2026-05-15","due_date":"2026-06-15"}' "$BASE_URL/api/v1/invoices/1")
    if echo "$body" | jq -e '.date == "2026-05-15"' > /dev/null 2>&1; then
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

test_status_draft_to_paid_skip() {
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d '{"status":"paid"}' "$BASE_URL/api/v1/invoices/1/status")
    if [ "$status" = "409" ]; then
        pass "Draft→paid skip returns 409"
    else
        fail "Draft→paid skip (expected 409, got $status)"
    fi
}

test_status_sent_to_paid_skip() {
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d '{"status":"paid"}' "$BASE_URL/api/v1/invoices/2/status")
    if [ "$status" = "409" ]; then
        pass "Sent→paid skip returns 409"
    else
        fail "Sent→paid skip (expected 409, got $status)"
    fi
}

test_status_viewed_to_paid_with_balance() {
    # First transition invoice 2 (sent) to viewed
    local body1
    body1=$(curl -sf -X POST -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d '{"status":"viewed"}' "$BASE_URL/api/v1/invoices/2/status")
    if ! echo "$body1" | jq -e '.status == "viewed"' > /dev/null 2>&1; then
        fail "Pre-condition: sent→viewed (body: $(echo "$body1" | head -c 200))"
        return
    fi
    pass "Transition sent to viewed"

    # Now try to mark as paid - should fail due to balance (1467.00)
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d '{"status":"paid"}' "$BASE_URL/api/v1/invoices/2/status")
    if [ "$status" = "409" ]; then
        pass "Viewed invoice with balance cannot be marked paid (409)"
    else
        fail "Viewed→paid with balance (expected 409, got $status)"
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

test_patch_negative_quantity() {
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d '{"items":[{"item_id":1,"quantity":-5}]}' "$BASE_URL/api/v1/invoices/1")
    if [ "$status" = "400" ]; then
        pass "PATCH negative quantity returns 400"
    else
        fail "PATCH negative quantity (expected 400, got $status)"
    fi
}

test_patch_negative_price() {
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d '{"items":[{"item_id":1,"price":-10}]}' "$BASE_URL/api/v1/invoices/1")
    if [ "$status" = "400" ]; then
        pass "PATCH negative price returns 400"
    else
        fail "PATCH negative price (expected 400, got $status)"
    fi
}

test_patch_scientific_notation() {
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d '{"items":[{"item_id":1,"quantity":"1e3"}]}' "$BASE_URL/api/v1/invoices/1")
    if [ "$status" = "400" ]; then
        pass "PATCH scientific notation quantity returns 400"
    else
        fail "PATCH scientific notation (expected 400, got $status)"
    fi
}

test_patch_null_price() {
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d '{"items":[{"item_id":1,"price":null}]}' "$BASE_URL/api/v1/invoices/1")
    if [ "$status" = "400" ]; then
        pass "PATCH null price returns 400"
    else
        fail "PATCH null price (expected 400, got $status)"
    fi
}

test_patch_boolean_quantity() {
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d '{"items":[{"item_id":1,"quantity":true}]}' "$BASE_URL/api/v1/invoices/1")
    if [ "$status" = "400" ]; then
        pass "PATCH boolean quantity returns 400"
    else
        fail "PATCH boolean quantity (expected 400, got $status)"
    fi
}

test_patch_invalid_tax_rate_id() {
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d '{"items":[{"item_id":1,"tax_rate_id":9999}]}' "$BASE_URL/api/v1/invoices/1")
    if [ "$status" = "400" ]; then
        pass "PATCH invalid tax_rate_id returns 400"
    else
        fail "PATCH invalid tax_rate_id (expected 400, got $status)"
    fi
}

test_patch_invalid_date() {
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d '{"date":"2026-13-45"}' "$BASE_URL/api/v1/invoices/1")
    if [ "$status" = "400" ]; then
        pass "PATCH invalid date returns 400"
    else
        fail "PATCH invalid date (expected 400, got $status)"
    fi
}

test_patch_due_date_before_date() {
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d '{"date":"2026-06-01","due_date":"2026-01-01"}' "$BASE_URL/api/v1/invoices/1")
    if [ "$status" = "400" ]; then
        pass "PATCH due_date before date returns 400"
    else
        fail "PATCH due_date before date (expected 400, got $status)"
    fi
}

test_patch_discount_exceeds_subtotal() {
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d '{"items":[{"item_id":1,"discount_amount":999999}]}' "$BASE_URL/api/v1/invoices/1")
    if [ "$status" = "400" ]; then
        pass "PATCH discount_amount>qty*price returns 400"
    else
        fail "PATCH discount_amount>qty*price (expected 400, got $status)"
    fi
}

test_patch_item_without_item_id() {
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d '{"items":[{"quantity":5}]}' "$BASE_URL/api/v1/invoices/1")
    if [ "$status" = "400" ]; then
        pass "PATCH item without item_id returns 400"
    else
        fail "PATCH item without item_id (expected 400, got $status)"
    fi
}

test_patch_wrong_item_id() {
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d '{"items":[{"item_id":5,"quantity":1}]}' "$BASE_URL/api/v1/invoices/1")
    if [ "$status" = "400" ]; then
        pass "PATCH item_id from wrong invoice returns 400"
    else
        fail "PATCH item_id from wrong invoice (expected 400, got $status)"
    fi
}

test_patch_items_not_array() {
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d '{"items":"not-array"}' "$BASE_URL/api/v1/invoices/1")
    if [ "$status" = "400" ]; then
        pass "PATCH items not array returns 400"
    else
        fail "PATCH items not array (expected 400, got $status)"
    fi
}

test_copy_invalid_date() {
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d '{"date":"not-a-date"}' "$BASE_URL/api/v1/invoices/2/copy")
    if [ "$status" = "400" ]; then
        pass "Copy with invalid date returns 400"
    else
        fail "Copy invalid date (expected 400, got $status)"
    fi
}

test_copy_due_date_before_date() {
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d '{"due_date":"2020-01-01"}' "$BASE_URL/api/v1/invoices/2/copy")
    if [ "$status" = "400" ]; then
        pass "Copy due_date before default date returns 400"
    else
        fail "Copy due_date before default date (expected 400, got $status)"
    fi
}

test_copy_unknown_item_id() {
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d '{"items":[{"item_id":9999,"quantity":1}]}' "$BASE_URL/api/v1/invoices/2/copy")
    if [ "$status" = "400" ]; then
        pass "Copy with unknown item_id returns 400"
    else
        fail "Copy unknown item_id (expected 400, got $status)"
    fi
}

test_copy_negative_quantity() {
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d '{"items":[{"item_id":3,"quantity":-5}]}' "$BASE_URL/api/v1/invoices/2/copy")
    if [ "$status" = "400" ]; then
        pass "Copy with negative quantity returns 400"
    else
        fail "Copy negative quantity (expected 400, got $status)"
    fi
}

test_copy_items_not_array() {
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d '{"items":"invalid"}' "$BASE_URL/api/v1/invoices/2/copy")
    if [ "$status" = "400" ]; then
        pass "Copy items not array returns 400"
    else
        fail "Copy items not array (expected 400, got $status)"
    fi
}

test_patch_valid_zero_quantity() {
    local body
    body=$(curl -sf -X PATCH -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d '{"items":[{"item_id":1,"quantity":0}]}' "$BASE_URL/api/v1/invoices/1")
    if echo "$body" | jq -e '.items[0].quantity == 0' > /dev/null 2>&1; then
        pass "PATCH valid zero quantity accepted"
    else
        fail "PATCH zero quantity (body: $(echo "$body" | head -c 200))"
    fi
}

test_patch_valid_tax_rate_id_zero() {
    local status body
    status=$(curl -s -o /tmp/tax_body.txt -w '%{http_code}' -X PATCH -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d '{"items":[{"item_id":2,"tax_rate_id":0}]}' "$BASE_URL/api/v1/invoices/1")
    body=$(cat /tmp/tax_body.txt)
    if [ "$status" = "200" ]; then
        pass "PATCH valid tax_rate_id=0 accepted (no tax)"
    else
        fail "PATCH tax_rate_id=0 (status=$status body: $(echo "$body" | head -c 200))"
    fi
}

test_env_secret_header_injection() {
    # Spoofing INVOICEPLANE_API_KEY via HTTP header must not bypass auth
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer wrong-key" \
        -H "INVOICEPLANE_API_KEY: attacker-key" \
        "$BASE_URL/api/v1/invoices")
    if [ "$status" = "401" ]; then
        pass "env_secret: HTTP header injection cannot bypass auth"
    else
        fail "env_secret bypass: expected 401, got $status"
    fi
}

test_env_secret_http_prefix_header_injection() {
    # PHP auto-populates HTTP headers into $_SERVER with HTTP_ prefix
    # e.g. HTTP_INVOICEPLANE_API_KEY -> $_SERVER['HTTP_INVOICEPLANE_API_KEY']
    # This verifies that env_secret() ignores these too
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer wrong-key" \
        -H "HTTP_INVOICEPLANE_API_KEY: attacker-key" \
        "$BASE_URL/api/v1/invoices")
    if [ "$status" = "401" ]; then
        pass "env_secret: HTTP_ prefix header injection cannot bypass auth"
    else
        fail "env_secret HTTP_ prefix: expected 401, got $status"
    fi
}

test_guest_url_present() {
    local body
    body=$(curl -sf -H "Authorization: Bearer $API_KEY" "$BASE_URL/api/v1/invoices/2")
    if echo "$body" | jq -e '.guest_url | startswith("http://localhost:10080/index.php/guest/view/invoice/")' > /dev/null 2>&1; then
        pass "guest_url present and uses configured INVOICEPLANE_BASE_URL"
    else
        fail "guest_url (body: $(echo "$body" | head -c 200))"
    fi
}

test_guest_url_host_header_injection() {
    # Malicious Host header must not affect guest_url
    local body
    body=$(curl -sf -H "Authorization: Bearer $API_KEY" -H "Host: evil.com" "$BASE_URL/api/v1/invoices/2")
    if echo "$body" | jq -e '.guest_url | startswith("http://localhost:10080/index.php/guest/view/invoice/")' > /dev/null 2>&1; then
        pass "guest_url immune to Host header injection"
    else
        fail "guest_url uses Host header or is missing (body: $(echo "$body" | head -c 200))"
    fi
}

test_body_too_large_content_length() {
    # Content-Length header > 1MB must be rejected immediately
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        -H "Content-Length: 2000000" \
        --data '{}' \
        "$BASE_URL/api/v1/invoices/1")
    if [ "$status" = "413" ]; then
        pass "Body size: Content-Length > 1MB returns 413"
    else
        fail "Body size: Content-Length > 1MB (expected 413, got $status)"
    fi
}

test_body_too_large_actual() {
    # Actual body > 1MB (spoofed or no Content-Length) must be rejected
    local status
    # Generate a payload > 1MB using python, send via curl
    local tmpfile
    tmpfile=$(mktemp)
    python3 -c "
import sys
sys.stdout.write('x' * 1500000)
" > "$tmpfile"
    status=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        --data-binary "@$tmpfile" \
        "$BASE_URL/api/v1/invoices/1")
    rm -f "$tmpfile"
    if [ "$status" = "413" ]; then
        pass "Body size: actual body > 1MB returns 413"
    else
        fail "Body size: actual body > 1MB (expected 413, got $status)"
    fi
}

test_security_headers() {
    local headers
    headers=$(curl -sf -I -H "Authorization: Bearer $API_KEY" "$BASE_URL/api/v1/invoices" 2>/dev/null || true)
    if echo "$headers" | grep -i 'Strict-Transport-Security:' > /dev/null 2>&1; then
        pass "Security headers: HSTS present"
    else
        fail "Security headers: HSTS missing"
    fi
    if echo "$headers" | grep -i 'Cache-Control:' > /dev/null 2>&1; then
        pass "Security headers: Cache-Control present"
    else
        fail "Security headers: Cache-Control missing"
    fi
    if echo "$headers" | grep -i 'Referrer-Policy:' > /dev/null 2>&1; then
        pass "Security headers: Referrer-Policy present"
    else
        fail "Security headers: Referrer-Policy missing"
    fi
}

test_405_wrong_method() {
    local status allow
    status=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $API_KEY" "$BASE_URL/api/v1/invoices")
    if [ "$status" = "405" ]; then
        pass "405: POST on list invoices returns 405"
    else
        fail "405: POST on list invoices (expected 405, got $status)"
    fi

    status=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer $API_KEY" "$BASE_URL/api/v1/invoices/1")
    if [ "$status" = "405" ]; then
        pass "405: DELETE on single invoice returns 405"
    else
        fail "405: DELETE on single invoice (expected 405, got $status)"
    fi

    allow=$(curl -s -o /dev/null -w '%{redirect_url}' -X OPTIONS -H "Authorization: Bearer $API_KEY" "$BASE_URL/api/v1/invoices/1" 2>/dev/null || true)
    status=$(curl -s -o /dev/null -w '%{http_code}' -X OPTIONS -H "Authorization: Bearer $API_KEY" "$BASE_URL/api/v1/invoices/1")
    if [ "$status" = "405" ]; then
        local allow_header
        allow_header=$(curl -s -D - -o /dev/null -X OPTIONS -H "Authorization: Bearer $API_KEY" "$BASE_URL/api/v1/invoices/1" 2>/dev/null | grep -i '^Allow:' | tr -d '\r')
        pass "405: OPTIONS returns 405 with Allow header ($allow_header)"
    else
        fail "405: OPTIONS on single invoice (expected 405, got $status)"
    fi
}

test_empty_patch_body() {
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d '{}' "$BASE_URL/api/v1/invoices/1")
    if [ "$status" = "400" ]; then
        pass "PATCH empty body returns 400"
    else
        fail "PATCH empty body (expected 400, got $status)"
    fi
}

test_content_type_validation() {
    local status

    # PATCH without Content-Type
    status=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH -H "Authorization: Bearer $API_KEY" -d '{"date":"2026-06-01"}' "$BASE_URL/api/v1/invoices/1")
    if [ "$status" = "415" ]; then
        pass "Content-Type: PATCH without application/json returns 415"
    else
        fail "Content-Type: PATCH without application/json (expected 415, got $status)"
    fi

    # POST status without Content-Type
    status=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $API_KEY" -d '{"status":"sent"}' "$BASE_URL/api/v1/invoices/1/status")
    if [ "$status" = "415" ]; then
        pass "Content-Type: POST status without application/json returns 415"
    else
        fail "Content-Type: POST status without application/json (expected 415, got $status)"
    fi
}

test_search_like_escaping() {
    local body
    body=$(curl -sf -H "Authorization: Bearer $API_KEY" "$BASE_URL/api/v1/invoices?q=%25&status=all")
    if echo "$body" | jq -e '.total == 0' > /dev/null 2>&1; then
        pass "Search: LIKE wildcard % is escaped (returns 0 matches)"
    else
        fail "Search: LIKE wildcard % (expected 0 matches, total=$(echo "$body" | jq '.total'))"
    fi
}

test_health_no_auth() {
    local body
    body=$(curl -sf "$BASE_URL/api/v1/health")
    if echo "$body" | jq -e '.ok == true' > /dev/null 2>&1; then
        pass "Health endpoint still accessible without auth"
    else
        fail "Health endpoint without auth (body: $(echo "$body" | head -c 200))"
    fi
}

# --- Runner ---

cmd_run() {
    echo ""
    echo "Running integration tests..."
    echo "============================"
    echo ""

    test_health
    test_health_no_auth
    test_security_headers
    test_auth_no_key
    test_auth_wrong_key
    test_env_secret_header_injection
    test_env_secret_http_prefix_header_injection
    test_guest_url_present
    test_guest_url_host_header_injection
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
    test_patch_negative_quantity
    test_patch_negative_price
    test_patch_scientific_notation
    test_patch_null_price
    test_patch_boolean_quantity
    test_patch_invalid_tax_rate_id
    test_patch_invalid_date
    test_patch_due_date_before_date
    test_patch_discount_exceeds_subtotal
    test_patch_item_without_item_id
    test_patch_wrong_item_id
    test_patch_items_not_array
    test_patch_valid_zero_quantity
    test_patch_valid_tax_rate_id_zero
    test_body_too_large_content_length
    test_body_too_large_actual
    test_status_draft_to_paid_skip
    test_status_sent_to_paid_skip
    test_status_viewed_to_paid_with_balance
    test_status_draft_to_sent
    test_status_backwards
    test_patch_non_draft
    test_405_wrong_method
    test_empty_patch_body
    test_content_type_validation
    test_search_like_escaping
    test_copy_invalid_date
    test_copy_due_date_before_date
    test_copy_unknown_item_id
    test_copy_negative_quantity
    test_copy_items_not_array

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