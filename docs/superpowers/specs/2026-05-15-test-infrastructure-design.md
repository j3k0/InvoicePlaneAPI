# Test Infrastructure Design

> **For agentic workers:** This spec defines the test infrastructure for InvoicePlaneAPI. Use `superpowers:writing-plans` to create the implementation plan.

**Goal:** Spin up a disposable InvoicePlane instance via Docker Compose to run automated integration tests against the InvoicePlaneAPI (`api.php`).

**Architecture:** Three containers — MariaDB, InvoicePlane php-fpm, InvoicePlane nginx — all non-persistent (anonymous volumes). Seed SQL loaded via `/docker-entrypoint-initdb.d/`. Test runner is a Bash+curl+jq script.

**Tech Stack:** Docker Compose, MariaDB 10, jeko/invoiceplane:1.7.1-1, Bash, curl, jq

---

## File Layout

```
InvoicePlaneAPI/
├── api.php                      # existing (unchanged)
├── README.md
├── SPEC.md
├── docker-compose.test.yml      # NEW — test stack definition
├── tests/
│   ├── test.sh                  # NEW — test runner (curl + jq)
│   ├── seed.sql                 # NEW — schema + deterministic test data
│   └── nginx-site.conf          # NEW — nginx config with /api/ block
├── AGENTS.md                    # NEW
└── docs/
```

## Docker Compose Stack

Three services, all non-persistent:

| Service      | Image                      | Role                                        |
|-------------|---------------------------|---------------------------------------------|
| mysql       | mariadb:10                 | Database with auto-seeded test data         |
| invoiceplane| jeko/invoiceplane:1.7.1-1 | PHP-FPM running `app:invoiceplane`          |
| nginx       | jeko/invoiceplane:1.7.1-1 | Nginx frontend running `app:nginx` + API route |

- **mysql**: Env vars `MYSQL_ROOT_PASSWORD`, `MYSQL_DATABASE=invoiceplane_db`, `MYSQL_USER=invoiceplane`, `MYSQL_PASSWORD=password`. Mount `seed.sql` into `/docker-entrypoint-initdb.d/`. Healthcheck `mysqladmin ping`. No published ports.
- **invoiceplane**: Command `app:invoiceplane`. Env vars: `INVOICEPLANE_FQDN=localhost`, `INVOICEPLANE_TIMEZONE=UTC`, `INVOICEPLANE_URL=http://localhost:10080`, `DB_HOST=mysql`, `DB_NAME=invoiceplane_db`, `DB_USER=invoiceplane`, `DB_PASS=password`, `INVOICEPLANE_API_KEY=test-api-key`, `INVOICEPLANE_DB_HOST=mysql`, `INVOICEPLANE_DB_NAME=invoiceplane_db`, `INVOICEPLANE_DB_USER=invoiceplane`, `INVOICEPLANE_DB_PASS=password`. Bind-mount `./api.php:/var/www/html/api/index.php:ro`. Depends on mysql (healthy).
- **nginx**: Command `app:nginx`. Env vars: `INVOICEPLANE_PHP_FPM_HOST=invoiceplane`, `INVOICEPLANE_PHP_FPM_PORT=9000`. Port `10080:80`. `volumes_from: invoiceplane`. Custom entrypoint (`tests/nginx-entrypoint.sh`) that runs the original entrypoint, then overwrites the generated InvoicePlane.conf with our API-aware config and reloads nginx. `volumes` mount the custom nginx-site.conf at `/etc/nginx/custom-site.conf` (read-only) and the entrypoint script at `/usr/local/bin/override-entrypoint.sh` (read-only). Depends on invoiceplane.
- All volumes are anonymous. `docker compose -f docker-compose.test.yml down -v` wipes everything.

## Nginx Config (`tests/nginx-site.conf`)

Mounted at `/etc/nginx/sites-enabled/InvoicePlane.conf` to override the image's auto-generated config. Uses `server_name localhost` to match `Host` header. Includes `fastcgi_split_path_info` and `PATH_INFO` for API routing.

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

## Seed SQL (`tests/seed.sql`)

