# Input Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add comprehensive input validation to PATCH and copy endpoints to prevent negative values, invalid dates, extreme numbers, null payloads, and invalid tax rate IDs.

**Architecture:** Two small validator functions (`validate_dates` and `validate_item_fields`) added to the existing single-file `api.php`, called before mutation logic in both PATCH and copy handlers. No new dependencies. No new files.

**Tech Stack:** PHP 7.2+ (strict types), MySQL/PDO, existing codebase patterns.

---

### Task 1: Add `validate_dates()` function

**Files:**
- Modify: `api.php:58-70` (after `tax_rate()`, before `recompute_item()`)

- [ ] **Step 1: Write the `validate_dates` function**

Insert after `tax_rate()` function (line 70), before `recompute_item()` (line 72):

```php
function validate_dates(array $body, ?PDO $db = null, ?int $invoice_id = null): void {
    $date = $body['date'] ?? null;
    $due_date = $body['due_date'] ?? null;

    $validate_date_field = function (?string $d, string $label): string {
        if ($d === null) return '';
        $dt = DateTimeImmutable::createFromFormat('Y-m-d', $d);
        if (!$dt || $dt->format('Y-m-d') !== $d || $dt->format('Y') === '0000') {
            err(400, "$label must be a valid date in Y-m-d format");
        }
        return $d;
    };

    $date = $validate_date_field($date, 'date') ?: null;
    $due_date = $validate_date_field($due_date, 'due_date') ?: null;

    if ($due_date !== null || $date !== null) {
        if ($db !== null && $invoice_id !== null) {
            if ($date === null || $due_date === null) {
                $s = $db->prepare('SELECT invoice_date_created, invoice_date_due FROM ip_invoices WHERE invoice_id = ?');
                $s->execute([$invoice_id]);
                $row = $s->fetch();
                if (!$row) err(404, 'invoice not found');
                if ($date === null) $date = $row['invoice_date_created'];
                if ($due_date === null) $due_date = $row['invoice_date_due'];
            }
        }
        if ($date !== null && $due_date !== null && $due_date < $date) {
            err(400, 'due_date must be on or after date');
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add api.php
git commit -m "feat: add validate_dates() function for date input validation"
```

---

### Task 2: Add `validate_item_fields()` function

**Files:**
- Modify: `api.php` (after `validate_dates()`, before `recompute_item()`)

- [ ] **Step 1: Write the `validate_item_fields` function**

Insert after `validate_dates()`, before `recompute_item()`:

