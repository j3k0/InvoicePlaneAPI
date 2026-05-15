# Test Infrastructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a Docker Compose test stack and automated integration test suite for InvoicePlaneAPI that can validate PRs and changes.

**Architecture:** Three-container Docker stack (MariaDB + InvoicePlane php-fpm + InvoicePlane nginx) with deterministic seed data, curl+jq test runner, and non-persistent volumes for clean resets. api.php is bind-mounted live into the php-fpm container.

**Tech Stack:** Docker Compose, MariaDB 10, jeko/invoiceplane:1.7.1-1, Bash, curl, jq

---

## File Structure

| File | Action | Purpose |
|------|--------|---------|
| `tests/seed.sql` | Create | Schema + test data loaded by MariaDB init |
| `tests/nginx-site.conf` | Create | Nginx config with /api/ fastcgi routing |
| `tests/nginx-entrypoint.sh` | Create | Custom entrypoint for nginx container |
| `docker-compose.test.yml` | Create | Three-service test stack (mysql, invoiceplane, nginx) |
| `tests/test.sh` | Create | 18-test integration runner with curl+jq assertions |
| `AGENTS.md` | Create | Project guide with testing instructions |

---

### Task 1: Create tests/seed.sql

**Files:**
- Create: `tests/seed.sql`

- [ ] **Step 1: Write the seed SQL file**

Create `tests/seed.sql` with the complete schema and test data:

