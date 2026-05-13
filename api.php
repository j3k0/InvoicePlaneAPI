<?php
declare(strict_types=1);

header('Content-Type: application/json');
header('X-Content-Type-Options: nosniff');

const STATUS_NAMES = [1 => 'draft', 2 => 'sent', 3 => 'viewed', 4 => 'paid'];
const STATUS_IDS   = ['draft' => 1, 'sent' => 2, 'viewed' => 3, 'paid' => 4];

function env(string $key, string $default = ''): string {
    if (isset($_SERVER[$key]) && $_SERVER[$key] !== '') return (string) $_SERVER[$key];
    $v = getenv($key);
    return $v === false ? $default : $v;
}

function jr($data, int $status = 200): void {
    http_response_code($status);
    echo json_encode($data, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    exit;
}

function err(int $status, string $message): void {
    jr(['error' => $message], $status);
}

function check_auth(): void {
    $keys = env('INVOICEPLANE_API_KEY');
    $auth = $_SERVER['HTTP_AUTHORIZATION'] ?? '';
    if ($keys === '' || !preg_match('/^Bearer\s+(.+)$/i', $auth, $m)) err(401, 'unauthorized');
    foreach (explode(',', $keys) as $k) {
        $k = trim($k);
        if ($k !== '' && hash_equals($k, $m[1])) return;
    }
    err(401, 'unauthorized');
}

function db(): PDO {
    static $pdo = null;
    if ($pdo) return $pdo;
    $dsn = sprintf('mysql:host=%s;dbname=%s;charset=utf8mb4',
        env('INVOICEPLANE_DB_HOST', 'localhost'), env('INVOICEPLANE_DB_NAME'));
    $pdo = new PDO($dsn, env('INVOICEPLANE_DB_USER'), env('INVOICEPLANE_DB_PASS'), [
        PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
        PDO::ATTR_EMULATE_PREPARES   => false,
    ]);
    return $pdo;
}

function body_json(): array {
    $raw = file_get_contents('php://input');
    if ($raw === '' || $raw === false) return [];
    $d = json_decode($raw, true);
    if (!is_array($d)) err(400, 'invalid json body');
    return $d;
}

function tax_rate(PDO $db, ?int $rate_id): float {
    static $cache = [];
    if (!$rate_id) return 0.0;
    if (isset($cache[$rate_id])) return $cache[$rate_id];
    try {
        $s = $db->prepare('SELECT tax_rate_percent FROM ip_tax_rates WHERE tax_rate_id = ?');
        $s->execute([$rate_id]);
        $r = $s->fetch();
        return $cache[$rate_id] = $r ? (float) $r['tax_rate_percent'] : 0.0;
    } catch (Throwable $e) {
        return $cache[$rate_id] = 0.0;
    }
}

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

function validate_items_array($items): void {
    if ($items !== null && !is_array($items)) {
        err(400, 'items must be an array');
    }
}

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

function recompute_item(PDO $db, int $item_id): void {
    $s = $db->prepare('SELECT item_quantity, item_price, item_discount_amount, item_tax_rate_id FROM ip_invoice_items WHERE item_id = ?');
    $s->execute([$item_id]);
    $i = $s->fetch();
    if (!$i) return;
    $discount = (float) ($i['item_discount_amount'] ?? 0);
    $subtotal = round((float) $i['item_quantity'] * (float) $i['item_price'] - $discount, 2);
    $tax      = round($subtotal * tax_rate($db, $i['item_tax_rate_id'] ? (int) $i['item_tax_rate_id'] : null) / 100, 2);
    $total    = round($subtotal + $tax, 2);
    $s = $db->prepare('SELECT item_amount_id FROM ip_invoice_item_amounts WHERE item_id = ?');
    $s->execute([$item_id]);
    if ($s->fetch()) {
        $s = $db->prepare('UPDATE ip_invoice_item_amounts SET item_subtotal=?, item_tax_total=?, item_discount=?, item_total=? WHERE item_id=?');
        $s->execute([$subtotal, $tax, $discount, $total, $item_id]);
    } else {
        $s = $db->prepare('INSERT INTO ip_invoice_item_amounts (item_id, item_subtotal, item_tax_total, item_discount, item_total) VALUES (?, ?, ?, ?, ?)');
        $s->execute([$item_id, $subtotal, $tax, $discount, $total]);
    }
}

function recompute_invoice(PDO $db, int $invoice_id): void {
    $s = $db->prepare('SELECT invoice_amount_id FROM ip_invoice_amounts WHERE invoice_id = ?');
    $s->execute([$invoice_id]);
    if (!$s->fetch()) {
        $s = $db->prepare('INSERT INTO ip_invoice_amounts (invoice_id) VALUES (?)');
        $s->execute([$invoice_id]);
    }
    $s = $db->prepare('SELECT COALESCE(SUM(ia.item_subtotal),0) AS sub, COALESCE(SUM(ia.item_tax_total),0) AS tax FROM ip_invoice_item_amounts ia JOIN ip_invoice_items ii ON ia.item_id=ii.item_id WHERE ii.invoice_id=?');
    $s->execute([$invoice_id]);
    $r = $s->fetch();
    $s = $db->prepare('UPDATE ip_invoice_amounts SET invoice_item_subtotal=?, invoice_item_tax_total=?, invoice_total = ? + ? + invoice_tax_total, invoice_balance = (? + ? + invoice_tax_total) - invoice_paid WHERE invoice_id=?');
    $sub = (float) $r['sub']; $tax = (float) $r['tax'];
    $s->execute([$sub, $tax, $sub, $tax, $sub, $tax, $invoice_id]);
}

function generate_invoice_number(PDO $db, int $group_id, string $date): string {
    $s = $db->prepare('SELECT invoice_group_identifier_format, invoice_group_next_id, invoice_group_left_pad FROM ip_invoice_groups WHERE invoice_group_id=?');
    $s->execute([$group_id]);
    $g = $s->fetch();
    if (!$g) throw new RuntimeException('invoice group not found');
    $padded = str_pad((string) (int) $g['invoice_group_next_id'], (int) $g['invoice_group_left_pad'], '0', STR_PAD_LEFT);
    $dt = new DateTimeImmutable($date);
    $number = strtr($g['invoice_group_identifier_format'], [
        '{{{year}}}'  => $dt->format('Y'),
        '{{{month}}}' => $dt->format('m'),
        '{{{day}}}'   => $dt->format('d'),
        '{{{id}}}'    => $padded,
    ]);
    $s = $db->prepare('SELECT COUNT(*) FROM ip_invoices WHERE invoice_number = ?');
    $s->execute([$number]);
    if ((int) $s->fetchColumn() > 0) {
        throw new RuntimeException('duplicate invoice number: ' . $number);
    }
    $s = $db->prepare('UPDATE ip_invoice_groups SET invoice_group_next_id = invoice_group_next_id + 1 WHERE invoice_group_id=?');
    $s->execute([$group_id]);
    return $number;
}

function fetch_invoice(PDO $db, int $id): ?array {
    $s = $db->prepare('SELECT i.*, c.client_name, c.client_email, c.client_address_1, c.client_address_2, c.client_city, c.client_state, c.client_zip, c.client_country FROM ip_invoices i LEFT JOIN ip_clients c ON i.client_id=c.client_id WHERE i.invoice_id=?');
    $s->execute([$id]);
    $inv = $s->fetch();
    if (!$inv) return null;
    $s = $db->prepare('SELECT ii.*, COALESCE(ia.item_subtotal,0) sub, COALESCE(ia.item_tax_total,0) tax, COALESCE(ia.item_discount,0) disc, COALESCE(ia.item_total,0) tot FROM ip_invoice_items ii LEFT JOIN ip_invoice_item_amounts ia ON ii.item_id=ia.item_id WHERE ii.invoice_id=? ORDER BY ii.item_order, ii.item_id');
    $s->execute([$id]);
    $items = $s->fetchAll();
    $s = $db->prepare('SELECT * FROM ip_invoice_amounts WHERE invoice_id=?');
    $s->execute([$id]);
    $a = $s->fetch() ?: ['invoice_total' => 0, 'invoice_paid' => 0, 'invoice_balance' => 0];
    $address = implode(', ', array_filter([
        trim(($inv['client_address_1'] ?? '') . ' ' . ($inv['client_address_2'] ?? '')),
        trim(($inv['client_city'] ?? '') . ' ' . ($inv['client_zip'] ?? '')),
        $inv['client_state'] ?? '',
        $inv['client_country'] ?? '',
    ], fn($x) => $x !== '' && $x !== null));
    $scheme = $_SERVER['REQUEST_SCHEME'] ?? (($_SERVER['HTTPS'] ?? '') === 'on' ? 'https' : 'http');
    $base = rtrim(env('INVOICEPLANE_BASE_URL', "$scheme://{$_SERVER['HTTP_HOST']}"), '/');
    return [
        'id'           => (int) $inv['invoice_id'],
        'number'       => $inv['invoice_number'],
        'date'         => $inv['invoice_date_created'],
        'due_date'     => $inv['invoice_date_due'],
        'status'       => STATUS_NAMES[(int) $inv['invoice_status_id']] ?? 'unknown',
        'is_read_only' => (int) ($inv['is_read_only'] ?? 0),
        'client'       => [
            'id'      => (int) $inv['client_id'],
            'name'    => $inv['client_name'],
            'address' => $address,
            'email'   => $inv['client_email'],
        ],
        'items' => array_map(fn($it) => [
            'id'          => (int) $it['item_id'],
            'name'        => $it['item_name'],
            'description' => $it['item_description'],
            'quantity'    => (float) $it['item_quantity'],
            'unit'        => $it['item_product_unit'],
            'price'       => (float) $it['item_price'],
            'subtotal'    => (float) $it['sub'],
            'tax_total'   => (float) $it['tax'],
            'discount'    => (float) $it['disc'],
            'total'       => (float) $it['tot'],
            'item_date'   => $it['item_date'],
            'item_order'  => (int) $it['item_order'],
        ], $items),
        'amounts' => [
            'total'   => (float) $a['invoice_total'],
            'paid'    => (float) $a['invoice_paid'],
            'balance' => (float) $a['invoice_balance'],
        ],
        'guest_url' => $base ? $base . '/index.php/guest/view/invoice/' . $inv['invoice_url_key'] : null,
    ];
}

$path   = $_SERVER['PATH_INFO'] ?? parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/';
$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
$parts  = array_values(array_filter(explode('/', $path), fn($p) => $p !== ''));
if (($parts[0] ?? '') === 'api') array_shift($parts);
if (($parts[0] ?? '') !== 'v1') err(404, 'not found');

if (count($parts) === 2 && $parts[1] === 'health' && $method === 'GET') {
    try { db()->query('SELECT 1'); jr(['status' => 'ok', 'db' => 'connected']); }
    catch (Throwable $e) { jr(['status' => 'error', 'db' => 'disconnected'], 503); }
}

check_auth();

try {
    $db = db();

    if (count($parts) === 2 && $parts[1] === 'invoices' && $method === 'GET') {
        $where = []; $params = [];
        if (!empty($_GET['client_id'])) { $where[] = 'i.client_id = ?'; $params[] = (int) $_GET['client_id']; }
        if (!empty($_GET['q'])) {
            $where[] = "EXISTS (SELECT 1 FROM ip_invoice_items ii WHERE ii.invoice_id=i.invoice_id AND (ii.item_name LIKE CONCAT('%',?,'%') OR ii.item_description LIKE CONCAT('%',?,'%')))";
            $params[] = $_GET['q']; $params[] = $_GET['q'];
        }
        $status = $_GET['status'] ?? '';
        if ($status === 'all') {
            // no filter
        } elseif ($status !== '') {
            $ids = [];
            foreach (explode(',', $status) as $n) { $n = trim($n); if (isset(STATUS_IDS[$n])) $ids[] = STATUS_IDS[$n]; }
            if ($ids) {
                $where[] = 'i.invoice_status_id IN (' . implode(',', array_fill(0, count($ids), '?')) . ')';
                $params = array_merge($params, $ids);
            }
        } else {
            $where[] = 'i.invoice_status_id != 1';
        }
        $w = $where ? 'WHERE ' . implode(' AND ', $where) : '';
        $order = match ($_GET['order'] ?? 'date_desc') {
            'date_asc'    => 'i.invoice_date_created ASC',
            'amount_desc' => 'amt.invoice_total DESC',
            default       => 'i.invoice_date_created DESC',
        };
        $limit  = max(1, min(100, (int) ($_GET['limit'] ?? 25)));
        $offset = max(0, (int) ($_GET['offset'] ?? 0));

        $cs = $db->prepare("SELECT COUNT(*) FROM ip_invoices i $w");
        $cs->execute($params);
        $total = (int) $cs->fetchColumn();

        $sql = "SELECT i.invoice_id, i.invoice_number, i.invoice_date_created, i.invoice_date_due, i.invoice_status_id, i.client_id, c.client_name,
                       COALESCE(amt.invoice_total, 0) AS total,
                       (SELECT GROUP_CONCAT(item_name ORDER BY item_order SEPARATOR ', ') FROM ip_invoice_items WHERE invoice_id=i.invoice_id) AS item_summary
                FROM ip_invoices i
                LEFT JOIN ip_clients c ON i.client_id=c.client_id
                LEFT JOIN ip_invoice_amounts amt ON i.invoice_id=amt.invoice_id
                $w ORDER BY $order LIMIT $limit OFFSET $offset";
        $s = $db->prepare($sql);
        $s->execute($params);
        $rows = $s->fetchAll();
        jr([
            'total' => $total,
            'invoices' => array_map(fn($r) => [
                'id'           => (int) $r['invoice_id'],
                'number'       => $r['invoice_number'],
                'date'         => $r['invoice_date_created'],
                'due_date'     => $r['invoice_date_due'],
                'status'       => STATUS_NAMES[(int) $r['invoice_status_id']] ?? 'unknown',
                'client_id'    => (int) $r['client_id'],
                'client_name'  => $r['client_name'],
                'total'        => (float) $r['total'],
                'currency'     => env('INVOICEPLANE_CURRENCY', 'EUR'),
                'item_summary' => $r['item_summary'],
            ], $rows),
        ]);
    }

    if (count($parts) >= 3 && $parts[1] === 'invoices' && ctype_digit($parts[2])) {
        $id = (int) $parts[2];

        if (count($parts) === 3 && $method === 'GET') {
            $inv = fetch_invoice($db, $id);
            if (!$inv) err(404, 'invoice not found');
            jr($inv);
        }

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

        if (count($parts) === 4 && $parts[3] === 'status' && $method === 'POST') {
            $body = body_json();
            $name = $body['status'] ?? '';
            if (!isset(STATUS_IDS[$name])) err(400, 'invalid status');
            $new = STATUS_IDS[$name];
            $s = $db->prepare('SELECT invoice_status_id FROM ip_invoices WHERE invoice_id=?');
            $s->execute([$id]);
            $row = $s->fetch();
            if (!$row) err(404, 'invoice not found');
            $cur = (int) $row['invoice_status_id'];
            if ($new < $cur) err(409, 'cannot transition backwards');
            $s = $db->prepare('UPDATE ip_invoices SET invoice_status_id=?, is_read_only=?, invoice_date_modified=NOW() WHERE invoice_id=?');
            $s->execute([$new, $new > 1 ? 1 : 0, $id]);
            jr(['status' => $name]);
        }
    }

    err(404, 'not found');
} catch (Throwable $e) {
    error_log('InvoicePlaneAPI error: ' . $e->getMessage());
    if (str_starts_with($e->getMessage(), 'duplicate invoice number')) {
        err(409, $e->getMessage());
    }
    err(500, 'internal error');
}
