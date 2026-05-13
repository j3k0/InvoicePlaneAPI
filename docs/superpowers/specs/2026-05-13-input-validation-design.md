# Input Validation for PATCH/copy Endpoints

**Issue:** #5 — Critical: No input validation on PATCH/copy fields  
**Date:** 2026-05-13

## Problem

The PATCH (`/api/v1/invoices/{id}`) and copy (`/api/v1/invoices/{id}/copy`) endpoints accept user input for financial and date fields without any validation. This enables:

- Negative quantities/prices creating negative invoices
- Negative discount_amount inflating invoices (double-negative)
- Invalid dates corrupting records (MySQL stores `0000-00-00`)
- Extreme numbers causing float overflow beyond DECIMAL precision
- Null values silently zeroing out prices (`array_key_exists` allows null)
- Non-existent tax_rate_id silently zeroing tax
- Scientific notation strings (`"1e3"`) accepted as numeric input
- Boolean `true` accepted and cast to `1`

## Design

### Architecture: Small Purpose-Built Validator Functions

Following the codebase convention of tiny helpers (`err`, `jr`, `tax_rate`, `recompute_item`), add two validation functions:

- `validate_dates(array $body, ?PDO $db = null, ?int $invoice_id = null): void` — validates `date` and `due_date` fields; when only one is provided in a PATCH, fetches the other from DB for cross-validation
- `validate_item_fields(array $fields): void` — validates a single item's mutable fields; called in a loop over `items[]` from both PATCH and copy

Both functions call `err(400, ...)` on failure, matching the existing error pattern.

### Validation Rules

#### Date fields (`date`, `due_date`, `item_date`)

| Rule | Detail |
|------|--------|
| Format | Must match `Y-m-d` exactly via `DateTimeImmutable::createFromFormat('Y-m-d', $v)` with strict comparison `$dt->format('Y-m-d') === $v`. Additionally reject year `0000` (`$dt->format('Y') !== '0000'`) because `0000-00-00` parses successfully but is not a valid invoice date |
| due_date >= date | For PATCH: if only one provided, fetch the other from the DB. For copy: compare directly from body/defaults |
| Required | `date` and `due_date` are optional in PATCH (only validate if present); in copy, default to today/today+30 if absent |

#### Numeric fields (`quantity`, `price`, `discount_amount`)

| Rule | Detail |
|------|--------|
| Type | Must be numeric AND match regex `/^\d+(\.\d+)?$/` (rejects scientific notation like `1e3`, negatives, null). Additionally, reject booleans explicitly with `is_bool($v)` check before the regex, since PHP coerces `true` to `"1"` in preg_match |
| Null rejection | Reject `null` explicitly — `array_key_exists` allows null, but `null` should not be accepted |
| Minimum | Must be >= 0 (zero is valid: free items, zero-discount) |
| Maximum | `quantity` <= 999999, `price` <= 999999999, `discount_amount` <= 999999999 |
| Cross-field | `discount_amount` must be <= effective quantity * effective price, where effective values come from the request if provided, otherwise from the existing DB row. This prevents negative subtotals after recompute |

#### Integer fields (`order`, `tax_rate_id`)

| Rule | Detail |
|------|--------|
| Type | Must be `is_int($v)` or `(is_string($v) && ctype_digit($v))`. Reject booleans, floats, null |
| order range | 0 <= order <= 999 |
| tax_rate_id | Special case: `0` or `null` or absent means "no tax" (InvoicePlane convention) — skip FK check. Positive integer values must exist in `ip_tax_rates`. Negative values and booleans rejected. This overrides the generic integer rule for this field: null is explicitly allowed for tax_rate_id |

#### String fields (`name`, `description`, `unit`)

| Rule | Detail |
|------|--------|
| Type | Must be string if present. Reject null, booleans |
| Empty strings | `name` must be non-empty (min 1 char). `description` and `unit` may be empty strings |
| name length | 1-255 characters |
| description length | max 65535 characters |
| unit length | max 50 characters |