```php
function validate_item_fields(array $item, ?PDO $db = null, ?int $invoice_id = null, ?array $db_row = null): void {
    $numeric_fields = [
        'quantity'         => ['max' => 999999],
        'price'            => ['max' => 999999999],
        'discount_amount'  => ['max' => 999999999],
    ];

    foreach ($numeric_fields as $field => $opts) {
        if (!array_key_exists($field, $item)) continue;
        $v = $item[$field];
        if (is_bool($v) || $v === null) {
            err(400, "$field must be a non-negative number");
        }
        if (!is_string($v) && !is_int($v) && !is_float($v)) {
            err(400, "$field must be a non-negative number");
        }
        $sv = (string) $v;
        if (!preg_match('/^\d+(\.\d+)?$/', $sv)) {
            err(400, "$field must be a non-negative number");
        }
        $fv = (float) $v;
        if ($fv < 0) {
            err(400, "$field must be a non-negative number");
        }
        if ($fv > $opts['max']) {
            err(400, "$field must not exceed {$opts['max']}");
        }
    }

    if (array_key_exists('discount_amount', $item)) {
        $qty = (float) ($item['quantity'] ?? ($db_row['item_quantity'] ?? 0));
        $price = (float) ($item['price'] ?? ($db_row['item_price'] ?? 0));
        $disc = (float) $item['discount_amount'];
        if ($disc > 0 && $qty > 0 && $price > 0 && $disc > $qty * $price) {
            err(400, 'discount_amount must not exceed quantity * price');
        }
    }

    if (array_key_exists('order', $item)) {
        $v = $item['order'];
        if (!is_int($v) && !(is_string($v) && ctype_digit($v))) {
            err(400, 'order must be an integer between 0 and 999');
        }
        if ((int) $v < 0 || (int) $v > 999) {
            err(400, 'order must be an integer between 0 and 999');
        }
    }

    if (array_key_exists('tax_rate_id', $item) && $item['tax_rate_id'] !== null) {
        $v = $item['tax_rate_id'];
        if (is_bool($v)) {
            err(400, 'tax_rate_id must be a positive integer');
        }
        if (!is_int($v) && !(is_string($v) && ctype_digit($v))) {
            err(400, 'tax_rate_id must be a positive integer');
        }
        $id = (int) $v;
        if ($id < 0) {
            err(400, 'tax_rate_id must be a positive integer');
        }
        if ($id > 0) {
            static $seen = [];
            if (!isset($seen[$id])) {
                $s = ($db ?? db())->prepare('SELECT 1 FROM ip_tax_rates WHERE tax_rate_id = ?');
                $s->execute([$id]);
                $seen[$id] = (bool) $s->fetch();
            }
            if (!$seen[$id]) {
                err(400, 'invalid tax_rate_id');
            }
        }
    }

    if (array_key_exists('item_date', $item)) {
        $v = $item['item_date'];
        if ($v !== null) {
            $dt = DateTimeImmutable::createFromFormat('Y-m-d', $v);
            if (!$dt || $dt->format('Y-m-d') !== $v || $dt->format('Y') === '0000') {
                err(400, 'item_date must be a valid date in Y-m-d format');
            }
        }
    }

    if (array_key_exists('name', $item)) {
        $v = $item['name'];
        if (!is_string($v)) err(400, 'name must be a string');
        if (mb_strlen($v) < 1 || mb_strlen($v) > 255) err(400, 'name must be 1-255 characters');
    }
    if (array_key_exists('description', $item)) {
        $v = $item['description'];
        if (!is_string($v)) err(400, 'description must be a string');
        if (mb_strlen($v) > 65535) err(400, 'description must be at most 65535 characters');
    }
    if (array_key_exists('unit', $item)) {
        $v = $item['unit'];
        if (!is_string($v)) err(400, 'unit must be a string');
        if (mb_strlen($v) > 50) err(400, 'unit must be at most 50 characters');
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add api.php
git commit -m "feat: add validate_item_fields() function for item input validation"
```

---

### Task 3: Add `validate_items_array()` helper and integrate validation into PATCH handler

**Files:**
- Modify: `api.php` (PATCH handler, lines 270-304)

- [ ] **Step 1: Add `validate_items_array` helper before `validate_item_fields`**

```php
function validate_items_array($items): void {
    if ($items !== null && !is_array($items)) {
        err(400, 'items must be an array');
    }
}
```

- [ ] **Step 2: Modify PATCH handler to call validators**

Replace the PATCH handler block (lines 270-304) with:

```php
        if (count($parts) === 3 && $method === 'PATCH') {
            $body = body_json();
            validate_items_array($body['items'] ?? null);
            $s = $db->prepare('SELECT invoice_status_id FROM ip_invoices WHERE invoice_id=?');
            $s->execute([$id]);
            $row = $s->fetch();
            if (!$row) err(404, 'invoice not found');
            if ((int) $row['invoice_status_id'] !== 1) err(409, 'invoice not in draft status');

            validate_dates($body, $db, $id);

            $up = []; $args = [];
            if (isset($body['date']))     { $up[] = 'invoice_date_created=?'; $args[] = $body['date']; }
            if (isset($body['due_date'])) { $up[] = 'invoice_date_due=?';     $args[] = $body['due_date']; }
            if ($up) {
                $up[] = 'invoice_date_modified=NOW()';
                $args[] = $id;
                $s = $db->prepare('UPDATE ip_invoices SET ' . implode(',', $up) . ' WHERE invoice_id=?');
                $s->execute($args);
            }
            $cols = ['quantity' => 'item_quantity', 'price' => 'item_price', 'description' => 'item_description', 'name' => 'item_name', 'unit' => 'item_product_unit', 'order' => 'item_order', 'discount_amount' => 'item_discount_amount', 'tax_rate_id' => 'item_tax_rate_id', 'item_date' => 'item_date'];
            foreach ($body['items'] ?? [] as $i) {
                if (!isset($i['item_id'])) {
                    err(400, 'item_id is required for each item');
                }
                $iid = (int) $i['item_id'];
                $s = $db->prepare('SELECT item_id FROM ip_invoice_items WHERE item_id=? AND invoice_id=?');
                $s->execute([$iid, $id]);
                if (!$s->fetch()) err(400, 'item_id does not belong to this invoice');

                $s = $db->prepare('SELECT item_quantity, item_price FROM ip_invoice_items WHERE item_id=?');
                $s->execute([$iid]);
                $db_row = $s->fetch();

                validate_item_fields($i, $db, $id, $db_row);

                $iup = []; $iargs = [];
                foreach ($cols as $k => $col) {
                    if (isset($i[$k])) { $iup[] = "$col=?"; $iargs[] = $i[$k]; }
                }
                if ($iup) {
                    $iargs[] = $iid;
                    $iargs[] = $id;
                    $s = $db->prepare('UPDATE ip_invoice_items SET ' . implode(',', $iup) . ' WHERE item_id=? AND invoice_id=?');
                    $s->execute($iargs);
                    recompute_item($db, $iid);
                }
            }
            recompute_invoice($db, $id);
            jr(fetch_invoice($db, $id));
        }
```

Key changes from original:
- `validate_items_array()` called at top
- `validate_dates()` called before processing dates, passing `$db` and `$id` for cross-validation
- `item_id` existence check added (`SELECT ... WHERE item_id=? AND invoice_id=?`)
- DB row fetched before `validate_item_fields()` for cross-field discount check
- `validate_item_fields()` called before item processing
- `array_key_exists` → `isset` on line 292 (now inside the `$cols` loop)

- [ ] **Step 3: Commit**

```bash
git add api.php
git commit -m "feat: integrate validation into PATCH handler"
```

---

### Task 4: Integrate validation into copy handler

**Files:**
- Modify: `api.php` (copy handler)

- [ ] **Step 1: Modify copy handler to call validators**

Replace the copy handler block (lines starting at `if (count($parts) === 4 && $parts[3] === 'copy' && $method === 'POST')`) with:

```php
        if (count($parts) === 4 && $parts[3] === 'copy' && $method === 'POST') {
            $body = body_json();
            validate_items_array($body['items'] ?? null);

            $s = $db->prepare('SELECT * FROM ip_invoices WHERE invoice_id=?');
            $s->execute([$id]);
            $orig = $s->fetch();
            if (!$orig) err(404, 'invoice not found');

            validate_dates($body);

            $date     = $body['date']     ?? date('Y-m-d');
            $due_date = $body['due_date'] ?? date('Y-m-d', strtotime("$date +30 days"));

            $number   = generate_invoice_number($db, (int) $orig['invoice_group_id'], $date);
            $url_key  = bin2hex(random_bytes(16));

            $s = $db->prepare('INSERT INTO ip_invoices (user_id, client_id, invoice_group_id, invoice_status_id, invoice_date_created, invoice_date_due, invoice_date_modified, invoice_number, invoice_terms, invoice_url_key, payment_method) VALUES (?, ?, ?, 1, ?, ?, NOW(), ?, ?, ?, ?)');
            $s->execute([$orig['user_id'], $orig['client_id'], $orig['invoice_group_id'], $date, $due_date, $number, $orig['invoice_terms'] ?? '', $url_key, $orig['payment_method'] ?? 0]);
            $new_id = (int) $db->lastInsertId();

            $overrides = [];
            foreach ($body['items'] ?? [] as $i) {
                if (isset($i['item_id'])) {
                    validate_item_fields($i, $db, $id);
                    $overrides[(int) $i['item_id']] = $i;
                }
            }

            $items = $db->prepare('SELECT * FROM ip_invoice_items WHERE invoice_id=? ORDER BY item_order, item_id');
            $items->execute([$id]);
            foreach ($items->fetchAll() as $it) {
                $ov = $overrides[(int) $it['item_id']] ?? [];
                $ins = $db->prepare('INSERT INTO ip_invoice_items (invoice_id, item_tax_rate_id, item_product_id, item_task_id, item_date_added, item_name, item_description, item_quantity, item_price, item_discount_amount, item_order, item_product_unit, item_product_unit_id, item_date) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)');
                $ins->execute([
                    $new_id,
                    isset($ov['tax_rate_id']) ? $ov['tax_rate_id'] : ($it['item_tax_rate_id'] ?? 0),
                    $it['item_product_id'],
                    $it['item_task_id'],
                    $date,
                    isset($ov['name']) ? $ov['name'] : $it['item_name'],
                    isset($ov['description']) ? $ov['description'] : $it['item_description'],
                    isset($ov['quantity']) ? $ov['quantity'] : $it['item_quantity'],
                    isset($ov['price']) ? $ov['price'] : $it['item_price'],
                    isset($ov['discount_amount']) ? $ov['discount_amount'] : $it['item_discount_amount'],
                    isset($ov['order']) ? $ov['order'] : $it['item_order'],
                    isset($ov['unit']) ? $ov['unit'] : $it['item_product_unit'],
                    $it['item_product_unit_id'],
                    $it['item_date'],
                ]);
                recompute_item($db, (int) $db->lastInsertId());
            }
            recompute_invoice($db, $new_id);
            jr(['id' => $new_id, 'number' => $number, 'status' => 'draft', 'url' => "/api/v1/invoices/$new_id"], 201);
        }
```

Key changes from original:
- `validate_items_array()` called at top
- `validate_dates()` called **before** date defaulting (validates raw input)
- Numeric override fields use `isset()` instead of `??` to reject null values
- `validate_item_fields()` called for each override item before it's stored
- Fetch items query moved into the loop (prepared once, but using fetchAll pattern is fine for small item counts)

- [ ] **Step 2: Commit**

```bash
git add api.php
git commit -m "feat: integrate validation into copy handler"
```

---

### Task 5: Update SPEC.md with validation rules

**Files:**
- Modify: `SPEC.md`

- [ ] **Step 1: Add Input Validation section to SPEC.md**

After the existing endpoint documentation, add a section documenting the validation rules. This serves as the source of truth for API consumers. Read the current SPEC.md to understand its structure, then add an appropriate validation section.

The section should document:
- Date validation: must be `Y-m-d` format, year >= 1000, `due_date >= date`
- Numeric fields: non-negative, max limits (quantity 999999, price/discount 999999999), no scientific notation, no booleans, no null
- Discount cross-field: discount_amount <= quantity * price
- Integer fields: order 0-999, tax_rate_id must exist (0 = no tax)
- String fields: name 1-255 chars, description max 65535, unit max 50
- Error format: `{"error": "message"}` with HTTP 400
- item_id must belong to the invoice
- items must be an array

- [ ] **Step 2: Commit**

```bash
git add SPEC.md
git commit -m "docs: document input validation rules in SPEC.md"
```

---

### Task 6: Verification — syntax check and manual smoke test

**Files:**
- `api.php`

- [ ] **Step 1: PHP syntax check**

```bash
php -l api.php
```

Expected: `No syntax errors detected in api.php`

- [ ] **Step 2: Verify all functions are present**

```bash
grep -n 'function validate_dates\|function validate_item_fields\|function validate_items_array' api.php
```

Expected: All three functions found at expected line numbers.

- [ ] **Step 3: Verify PATCH handler calls validators**

```bash
grep -n 'validate_dates\|validate_item_fields\|validate_items_array' api.php
```

Expected: All three called from PATCH handler and copy handler.

- [ ] **Step 4: Final commit if any fixes needed**

If any issues were found and fixed, commit them.