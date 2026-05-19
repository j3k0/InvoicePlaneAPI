# InvoicePlane REST API Specification

> A thin standalone REST API on top of the InvoicePlane MySQL database for programmatic invoice management.

## Motivation

InvoicePlane has no REST API — everything is form submissions and AJAX-loaded HTML modals behind session-based authentication. Our automated workflows (reconciliation, yearly invoice copies, cron-triggered invoice creation) require reliable programmatic access to invoice data.

Rather than scraping HTML or parsing CSV exports, we want direct SQL queries against the MySQL database exposed through a minimal, key-secured REST API.

## Architecture Decision: Standalone

**Single PHP file** (`api/index.php`) with its own PDO connection. Not integrated into InvoicePlane's CodeIgniter/HMVC stack.

**Why not a CodeIgniter module or fork + PR?**
- Env-var API key auth means zero dependency on InvoicePlane's session system, migrations, or user model
- Survives any InvoicePlane upgrade — just drop the file in and configure Nginx
- 200-line single file vs. multi-file HMVC module with controllers, libraries, helpers, routes, migration
- Deploys in 30 seconds, no PR review latency, no maintenance burden on upstream

## Authentication

```php
// Authorization: Bearer <key>
// Env var: INVOICEPLANE_API_KEY="key1,key2,key3"
```
Plain-text keys, comma-separated in an environment variable. Rotation: add new key → deploy → remove old. Zero crypto, zero DB schema changes.

## Base URL

`https://invoices-eur.fovea.cc/api/v1`

Nginx config:

```nginx
location /api/ {
    rewrite ^/api/(.*) /api/index.php/$1 last;
}
location /api/index.php {
    fastcgi_pass invoiceplane:9000;
    fastcgi_param INVOICEPLANE_API_KEY "key1,key2";
    fastcgi_param INVOICEPLANE_DB_HOST "mysql";
    fastcgi_param INVOICEPLANE_DB_NAME "invoiceplane_db";
    fastcgi_param INVOICEPLANE_DB_USER "invoiceplane";
    fastcgi_param INVOICEPLANE_DB_PASS "password";
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME /var/www/html/api/index.php;
}
```

## Endpoints

### 1. List/Filter Invoices

```
GET /api/v1/invoices
```

**Query parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `client_id` | int | Filter by client ID |
| `q` | string | Search across `item_name` and `item_description` (SQL `LIKE '%value%'`) |
| `status` | string | Comma-separated: `draft`, `sent`, `viewed`, `paid`; or `all` (default: exclude drafts) |
| `order` | string | `date_desc` (default), `date_asc`, `amount_desc` |
| `limit` | int | Max results (default 25, max 100) |
| `offset` | int | Pagination offset |

**Response (200):**

```json
{
  "total": 42,
  "invoices": [
    {
      "id": 168,
      "number": "20250506E",
      "date": "2025-05-06",
      "due_date": "2025-06-05",
      "status": "paid",
      "client_id": 5,
      "client_name": "Goliath BV",
      "total": 2434.80,
      "currency": "EUR",
      "item_summary": "Month of Wordpress Hosting, Month of Disabled Website Storage"
    }
  ]
}
```

### 2. Get Single Invoice

```
GET /api/v1/invoices/{id}
```

**Response (200):**

```json
{
  "id": 168,
  "number": "20250506E",
  "date": "2025-05-06",
  "due_date": "2025-06-05",
  "status": "paid",
  "is_read_only": 1,
  "client": {
    "id": 5,
    "name": "Goliath BV",
    "address": "Vijzelpad 80, Hattem 8051 KR, The Netherlands",
    "email": "invoices@goliathgames.nl"
  },
  "items": [
    {
      "id": 456,
      "name": "Month of Wordpress Hosting",
      "description": "33 websites at 5,70 euro per month each. (33 x 12 = 396)\nFrom 01-may-2025 to 30-apr-2026 included.",
      "quantity": 396.00000000,
      "unit": "month/months",
      "price": 5.70,
      "subtotal": 2257.20,
      "tax_total": 0.00,
      "discount": 0.00,
      "total": 2257.20,
      "item_date": null,
      "item_order": 0
    },
    {
      "id": 457,
      "name": "Month of Disabled Website Storage",
      "description": "37 websites at 0,40 euro per month each. (37 x 12 = 444)\nFrom 01-may-2025 to 30-apr-2026 included.",
      "quantity": 444.00000000,
      "unit": "month/months",
      "price": 0.40,
      "subtotal": 177.60,
      "tax_total": 0.00,
      "discount": 0.00,
      "total": 177.60,
      "item_date": null,
      "item_order": 1
    }
  ],
  "amounts": {
    "total": 2434.80,
    "paid": 2434.80,
    "balance": 0.00
  },
  "guest_url": "https://invoices-eur.fovea.cc/index.php/guest/view/invoice/NbgkO1RUrKCxe4SAnwyJ9DEqsil7Iju3"
}
```