#### `item_date` (inside items)

| Rule | Detail |
|------|--------|
| Format | Same strict `Y-m-d` validation as invoice-level dates, including year != 0000 check |
| When validated | Inside `validate_item_fields()`, since `item_date` is an item-level field |

### Overflow Safety

The caps were chosen to prevent DECIMAL overflow in computed columns:

- Max subtotal = 999999 * 999999999 ≈ 9.99e14, well within DECIMAL(20,2) max (~1e18)
- Max discount_amount = 999999999, which is always <= subtotal (cross-field check)
- Max tax computation: subtotal * tax_percent / 100 stays within bounds

### Code Changes

1. **Add `validate_dates()` function** (after `tax_rate()`, before `recompute_item()`)
   - Validates date format using strict `Y-m-d` parsing
   - For PATCH: fetches existing invoice dates when only one date is provided
   - Ensures `due_date >= date`

2. **Add `validate_item_fields()` function** (after `validate_dates()`)
   - Validates only the fields **present in the request** (partial updates — not all fields need to be present)
   - Returns void, calls `err(400, ...)` on failure
   - Shared by both PATCH and copy handlers
   - For cross-field check (discount_amount <= qty * price): when discount_amount is provided but quantity/price are not in the same request, fetch the current values from DB to compute the effective subtotal

3. **Modify PATCH handler** (lines 270-304)
   - Call `validate_dates($body, $db, $id)` before processing invoice-level updates
   - Call `validate_item_fields($i)` inside the items loop before processing each item

4. **Modify copy handler** (lines 306-353)
   - Call `validate_dates($body)` **before** extracting defaults (lines 316-317). This ensures `$body['date']` is validated before `strtotime("$date +30 days")` or `DateTimeImmutable` processes it
   - Call `validate_item_fields($i)` inside the overrides loop before processing each item override

5. **Modify `array_key_exists` to `isset` for item fields** (line 292)
   - Change `array_key_exists($k, $i)` to `isset($i[$k])` in PATCH handler to reject null values
   - In copy handler, use `isset($ov['field'])` instead of `??` for numeric overrides (but keep `??` for optional string fields where null should fall back to original)
   - **Behavioral change**: This means `{"price": null}` is no longer silently accepted — it will be rejected with a validation error (previously, null was cast to `0.0` by `(float)`). This is intentional: null should not zero out financial fields

6. **Add explicit item_id ownership check in PATCH handler**
   - Currently, a mismatched `item_id` silently does nothing due to `WHERE item_id=? AND invoice_id=?`. Add an explicit `SELECT 1 FROM ip_invoice_items WHERE item_id=? AND invoice_id=?` check before processing each item, returning 400 if the item doesn't belong to this invoice

### Error Responses

All validation failures return `400` with a descriptive message:
- `invalid date format, expected Y-m-d`
- `due_date must be on or after date`
- `quantity must be a non-negative number`
- `quantity must not exceed 999999`
- `price must be a non-negative number`
- `price must not exceed 999999999`
- `discount_amount must be a non-negative number`
- `discount_amount must not exceed quantity * price`
- `tax_rate_id must be a positive integer`
- `invalid tax_rate_id`
- `order must be an integer between 0 and 999`
- `name must be a string with at most 255 characters`
- `description must be a string with at most 65535 characters`
- `unit must be a string with at most 50 characters`
- `items must be an array`
- `item_id is required for each item` (PATCH)
- `items must be an array if provided`
- `item_id must match an item on this invoice` (PATCH — item_id must belong to the invoice being patched)

### Not In Scope

- Transaction wrapping (issue #4)
- Status transition business rules (issue #6)
- Rate limiting (issue #10)
- Request body size limits (issue #9)
- IDOR protection (issue #7)
- Host header injection (issue #2)
- Auth bypass via $_SERVER (issue #1)
- Race condition in invoice number generation (issue #3)
- Error response information leakage (issue #8)