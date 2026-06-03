# InvoicePlaneAPI — Project Guide

When using /learn, read `.opencode/learn.md` first

## Overview

Single-file PHP REST API (~379 lines) for InvoicePlane. No framework, no dependencies, just PDO + Bearer token auth. Lives in `api.php`.

## Architecture Quirks

- `api.php:185` routes via `$_SERVER['PATH_INFO']` — nginx must include `fastcgi_split_path_info` or all endpoints 404
- `env()` (line 10-14) reads `$_SERVER` first, then `getenv()`. PHP-FPM's `clear_env` defaults to on, so env vars must be passed as `fastcgi_param` in nginx, not just as Docker environment variables
- Default `GET /api/v1/invoices` excludes drafts (`invoice_status_id != 1`). Pass `?status=all` to include them. Search on draft-only items returns 0 results without `status=all`
- Invoice statuses are hardcoded constants (1=draft, 2=sent, 3=viewed, 4=paid), not in the database
- `str_starts_with()` on line 375 requires PHP 8.0+ — will fatal error on PHP 7.x
- Invoice number generation atomically increments `ip_invoice_groups.invoice_group_next_id` and expands `{{{year}}}`, `{{{month}}}`, `{{{day}}}`, `{{{id}}}` tokens from the group format
- Security headers (HSTS, Cache-Control, Referrer-Policy) are set on every response
- Health endpoint now returns `{"ok": true}` (no longer leaks DB status)
- Audit logging goes to PHP error log with `InvoicePlaneAPI audit:` prefix
- LIKE wildcards `%` and `_` in search queries are escaped to prevent injection
- API keys shorter than 32 characters trigger a warning
- Mutation endpoints require `Content-Type: application/json` (return 415 if missing)
- Empty PATCH `{}` body returns 400
- Wrong HTTP methods on valid paths return 405 with Allow header
- Rate limiting is done at the nginx level (not in api.php)

## Docker Image Quirks (jeko/invoiceplane:1.7.1-1)

- Entry point `/sbin/entrypoint.sh` `chmod`s `/var/lib/invoiceplane` at startup — container exits if dir missing. Anonymous volume `- /var/lib/invoiceplane` or `mkdir -p` in custom entrypoint required
- Image creates `/etc/nginx/sites-enabled/InvoicePlane.conf` with `server_name localhost` and `chmod`s it — cannot bind-mount read-only at that path. Custom entrypoint must copy config after original entrypoint runs, then `nginx -s reload`
- `INVOICEPLANE_PHP_FPM_HOST` and `INVOICEPLANE_PHP_FPM_PORT` env vars required on nginx service even when using custom nginx config
- `app:invoiceplane` starts php-fpm, `app:nginx` starts nginx frontend — both from the same image, separate containers

## Testing

**No task is done until `./tests/test.sh` passes.** If you add or change an API endpoint, add a corresponding test case to `tests/test.sh` and add seed data to `tests/seed.sql` if needed. If you change `api.php` or `docker-compose.test.yml`, run `./tests/test.sh` to verify nothing broke.

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