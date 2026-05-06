# InvoicePlaneAPI

A thin standalone REST API for [InvoicePlane](https://github.com/InvoicePlane/InvoicePlane) — programmatic access to invoices without browser automation or CSV exports.

Single file, zero dependencies, ~200 lines of PHP with PDO.

## Motivation

InvoicePlane has no API. Everything is form submissions and AJAX-loaded HTML modals behind session auth. Automated workflows (reconciliation, invoice copies, cron-triggered creation) need reliable programmatic access. This fills that gap.

## Quick Install

```bash
# Drop api.php into InvoicePlane's web root
cp api.php /srv/docker/invoiceplane/html/api/index.php
```

Then add the Nginx location block (see below).

## Requirements

- PHP 7.2+ with PDO MySQL
- Access to InvoicePlane's MySQL database
- No Composer, no framework, no dependencies

## Environment Variables

| Variable | Description |
|----------|-------------|
| `INVOICEPLANE_API_KEY` | Comma-separated API keys (plain text) |
| `INVOICEPLANE_DB_HOST` | MySQL host (e.g., `mysql`) |
| `INVOICEPLANE_DB_NAME` | Database name (e.g., `invoiceplane_db`) |
| `INVOICEPLANE_DB_USER` | Database user |
| `INVOICEPLANE_DB_PASS` | Database password |

## Authentication

```
Authorization: Bearer <key>
```

Keys are plain-text, comma-separated in `INVOICEPLANE_API_KEY`. Rotation is trivial: add a new key → deploy → remove the old one.

Example: `INVOICEPLANE_API_KEY="key1,key2,key3"` — any of these keys will authenticate.

## Nginx Configuration

```nginx
# Route /api/ to the standalone PHP file
location /api/ {
    rewrite ^/api/(.*) /api/index.php/$1 last;
}

location /api/index.php {
    fastcgi_pass invoiceplane:9000;
    fastcgi_param INVOICEPLANE_API_KEY "your-key-here";
    fastcgi_param INVOICEPLANE_DB_HOST "mysql";
    fastcgi_param INVOICEPLANE_DB_NAME "invoiceplane_db";
    fastcgi_param INVOICEPLANE_DB_USER "invoiceplane";
    fastcgi_param INVOICEPLANE_DB_PASS "password";
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME /var/www/html/api/index.php;
}
```

## Docker Installation

Add a bind mount to your `docker-compose.yml`:

```yaml
invoiceplane:
  volumes:
    - ./api/index.php:/var/www/html/api/index.php:ro
```

Add the Nginx block above to your nginx config, and the env vars via `environment:` or `env_file:` on the `invoiceplane` service.

## API Reference

Base URL: `https://your-domain/api/v1`

### `GET /api/v1/health`
No auth. Returns `{"status":"ok","db":"connected"}`.

### `GET /api/v1/invoices`
List/filter invoices.

| Query param | Description |
|-------------|-------------|
| `client_id` | Filter by client |
| `q` | Search `item_name` and `item_description` |
| `status` | `draft,sent,viewed,paid` or `all` (default: exclude drafts) |
| `order` | `date_desc` (default), `date_asc`, `amount_desc` |
| `limit` | Max results (default 25, max 100) |
| `offset` | Pagination |

Example: `GET /api/v1/invoices?client_id=5&q=Wordpress&status=paid&limit=1`

### `GET /api/v1/invoices/{id}`
Full invoice with client, items, and amounts.

### `POST /api/v1/invoices/{id}/copy`
Clone an invoice as a new draft. Optional body to override dates and item values:

```json
{
  "date": "2026-05-06",
  "due_date": "2026-06-05",
  "items": [
    {
      "item_id": 456,
      "quantity": 384,
      "description": "Updated description"
    }
  ]
}
```

Returns the new draft invoice ID and number.

### `PATCH /api/v1/invoices/{id}`
Update a draft invoice's date, due date, or items. Recomputes amounts.

### `POST /api/v1/invoices/{id}/status`
Set invoice status. Body: `{"status": "sent"}`. Valid transitions: draft → sent → viewed → paid.

## Full Specification

See [SPEC.md](SPEC.md) for the complete API specification with verified database schema, SQL patterns, and security considerations.

## Security

- Timing-safe API key comparison (`hash_equals`)
- PDO prepared statements for all queries — no SQL injection
- `X-Content-Type-Options: nosniff` on all responses
- Health endpoint is the only unauthenticated route

## License

MIT