### 3. Copy Invoice as Draft

```
POST /api/v1/invoices/{id}/copy
```

Creates a carbon-copy of the invoice as a new draft. Clones all items (name, description, quantity, price, unit, order). Generates a new invoice number using the same invoice group. Sets date to today unless overridden.

**Request body (all optional):**

```json
{
  "date": "2026-05-06",
  "due_date": "2026-06-05",
  "items": [
    {
      "item_id": 456,
      "quantity": 384,
      "price": 5.70,
      "description": "32 websites at 5,70 euro per month each. (32 x 12 = 384)\nFrom 01-may-2026 to 30-apr-2027 included."
    }
  ]
}
```

- If `items[].item_id` matches an original item, that item is updated with the new values. Other fields (name, unit, order, tax_rate_id) are cloned from the original unless explicitly provided.
- Items not mentioned in the request are cloned verbatim.
- If the `items` array is absent or empty, all items are cloned verbatim.

**Response (201):**

```json
{
  "id": 172,
  "number": "20260506E",
  "status": "draft",
  "url": "/api/v1/invoices/172"
}
```

### 4. Update Draft Invoice

```
PATCH /api/v1/invoices/{id}
```

Only works on invoices with `invoice_status_id = 1` (draft). Any fields not provided are left unchanged. Recomputes amounts after changes.

**Request body:**

```json
{
  "date": "2026-05-06",
  "due_date": "2026-06-05",
  "items": [
    {
      "item_id": 456,
      "quantity": 384,
      "price": 5.70,
      "description": "Updated description"
    }
  ]
}
```

**Response (200):** Updated invoice object (same format as GET single).

### 5. Set Invoice Status

```
POST /api/v1/invoices/{id}/status
```

**Request body:**

```json
{
  "status": "sent"
}
```

Valid transitions (monotonically increasing in InvoicePlane): `draft` → `sent` → `viewed` → `paid`.

**Response (200):** `{"status": "sent"}`

### 6. Health Check

```
GET /api/v1/health
```

No auth required. **Response (200):**

```json
{
  "status": "ok",
  "db": "connected"
}
```

## Verified Database Schema