```sql
SET NAMES utf8;
USE invoiceplane_db;

CREATE TABLE IF NOT EXISTS ip_users (
    user_id INT(11) NOT NULL AUTO_INCREMENT,
    user_email VARCHAR(255) NOT NULL,
    user_name VARCHAR(255) NOT NULL,
    user_password VARCHAR(60) NOT NULL,
    user_type VARCHAR(255) NOT NULL DEFAULT '1',
    user_active INT(1) NOT NULL DEFAULT '1',
    PRIMARY KEY (user_id)
) ENGINE=MyISAM DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS ip_clients (
    client_id INT(11) NOT NULL AUTO_INCREMENT,
    client_name TEXT NOT NULL,
    client_address_1 TEXT,
    client_address_2 TEXT,
    client_city TEXT,
    client_state TEXT,
    client_zip TEXT,
    client_country TEXT,
    client_email TEXT,
    client_active INT(1) NOT NULL DEFAULT '1',
    PRIMARY KEY (client_id)
) ENGINE=MyISAM DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS ip_invoice_groups (
    invoice_group_id INT(11) NOT NULL AUTO_INCREMENT,
    invoice_group_name TEXT NOT NULL DEFAULT '',
    invoice_group_identifier_format VARCHAR(255) NOT NULL,
    invoice_group_next_id INT(11) NOT NULL,
    invoice_group_left_pad INT(2) NOT NULL DEFAULT '0',
    PRIMARY KEY (invoice_group_id)
) ENGINE=MyISAM DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS ip_tax_rates (
    tax_rate_id INT(11) NOT NULL AUTO_INCREMENT,
    tax_rate_name VARCHAR(255) NOT NULL,
    tax_rate_percent DECIMAL(10,2) NOT NULL,
    PRIMARY KEY (tax_rate_id)
) ENGINE=MyISAM DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS ip_invoices (
    invoice_id INT(11) NOT NULL AUTO_INCREMENT,
    user_id INT(11) NOT NULL,
    client_id INT(11) NOT NULL,
    invoice_group_id INT(11) NOT NULL,
    invoice_status_id TINYINT(2) NOT NULL DEFAULT '1',
    is_read_only TINYINT(1) NULL,
    creditinvoice_parent_id INT(11) NULL,
    invoice_date_created DATE NOT NULL,
    invoice_date_due DATE NOT NULL,
    invoice_date_modified DATETIME NOT NULL,
    invoice_time_created TIME NOT NULL DEFAULT '00:00:00',
    invoice_number VARCHAR(100) NULL,
    invoice_terms LONGTEXT NOT NULL,
    invoice_url_key CHAR(32) NOT NULL,
    payment_method INT NOT NULL DEFAULT '0',
    invoice_password VARCHAR(90) NULL,
    invoice_discount_amount DECIMAL(20,2) NULL,
    invoice_discount_percent DECIMAL(20,2) NULL,
    PRIMARY KEY (invoice_id)
) ENGINE=MyISAM DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS ip_invoice_items (
    item_id INT(11) NOT NULL AUTO_INCREMENT,
    invoice_id INT(11) NOT NULL,
    item_tax_rate_id INT(11) NOT NULL DEFAULT '0',
    item_product_id INT(11) NULL,
    item_task_id INT(11) NULL,
    item_date_added DATE NOT NULL,
    item_name TEXT,
    item_description LONGTEXT,
    item_quantity DECIMAL(20,8),
    item_price DECIMAL(20,2),
    item_discount_amount DECIMAL(20,2) NULL,
    item_order INT(2) NOT NULL DEFAULT '0',
    item_is_recurring TINYINT(1) NULL,
    item_product_unit VARCHAR(50) NULL,
    item_product_unit_id INT(11) NULL,
    item_date DATE NULL,
    PRIMARY KEY (item_id)
) ENGINE=MyISAM DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS ip_invoice_item_amounts (
    item_amount_id INT(11) NOT NULL AUTO_INCREMENT,
    item_id INT(11) NOT NULL,
    item_subtotal DECIMAL(20,2) NOT NULL,
    item_tax_total DECIMAL(20,2) NOT NULL,
    item_discount DECIMAL(20,2) NULL,
    item_total DECIMAL(20,2) NOT NULL,
    PRIMARY KEY (item_amount_id)
) ENGINE=MyISAM DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS ip_invoice_amounts (
    invoice_amount_id INT(11) NOT NULL AUTO_INCREMENT,
    invoice_id INT(11) NOT NULL,
    invoice_sign ENUM('1','-1') NOT NULL DEFAULT '1',
    invoice_item_subtotal DECIMAL(20,2) DEFAULT '0.00',
    invoice_item_tax_total DECIMAL(20,2) DEFAULT '0.00',
    invoice_tax_total DECIMAL(20,2) DEFAULT '0.00',
    invoice_total DECIMAL(20,2) DEFAULT '0.00',
    invoice_paid DECIMAL(20,2) DEFAULT '0.00',
    invoice_balance DECIMAL(20,2) DEFAULT '0.00',
    PRIMARY KEY (invoice_amount_id)
) ENGINE=MyISAM DEFAULT CHARSET=utf8;

INSERT INTO ip_users (user_id, user_email, user_name, user_password, user_type) VALUES
(1, 'admin@example.com', 'Admin', '$2y$10$invalidhashforseedonly', '1');

INSERT INTO ip_clients (client_id, client_name, client_address_1, client_city, client_country, client_email) VALUES
(1, 'Acme Corp', '123 Main St', 'Springfield', 'US', 'billing@acme.example'),
(2, 'Goliath BV', 'Vijzelpad 80', 'Hattem', 'NL', 'invoices@goliathgames.nl');

INSERT INTO ip_invoice_groups (invoice_group_id, invoice_group_name, invoice_group_identifier_format, invoice_group_next_id, invoice_group_left_pad) VALUES
(1, 'Default', '{{{year}}}{{{month}}}{{{day}}}{{{id}}}', 4, 3);

INSERT INTO ip_tax_rates (tax_rate_id, tax_rate_name, tax_rate_percent) VALUES
(1, 'None', 0.00),
(2, 'VAT 21%', 21.00);

INSERT INTO ip_invoices (invoice_id, user_id, client_id, invoice_group_id, invoice_status_id, is_read_only, invoice_date_created, invoice_date_due, invoice_date_modified, invoice_number, invoice_terms, invoice_url_key, payment_method) VALUES
(1, 1, 1, 1, 1, 0, '2026-05-01', '2026-05-31', '2026-05-01 00:00:00', 'INV001', '', 'aaaaurlkey1111bbbburlkey2222', 0),
(2, 1, 2, 1, 2, 1, '2026-04-15', '2026-05-15', '2026-04-15 00:00:00', 'INV002', '', 'ccccurlkey3333ddddurlkey4444', 0),
(3, 1, 1, 1, 4, 1, '2026-03-10', '2026-04-10', '2026-03-10 00:00:00', 'INV003', '', 'eeeeurlkey5555ffffurlkey6666', 0);

INSERT INTO ip_invoice_items (item_id, invoice_id, item_tax_rate_id, item_product_id, item_task_id, item_date_added, item_name, item_description, item_quantity, item_price, item_discount_amount, item_order, item_product_unit, item_date) VALUES
(1, 1, 0, NULL, NULL, '2026-05-01', 'Website Hosting', '12 months of hosting at 50.00/month', 12.00000000, 50.00, 0.00, 0, 'month/months', NULL),
(2, 1, 0, NULL, NULL, '2026-05-01', 'SSL Certificate', 'Annual SSL certificate', 1.00000000, 75.00, 0.00, 1, NULL, NULL),
(3, 2, 2, NULL, NULL, '2026-04-15', 'Consulting Hours', '10 hours of consulting at 120.00/hour', 10.00000000, 120.00, 0.00, 0, 'hour/hours', NULL),
(4, 2, 0, NULL, NULL, '2026-04-15', 'Domain Registration', '1 domain registration', 1.00000000, 15.00, 0.00, 1, NULL, NULL),
(5, 3, 0, NULL, NULL, '2026-03-10', 'Annual Maintenance', 'Yearly maintenance contract', 1.00000000, 600.00, 0.00, 0, 'year/years', NULL);

INSERT INTO ip_invoice_item_amounts (item_amount_id, item_id, item_subtotal, item_tax_total, item_discount, item_total) VALUES
(1, 1, 600.00, 0.00, 0.00, 600.00),
(2, 2, 75.00, 0.00, 0.00, 75.00),
(3, 3, 1200.00, 252.00, 0.00, 1452.00),
(4, 4, 15.00, 0.00, 0.00, 15.00),
(5, 5, 600.00, 0.00, 0.00, 600.00);

INSERT INTO ip_invoice_amounts (invoice_amount_id, invoice_id, invoice_sign, invoice_item_subtotal, invoice_item_tax_total, invoice_tax_total, invoice_total, invoice_paid, invoice_balance) VALUES
(1, 1, '1', 675.00, 0.00, 0.00, 675.00, 0.00, 675.00),
(2, 2, '1', 1215.00, 252.00, 0.00, 1467.00, 0.00, 1467.00),
(3, 3, '1', 600.00, 0.00, 0.00, 600.00, 600.00, 0.00);
```

