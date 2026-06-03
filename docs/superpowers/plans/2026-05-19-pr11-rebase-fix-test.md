# PR #11 Rebase, Fix Review Issues, Add Tests, Finalize

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebase PR #11 (`fix/input-validation-issue-5`) onto master, fix the 4 review issues from the PR comment, add comprehensive test coverage for validation, and force-push the final result.

**Architecture:** The PR branch adds 3 validation functions (`validate_dates`, `validate_items_array`, `validate_item_fields`) to `api.php` and integrates them into the PATCH and copy handlers. Master has since added Docker test infrastructure (`docker-compose.test.yml`, `tests/test.sh`, `tests/seed.sql`). We rebase onto master, resolve the `api.php` merge conflict (keep PR's validated version), fix the copy handler date gap, remove dead code, add test cases, and push.

**Tech Stack:** PHP 8.0+, MySQL/MariaDB, Docker Compose, bash test harness (`tests/test.sh` with curl + jq)

---

## Pre-Task: Checkout and Rebase

**Files:**
- Modify: `api.php` (merge conflict resolution)

- [ ] **Step 1: Checkout PR branch locally**

```bash
git checkout -b fix/input-validation-issue-5 origin/fix/input-validation-issue-5
```

- [ ] **Step 2: Rebase onto master**

```bash
git rebase master
```

Expected: Merge conflict in `api.php`. The PR branch version has the validation functions; master has the baseline without validation. We keep the PR branch version of `api.php`.

- [ ] **Step 3: Resolve merge conflict in api.php**

During the rebase conflict, the correct resolution is to keep the PR branch's version of `api.php` (which has the validation functions). Use:

```bash
git checkout --theirs api.php
git add api.php
```

Wait — in a rebase, `--theirs` is actually the branch being rebased (our PR branch), and `--ours` is master. So:

```bash
git checkout --theirs api.php
git add api.php
git rebase --continue
```

- [ ] **Step 4: Verify api.php has validation functions after rebase**

```bash
grep -c 'function validate_dates' api.php
grep -c 'function validate_items_array' api.php
grep -c 'function validate_item_fields' api.php
grep -c 'function recompute_item' api.php
grep -c 'docker-compose.test.yml' .
```

Expected: all three validation functions present, `recompute_item` present, test infrastructure files exist.

- [ ] **Step 5: Verify test infrastructure exists**

```bash
ls tests/test.sh tests/seed.sql docker-compose.test.yml tests/nginx-entrypoint.sh tests/nginx-site.conf
```

Expected: all files present (from master).

- [ ] **Step 6: Run existing tests to verify baseline**

```bash
./tests/test.sh
```

Expected: All 17 existing tests pass.

- [ ] **Step 7: Commit the rebase result**

The rebase itself replays commits — no new commit needed unless we had to resolve conflicts. The conflict resolution is captured in the rebased commits.

---

### Task 1: Fix copy handler date validation gap

**Review issue:** When only `due_date` is provided in a copy request, `validate_dates($body)` validates format but cannot do the cross-field check because it doesn't know the default `$date`. For example, `POST /invoices/2/copy {"due_date": "2020-01-01"}` passes validation, but the effective `date` defaults to today, making `due_date < date`.

**Fix:** After computing the default dates (`$date = $body['date'] ?? date('Y-m-d')` and `$due_date = $body['due_date'] ?? date('Y-m-d', strtotime("$date +30 days"))`), add a cross-field check. This validates the actual values the new invoice will have.

**Files:**
- Modify: `api.php` (copy handler, ~line 470-480 in rebased version)

- [ ] **Step 1: Add cross-field date check after defaults are computed in copy handler**

In the copy handler, after these lines:

```php
$date     = $body['date']     ?? date('Y-m-d');
$due_date = $body['due_date'] ?? date('Y-m-d', strtotime("$date +30 days"));
```

Add:

```php
if ($due_date < $date) {
    err(400, 'due_date must be on or after date');
}
```

This is placed after `validate_dates($body)` (which validates format) and after the defaults are computed, so it checks the actual values that will be written to the new invoice. No extra DB query needed — we're validating against the computed defaults, which is correct for a copy operation creating a new invoice.

- [ ] **Step 2: Verify the fix manually by reading the relevant section**

Read `api.php` around the copy handler to confirm the placement is correct: `validate_dates($body)` for format validation, then defaults computed, then cross-field check.

- [ ] **Step 3: Run test suite to verify no regression**

```bash
./tests/test.sh
```

Expected: All 17 existing tests pass.

- [ ] **Step 4: Commit**

```bash
git add api.php
git commit -m "fix: add due_date>=date cross-check in copy handler after defaulting"
```

---

### Task 2: Remove dead year-0000 check

**Review issue:** `$dt->format('Y') === '0000'` in `validate_dates()` and `validate_item_fields()` never fires. PHP maps year 0000 to -1 in DateTime, and the round-trip check (`$dt->format('Y-m-d') !== $d`) already catches it. The check is misleading dead code.

**Files:**
- Modify: `api.php` (two locations)

- [ ] **Step 1: Remove year-0000 check from validate_dates()**

In `validate_dates()`, change:

```php
if (!$dt || $dt->format('Y-m-d') !== $d || $dt->format('Y') === '0000') {
```

to:

```php
if (!$dt || $dt->format('Y-m-d') !== $d) {
```

- [ ] **Step 2: Remove year-0000 check from validate_item_fields()**

In `validate_item_fields()`, in the `item_date` validation block, change:

```php
if (!$dt || $dt->format('Y-m-d') !== $v || $dt->format('Y') === '0000') {
```

to:

```php
if (!$dt || $dt->format('Y-m-d') !== $v) {
```

- [ ] **Step 3: Run test suite**

```bash
./tests/test.sh
```

Expected: All 17 existing tests pass.

- [ ] **Step 4: Commit**

```bash
git add api.php
git commit -m "fix: remove dead year-0000 check from date validation"
```

---

### Task 3: Add validation test cases to tests/test.sh

**Review issue:** Per AGENTS.md: "If you add or change an API endpoint, add a corresponding test case." The PR adds significant validation logic but no test cases.

**Files:**
- Modify: `tests/test.sh`

We add test functions for every validation rule. Each test sends an invalid request and asserts a 400 status code. We also add a few tests for valid inputs that should still work (to ensure validation doesn't reject valid data).

Seed data context (from `tests/seed.sql`):
- Invoice 1: draft, items 1 and 2 (item 1: qty=12, price=50; item 2: qty=1, price=75)
- Invoice 2: sent status, item 3 and 4
- Invoice 3: paid status, item 5
- Tax rates: id=1 (0%), id=2 (21%)
- No tax_rate_id beyond 2 exists

**Important:** Invoice 1 is a draft — it's the only invoice we can PATCH. Invoices 2 and 3 are non-draft and cannot be patched. For copy, we can copy any invoice.

**CRITICAL test ordering note:** The existing test `test_status_draft_to_sent` transitions invoice 1 from draft to sent. After that, any PATCH to invoice 1 returns 409 (not 400). PATCH validation tests MUST be placed **before** `test_status_draft_to_sent` in the runner. Copy validation tests can go anywhere since they create new invoices and don't modify invoice 1's status.

The correct runner order is:
1. Existing: `test_health` through `test_patch_draft_item`
2. **NEW: PATCH validation tests** (they only check for 400, don't modify invoice state)
3. **NEW: PATCH valid-input tests** (they modify item values but invoice stays draft)
4. Existing: `test_status_draft_to_sent` (transitions invoice 1 to sent)
5. Existing: `test_status_backwards`, `test_patch_non_draft`
6. **NEW: Copy validation tests** (copy from invoice 2, create new invoices)
7. Existing results output

- [ ] **Step 1: Add PATCH validation test functions**

Add these functions after `test_patch_non_draft()` and before the runner section in `tests/test.sh`:

```bash
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
    local body
    body=$(curl -sf -X PATCH -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d '{"items":[{"item_id":1,"tax_rate_id":0}]}' "$BASE_URL/api/v1/invoices/1")
    if echo "$body" | jq -e '.items[0].tax_rate_id == 0' > /dev/null 2>&1; then
        pass "PATCH valid tax_rate_id=0 accepted (no tax)"
    else
        fail "PATCH tax_rate_id=0 (body: $(echo "$body" | head -c 200))"
    fi
}
```

- [ ] **Step 2: Add test functions to the runner**

In `cmd_run()`, the test call order matters because `test_status_draft_to_sent` changes invoice 1 from draft to sent, after which all PATCH requests to invoice 1 return 409 (not 400). Insert the new test calls as follows:

**After `test_patch_draft_item` (line ~253) and before `test_status_draft_to_sent` (line ~255):**

```bash
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
```

**After `test_patch_non_draft` (line ~227) and before the results section:**

```bash
    test_copy_invalid_date
    test_copy_due_date_before_date
    test_copy_unknown_item_id
    test_copy_negative_quantity
    test_copy_items_not_array
```

- [ ] **Step 3: Run the full test suite**

```bash
./tests/test.sh
```

Expected: All tests pass (17 old + 19 new = 36 total).

- [ ] **Step 4: Commit**

```bash
git add tests/test.sh
git commit -m "test: add validation test cases for PATCH and copy endpoints"
```

---

### Task 4: Document breaking change in SPEC.md

**Review issue:** Items without `item_id` now return 400 instead of being silently skipped. Correct behavior, but should be documented.

**Files:**
- Modify: `SPEC.md` (Input Validation section, which was already added by the PR branch)

- [ ] **Step 1: Add breaking change note to SPEC.md Input Validation section**

In SPEC.md, in the "Structural validation" table, update the `item_id` row to note the breaking change:

Change:

```markdown
| `item_id` | Required for each item in PATCH; must belong to the target invoice |
```

to:

```markdown
| `item_id` | Required for each item in PATCH; must belong to the target invoice. **Breaking change:** previously items without `item_id` were silently skipped; now they return 400 |
```

- [ ] **Step 2: Run tests to verify nothing broke**

```bash
./tests/test.sh
```

Expected: All 36 tests pass.

- [ ] **Step 3: Commit**

```bash
git add SPEC.md
git commit -m "docs: document breaking change for missing item_id in PATCH"
```

---

### Task 5: Force-push rebased branch and finalize PR

- [ ] **Step 1: Force-push the rebased branch**

```bash
git push --force-with-lease origin fix/input-validation-issue-5
```

- [ ] **Step 2: Verify PR is updated**

```bash
gh pr view 11 --json commits,state,mergeable
```

Expected: PR shows updated commits, state=OPEN, mergeable.

- [ ] **Step 3: Post review response comment on PR**

Comment acknowledging all 4 review items were addressed.

---

## Self-Review Checklist

- [x] **Spec coverage:** Every review issue (4 items) has a corresponding task
- [x] **No placeholders:** All steps contain exact code, exact commands
- [x] **Type consistency:** All curl commands use consistent headers and URLs; test function names match between definition and runner call
- [x] **Test ordering:** PATCH validation tests placed before `test_status_draft_to_sent` (which transitions invoice 1 to sent); copy validation tests after `test_patch_non_draft`
- [x] **Breaking change documented:** Task 4 covers the breaking change note
- [x] **Copy handler date gap fixed:** Task 1 with cross-field check after defaults
- [x] **Dead code removed:** Task 2 with both locations
- [x] **Test coverage complete:** Task 3 with 19 new test functions covering all validation rules mentioned in the review