Creates only the tables the API queries (matching SPEC.md schema exactly):
`ip_users`, `ip_clients`, `ip_invoice_groups`, `ip_tax_rates`, `ip_invoices`, `ip_invoice_items`, `ip_invoice_item_amounts`, `ip_invoice_amounts`.

Uses `CREATE TABLE IF NOT EXISTS` for idempotency.

### Test Data

| Invoice | ID | Number | Status       | Client      | Items                                  | Total     |
|---------|-----|---------|-------------|-------------|----------------------------------------|-----------|
| Draft   | 1   | INV001  | draft (1)   | Acme Corp   | Website Hosting + SSL Certificate      | €675.00   |
| Sent    | 2   | INV002  | sent (2)    | Goliath BV  | Consulting Hours (VAT 21%) + Domain Reg | €1,467.00 |
| Paid    | 3   | INV003  | paid (4)    | Acme Corp   | Annual Maintenance                     | €600.00   |

Reference data: 1 admin user (id=1), 2 clients, 1 invoice group (format `{{{year}}}{{{month}}}{{{day}}}{{{id}}}`, left_pad=3, next_id=4), 2 tax rates (0% and 21%).

## Test Runner (`tests/test.sh`)

Usage: `./tests/test.sh [--up|--down|--run]`
- Default: full cycle — up, wait, test, down.
- `--up`: start stack, wait for health.
- `--down`: tear down and wipe volumes.
- `--run`: run tests against running stack.

Wait logic: Polls `GET /api/v1/health` every 2s, up to 30 attempts (60s).

### Test Cases

| #  | Test                        | Method | URL                          | Asserts                                      |
|----|-----------------------------|--------|------------------------------|-----------------------------------------------|
| 1  | Health OK                   | GET    | /api/v1/health               | 200, status=ok, db=connected                  |
| 2  | Auth: no key                | GET    | /api/v1/invoices             | 401                                            |
| 3  | Auth: wrong key             | GET    | /api/v1/invoices             | 401                                            |
| 4  | List invoices default       | GET    | /api/v1/invoices             | 200, 2 results (excludes drafts)               |
| 5  | List all statuses           | GET    | /api/v1/invoices?status=all  | 200, 3 results                                  |
| 6  | Filter by status=paid      | GET    | /api/v1/invoices?status=paid  | 200, 1 result                                   |
| 7  | Filter by client_id=1      | GET    | /api/v1/invoices?client_id=1  | 200, 1 result (Acme, non-draft)                 |
| 8  | Search q=Consulting         | GET    | /api/v1/invoices?q=Consulting | Matches "Consulting Hours"                      |
| 9  | Sort amount_desc            | GET    | /api/v1/invoices?order=amount_desc | First has highest total                |
| 10 | Pagination                  | GET    | /api/v1/invoices?limit=1&offset=1 | 1 result, offset applied               |
| 11 | Get single invoice          | GET    | /api/v1/invoices/2           | 200, full detail with client, items, amounts   |
| 12 | 404 unknown invoice         | GET    | /api/v1/invoices/9999        | 404                                            |
| 13 | Copy invoice                | POST   | /api/v1/invoices/2/copy      | 201, new draft ID                              |
| 14 | Patch draft date            | PATCH  | /api/v1/invoices/1           | 200, date updated                              |
| 15 | Patch draft item qty        | PATCH  | /api/v1/invoices/1           | 200, qty updated, amounts recomputed           |
| 16 | Status draft→sent           | POST   | /api/v1/invoices/1/status    | 200, status=sent                               |
| 17 | Backwards transition        | POST   | /api/v1/invoices/2/status    | 409                                            |
| 18 | Patch non-draft             | PATCH  | /api/v1/invoices/2           | 409                                            |

Mutating tests (13, 15, 16) are fine because each `--up` starts fresh from seed.sql.

## AGENTS.md Summary

- `docker compose -f docker-compose.test.yml up -d` — start stack
- `./tests/test.sh` — full cycle: start, test, tear down
- `./tests/test.sh --up` / `--down` / `--run` — individual steps
- `docker compose -f docker-compose.test.yml down -v` — clean wipe
- API at `http://localhost:10080/api/v1`, auth `Bearer test-api-key`
- Changes to `api.php` are live (bind-mounted); restart php-fpm if needed