Source: `application/modules/setup/sql/` migration files (44 files, v1.0.0 to v1.7.2). Engine: MyISAM, charset: utf8. No FK constraints (MyISAM doesn't support them).

### `ip_invoices`

| Column | Type | Notes |
|--------|------|-------|
| `invoice_id` | INT(11) PK AUTO_INCREMENT | |
| `user_id` | INT(11) NOT NULL | |
| `client_id` | INT(11) NOT NULL | → `ip_clients.client_id` |
| `invoice_group_id` | INT(11) NOT NULL | → `ip_invoice_groups.invoice_group_id` |
| `invoice_status_id` | TINYINT(2) NOT NULL DEFAULT 1 | 1=draft, 2=sent, 3=viewed, 4=paid |
| `is_read_only` | TINYINT(1) NULL | Set after leaving draft |
| `creditinvoice_parent_id` | INT(11) NULL | Self-referencing for credit notes |
| `invoice_date_created` | DATE NOT NULL | |
| `invoice_date_due` | DATE NOT NULL | |
| `invoice_date_modified` | DATETIME NOT NULL | |
| `invoice_time_created` | TIME NOT NULL DEFAULT '00:00:00' | |
| `invoice_number` | VARCHAR(100) NULL | Generated by group, nullable for drafts if settings say so |
| `invoice_terms` | LONGTEXT NOT NULL | |
| `invoice_url_key` | CHAR(32) NOT NULL UNIQUE | Guest access token |
| `payment_method` | INT NOT NULL DEFAULT 0 | |
| `invoice_password` | VARCHAR(90) NULL | PDF password |
| `invoice_discount_amount` | DECIMAL(20,2) NULL | |
| `invoice_discount_percent` | DECIMAL(20,2) NULL | |

### `ip_invoice_items`

| Column | Type | Notes |
|--------|------|-------|
| `item_id` | INT(11) PK AUTO_INCREMENT | |
| `invoice_id` | INT(11) NOT NULL | → `ip_invoices.invoice_id` |
| `item_tax_rate_id` | INT(11) NOT NULL DEFAULT 0 | |
| `item_product_id` | INT(11) NULL | → `ip_products.product_id` |
| `item_task_id` | INT(11) NULL | |
| `item_date_added` | DATE NOT NULL | |
| `item_name` | TEXT | |
| `item_description` | LONGTEXT | The "description" field from the UI |
| `item_quantity` | DECIMAL(20,8) | High precision |
| `item_price` | DECIMAL(20,2) | |
| `item_discount_amount` | DECIMAL(20,2) NULL | |
| `item_order` | INT(2) NOT NULL DEFAULT 0 | Sort order |
| `item_is_recurring` | TINYINT(1) NULL | |
| `item_product_unit` | VARCHAR(50) NULL | e.g. "month/months" |
| `item_product_unit_id` | INT(11) NULL | |
| `item_date` | DATE NULL | Single date field (no date_from/date_to — dates go in description) |

### `ip_invoice_item_amounts`

| Column | Type | Notes |
|--------|------|-------|
| `item_amount_id` | INT(11) PK AUTO_INCREMENT | |
| `item_id` | INT(11) NOT NULL | → `ip_invoice_items.item_id` |
| `item_subtotal` | DECIMAL(20,2) NOT NULL | quantity × price |
| `item_tax_total` | DECIMAL(20,2) NOT NULL | |
| `item_discount` | DECIMAL(20,2) NULL | |
| `item_total` | DECIMAL(20,2) NOT NULL | subtotal + tax − discount |

### `ip_invoice_amounts`

| Column | Type | Notes |
|--------|------|-------|
| `invoice_amount_id` | INT(11) PK AUTO_INCREMENT | |
| `invoice_id` | INT(11) NOT NULL | 1:1 with `ip_invoices` |
| `invoice_sign` | ENUM('1','-1') NOT NULL DEFAULT '1' | '1' = normal, '-1' = credit note |
| `invoice_item_subtotal` | DECIMAL(20,2) DEFAULT '0.00' | |
| `invoice_item_tax_total` | DECIMAL(20,2) DEFAULT '0.00' | |
| `invoice_tax_total` | DECIMAL(20,2) DEFAULT '0.00' | |
| `invoice_total` | DECIMAL(20,2) DEFAULT '0.00' | |
| `invoice_paid` | DECIMAL(20,2) DEFAULT '0.00' | |
| `invoice_balance` | DECIMAL(20,2) DEFAULT '0.00' | invoice_total − invoice_paid |

### `ip_clients`

| Column | Type | Notes |
|--------|------|-------|
| `client_id` | INT(11) PK AUTO_INCREMENT | |
| `client_name` | TEXT NOT NULL | |
| `client_address_1` | TEXT | |
| `client_address_2` | TEXT | |
| `client_city` | TEXT | |
| `client_state` | TEXT | |
| `client_zip` | TEXT | |
| `client_country` | TEXT | |
| `client_email` | TEXT | |
| `client_active` | INT(1) NOT NULL DEFAULT 1 | |

### `ip_invoice_groups`

| Column | Type | Notes |
|--------|------|-------|
| `invoice_group_id` | INT(11) PK AUTO_INCREMENT | |
| `invoice_group_name` | TEXT NOT NULL DEFAULT '' | |
| `invoice_group_identifier_format` | VARCHAR(255) NOT NULL | Template with `{{{year}}}`, `{{{month}}}`, `{{{day}}}`, `{{{id}}}` |
| `invoice_group_next_id` | INT(11) NOT NULL | Auto-increment counter for `{{{id}}}` |
| `invoice_group_left_pad` | INT(2) NOT NULL DEFAULT 0 | Zero-pad width for the ID |

### Invoice Statuses — NOT in DB

Hardcoded in `application/modules/invoices/models/Mdl_invoices.php`:

| ID | Name |
|----|------|
| 1 | Draft |
| 2 | Sent |
| 3 | Viewed |
| 4 | Paid |

### Invoice Number Generation

Logic from `application/modules/invoice_groups/models/Mdl_invoice_groups.php`:

1. Parse `invoice_group_identifier_format` (e.g. `{{{year}}}{{{month}}}{{{day}}}{{{id}}}` → `2026050601`)
2. Replace tokens with current date and padded `invoice_group_next_id`
3. Increment `invoice_group_next_id` atomically: `UPDATE ... SET invoice_group_next_id = invoice_group_next_id + 1`

Drafts may have a NULL invoice number if the `generate_invoice_number_for_draft` setting is 0 (number generated on first status transition). Our copy endpoint always generates a number immediately.

## SQL Patterns

### Invoice search with item matching

```sql
SELECT DISTINCT i.invoice_id
FROM ip_invoices i
JOIN ip_invoice_items it ON i.invoice_id = it.invoice_id
WHERE i.client_id = ?
  AND (it.item_name LIKE CONCAT('%', ?, '%')
       OR it.item_description LIKE CONCAT('%', ?, '%'))
  AND i.invoice_status_id != 1  -- exclude drafts by default
ORDER BY i.invoice_date_created DESC
LIMIT ? OFFSET ?
```

### Compute invoice amounts after insert/update

```sql
-- Invoice-level totals
UPDATE ip_invoice_amounts
SET invoice_item_subtotal = (SELECT COALESCE(SUM(item_subtotal), 0) FROM ip_invoice_item_amounts ia JOIN ip_invoice_items ii ON ia.item_id = ii.item_id WHERE ii.invoice_id = ?),
    invoice_item_tax_total = (SELECT COALESCE(SUM(item_tax_total), 0) FROM ip_invoice_item_amounts ia JOIN ip_invoice_items ii ON ia.item_id = ii.item_id WHERE ii.invoice_id = ?),
    invoice_total = invoice_item_subtotal + invoice_item_tax_total + invoice_tax_total,
    invoice_balance = invoice_total - invoice_paid
WHERE invoice_id = ?
```

### Atomic invoice number generation

```sql
UPDATE ip_invoice_groups
SET invoice_group_next_id = invoice_group_next_id + 1
WHERE invoice_group_id = ?
```

## Security

- API key env var compared with `hash_equals()` (timing-safe)
- All query parameters bound via PDO prepared statements — no string interpolation
- `Content-Type: application/json` with `X-Content-Type-Options: nosniff`
- `GET /health` is the only unauthenticated endpoint
- No exposure of `ip_users` table, session tokens, or internal InvoicePlane paths

## Input Validation

All mutation endpoints validate input before writing to the database. Validation failures return `400` with `{"error": "message"}`.

### Date fields (`date`, `due_date`, `item_date`)

| Rule | Detail |
|------|--------|
| Format | Must be `Y-m-d` (strict round-trip check; rejects `0000-00-00`) |
| Cross-field | `due_date` must be >= `date`; for PATCH with only one date, the other is fetched from DB |

### Numeric fields (`quantity`, `price`, `discount_amount`)

| Rule | Detail |
|------|--------|
| Type | Must match `/^\d+(\.\d+)?$/` (rejects scientific notation, negatives, null, booleans) |
| Minimum | >= 0 (zero is valid) |
| Maximum | `quantity` <= 999999, `price` <= 999999999, `discount_amount` <= 999999999 |
| Cross-field | `discount_amount` must be <= effective quantity * effective price |

### Integer fields (`order`, `tax_rate_id`)

| Rule | Detail |
|------|--------|
| `order` | Integer 0-999; rejects booleans, floats, null |
| `tax_rate_id` | `0` or absent = no tax (no FK check); positive must exist in `ip_tax_rates`; rejects negatives, booleans |

### String fields (`name`, `description`, `unit`)

| Rule | Detail |
|------|--------|
| `name` | String, 1-255 characters (non-empty) |
| `description` | String, max 65535 characters |
| `unit` | String, max 50 characters |

### Structural validation

| Rule | Detail |
|------|--------|
| `items` | Must be an array if provided |
| `item_id` | Required for each item in PATCH; must belong to the target invoice. **Breaking change:** previously items without `item_id` were silently skipped; now they return 400 |
| Null rejection | Null values for numeric fields are rejected (prevents silent zeroing) |

### Overflow safety

Caps prevent computed-column overflow: max subtotal = 999999 * 999999999 ≈ 1e15, well within DECIMAL(20,2) max (~1e18).

## Implementation Notes

- File: `/srv/docker/invoiceplane/html/api/index.php` (or wherever the web root is volume-mounted)
- Single file, no Composer deps, no autoloader
- Reads `$_ENV` for DB credentials and API keys
- ~200 lines of PHP total

## Deliverables

1. ✅ Verified database schema (subagent report)
2. ✅ This specification
3. Working `api/index.php` implementation
4. Nginx config snippet
5. Docker compose update (env vars)
6. Hermes skill: `invoiceplane-api` for Hermes to interact with the API