- [ ] **Step 2: Commit seed.sql**

```bash
git add tests/seed.sql
git commit -m "feat: add seed SQL for test infrastructure"
```

---

### Task 2: Create tests/nginx-site.conf

**Files:**
- Create: `tests/nginx-site.conf`

> **Note:** The jeko/invoiceplane image entrypoint creates its own config at `/etc/nginx/sites-enabled/InvoicePlane.conf` with `server_name localhost`. To have our config take effect, we must mount over that path. The entrypoint checks `! -f` before creating it, so our bind mount prevents it from being overwritten.

- Create: `tests/nginx-entrypoint.sh`

> **Note:** The jeko/invoiceplane image entrypoint creates `/etc/nginx/sites-enabled/InvoicePlane.conf` at startup and does `chmod` on the data directory. Our custom entrypoint creates `/var/lib/invoiceplane`, runs the original entrypoint in the background, waits briefly, then overwrites the generated config with our custom one and reloads nginx.

- [ ] **Step 1: Write the nginx entrypoint script**

Create `tests/nginx-site.conf`:

```nginx
server {
    listen 80;
    server_name localhost;
    root /var/www/html;
    index index.php index.html;

    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    location /api/ {
        rewrite ^/api/(.*) /api/index.php/$1 last;
    }

    location /api/index.php {
        fastcgi_pass invoiceplane:9000;
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_param PATH_INFO $fastcgi_path_info;
        fastcgi_param INVOICEPLANE_API_KEY "test-api-key";
        fastcgi_param INVOICEPLANE_DB_HOST "mysql";
        fastcgi_param INVOICEPLANE_DB_NAME "invoiceplane_db";
        fastcgi_param INVOICEPLANE_DB_USER "invoiceplane";
        fastcgi_param INVOICEPLANE_DB_PASS "password";
        fastcgi_param INVOICEPLANE_BASE_URL "http://localhost:10080";
        fastcgi_param INVOICEPLANE_CURRENCY "EUR";
        fastcgi_param REQUEST_SCHEME http;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME /var/www/html/api/index.php;
    }

    location ~ \.php$ {
        fastcgi_pass invoiceplane:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\. {
        deny all;
    }
}
```

Key changes from the initial design:
- `server_name localhost` — matches the `Host` header from curl (the image's entrypoint creates an `InvoicePlane.conf` with `server_name localhost`, so we must match)
- `fastcgi_split_path_info` + `PATH_INFO` — api.php uses `$_SERVER['PATH_INFO']` for routing (line 185: `$path = $_SERVER['PATH_INFO'] ?? ...`). Without this, all API endpoints would 404.
- `REQUEST_SCHEME http` — ensures `$_SERVER['REQUEST_SCHEME']` is set for `guest_url` generation.

- [ ] **Step 2: Commit nginx config**

```bash
git add tests/nginx-site.conf
git commit -m "feat: add nginx config for test stack with /api/ routing and PATH_INFO"
```

---

### Task 3: Create docker-compose.test.yml

**Files:**
- Create: `docker-compose.test.yml`

- [ ] **Step 1: Write the compose file**

Create `docker-compose.test.yml`:

```yaml
services:
  mysql:
    image: mariadb:10
    environment:
      MYSQL_ROOT_PASSWORD: rootpassword
      MYSQL_DATABASE: invoiceplane_db
      MYSQL_USER: invoiceplane
      MYSQL_PASSWORD: password
    volumes:
      - ./tests/seed.sql:/docker-entrypoint-initdb.d/01-seed.sql:ro
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 3s
      timeout: 5s
      retries: 10

  invoiceplane:
    image: jeko/invoiceplane:1.7.1-1
    command: app:invoiceplane
    environment:
      INVOICEPLANE_FQDN: localhost
      INVOICEPLANE_TIMEZONE: UTC
      INVOICEPLANE_URL: http://localhost:10080
      DB_HOST: mysql
      DB_NAME: invoiceplane_db
      DB_USER: invoiceplane
      DB_PASS: password
      INVOICEPLANE_API_KEY: test-api-key
      INVOICEPLANE_DB_HOST: mysql
      INVOICEPLANE_DB_NAME: invoiceplane_db
      INVOICEPLANE_DB_USER: invoiceplane
      INVOICEPLANE_DB_PASS: password
    volumes:
      - ./api.php:/var/www/html/api/index.php:ro
      - /var/lib/invoiceplane
    depends_on:
      mysql:
        condition: service_healthy

  nginx:
    image: jeko/invoiceplane:1.7.1-1
    entrypoint: /usr/local/bin/override-entrypoint.sh
    command: app:nginx
    environment:
      INVOICEPLANE_PHP_FPM_HOST: invoiceplane
      INVOICEPLANE_PHP_FPM_PORT: "9000"
    ports:
      - "10080:80"
    volumes_from:
      - invoiceplane
    volumes:
      - ./tests/nginx-site.conf:/etc/nginx/custom-site.conf:ro
      - ./tests/nginx-entrypoint.sh:/usr/local/bin/override-entrypoint.sh:ro
    depends_on:
      - invoiceplane
```

Key changes from the initial design:
- Added `INVOICEPLANE_URL` to invoiceplane service — the image entrypoint uses this to configure InvoicePlane's base URL.
- Added `INVOICEPLANE_PHP_FPM_HOST` and `INVOICEPLANE_PHP_FPM_PORT` to nginx service — the image entrypoint requires these to configure the PHP-FPM connection.
- Added anonymous volume `/var/lib/invoiceplane` on the invoiceplane service — the entrypoint's `initialize_datadir` needs to `chmod` this directory.
- Used a custom entrypoint (`tests/nginx-entrypoint.sh`) for the nginx service — the image's entrypoint creates and `chmod`s `/etc/nginx/sites-enabled/InvoicePlane.conf`, which conflicts with a read-only bind mount. The custom entrypoint runs the original entrypoint, then copies our config over the generated one and reloads nginx.
- Mounted our nginx config at `/etc/nginx/custom-site.conf` (not directly at the InvoicePlane.conf path) — the custom entrypoint copies it over after the original entrypoint finishes.

- [ ] **Step 2: Commit compose file**

```bash
git add docker-compose.test.yml
git commit -m "feat: add docker-compose.test.yml for integration test stack"
```

---

### Task 4: Create tests/test.sh

**Files:**
- Create: `tests/test.sh`

- [ ] **Step 1: Write the test runner script**

Create `tests/test.sh`:

```bash
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
```

- [ ] **Step 2: Make test.sh executable**

Run: `chmod +x tests/test.sh`

- [ ] **Step 3: Commit test.sh**

```bash
git add tests/test.sh
git commit -m "feat: add integration test runner with 18 curl+jq assertions"
```

---

### Task 5: Create AGENTS.md

**Files:**
- Create: `AGENTS.md`

- [ ] **Step 1: Write AGENTS.md**

Create `AGENTS.md`:

```markdown
# InvoicePlaneAPI — Project Guide

## Overview

Single-file PHP REST API (~379 lines) for InvoicePlane. No framework, no dependencies, just PDO + Bearer token auth. Lives in `api.php`.

## Testing

### Quick Start

```bash
# Full cycle: start, test, tear down
./tests/test.sh

# Step by step
./tests/test.sh --up     # Start stack, wait for health
./tests/test.sh --run    # Run tests against running stack
./tests/test.sh --down   # Tear down and wipe all data
```

### Stack Details

- `docker-compose.test.yml` — MariaDB + InvoicePlane (php-fpm) + Nginx
- Non-persistent volumes: `docker compose -f docker-compose.test.yml down -v` wipes everything
- API base URL: `http://localhost:10080/api/v1`
- Auth: `Bearer test-api-key`
- Seed data: 3 invoices (draft/sent/paid), 2 clients, 1 invoice group, 2 tax rates
- Nginx uses a custom entrypoint (`tests/nginx-entrypoint.sh`) to overlay the API routing config after the image's default entrypoint runs

### Manual Testing

```bash
# Start the stack
docker compose -f docker-compose.test.yml up -d

# Wait for health
curl http://localhost:10080/api/v1/health

# List invoices
curl -H "Authorization: Bearer test-api-key" http://localhost:10080/api/v1/invoices

# Tear down
docker compose -f docker-compose.test.yml down -v
```

### After Changes to api.php

No rebuild needed — `api.php` is bind-mounted read-only into the container. Changes are live after saving the file. Restart php-fpm if needed:

```bash
docker compose -f docker-compose.test.yml restart invoiceplane
```

### After Changes to Seed Data

```bash
docker compose -f docker-compose.test.yml down -v
docker compose -f docker-compose.test.yml up -d
```

### Test Data

| Invoice | ID | Number | Status | Client | Items | Total |
|---------|-----|---------|--------|--------|-------|-------|
| INV001 | 1 | INV001 | draft | Acme Corp | Website Hosting + SSL Certificate | €675.00 |
| INV002 | 2 | INV002 | sent | Goliath BV | Consulting Hours (VAT 21%) + Domain Registration | €1,467.00 |
| INV003 | 3 | INV003 | paid | Acme Corp | Annual Maintenance | €600.00 |
```

- [ ] **Step 2: Commit AGENTS.md**

```bash
git add AGENTS.md
git commit -m "docs: add AGENTS.md with testing infrastructure instructions"
```

---

### Task 6: Smoke Test — Start Stack and Verify

**Files:**
- None (verification only)

- [ ] **Step 1: Pull Docker images and start the stack**

Run: `docker compose -f docker-compose.test.yml up -d`

Expected: All three containers start (mysql, invoiceplane, nginx). MariaDB initializes the database and loads seed.sql.

- [ ] **Step 2: Check container status**

Run: `docker compose -f docker-compose.test.yml ps`

Expected: All containers running. MySQL should show as healthy.

- [ ] **Step 3: Wait for API health and verify**

Run: `./tests/test.sh --up`

Expected: "API is healthy" message. If this fails, check logs with `docker compose -f docker-compose.test.yml logs <service>` and adjust config as needed.

Potential issues to check:
- If nginx returns 404 for all /api/ requests, `PATH_INFO` may not be reaching PHP. Check `fastcgi_split_path_info` in the nginx config.
- If nginx returns the InvoicePlane setup page instead of the API, our config may not be taking effect. Verify the mount at `/etc/nginx/sites-enabled/InvoicePlane.conf`.
- If `api.php` crashes with "Call to undefined function str_starts_with()", the image has PHP 7.x. Fix api.php line 375 to use `strpos($e->getMessage(), 'duplicate invoice number') === 0` instead.
- The `app:invoiceplane` entrypoint may print errors about missing env vars. Check `docker compose ... logs invoiceplane`.

- [ ] **Step 4: Run the integration tests**

Run: `./tests/test.sh --run`

Expected: All 18 tests pass with "Results: 18 passed, 0 failed".

- [ ] **Step 5: Fix any issues found during smoke test**

If tests fail, check:
- `docker compose -f docker-compose.test.yml logs nginx` for nginx errors
- `docker compose -f docker-compose.test.yml logs invoiceplane` for php-fpm errors
- `docker compose -f docker-compose.test.yml logs mysql` for database errors

Adjust `tests/nginx-site.conf`, `docker-compose.test.yml`, or `tests/seed.sql` as needed and re-test.

- [ ] **Step 6: Tear down**

Run: `./tests/test.sh --down`

Expected: All containers removed, volumes wiped.

- [ ] **Step 7: Run full cycle test**

Run: `./tests/test.sh`

Expected: Full cycle (up, test, down) passes all 18 tests.