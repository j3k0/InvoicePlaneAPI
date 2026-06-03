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
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

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
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS ip_invoice_groups (
    invoice_group_id INT(11) NOT NULL AUTO_INCREMENT,
    invoice_group_name TEXT NOT NULL DEFAULT '',
    invoice_group_identifier_format VARCHAR(255) NOT NULL,
    invoice_group_next_id INT(11) NOT NULL,
    invoice_group_left_pad INT(2) NOT NULL DEFAULT '0',
    PRIMARY KEY (invoice_group_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS ip_tax_rates (
    tax_rate_id INT(11) NOT NULL AUTO_INCREMENT,
    tax_rate_name VARCHAR(255) NOT NULL,
    tax_rate_percent DECIMAL(10,2) NOT NULL,
    PRIMARY KEY (tax_rate_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

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
    invoice_number VARCHAR(100) NULL UNIQUE,
    invoice_terms LONGTEXT NOT NULL,
    invoice_url_key CHAR(32) NOT NULL,
    payment_method INT NOT NULL DEFAULT '0',
    invoice_password VARCHAR(90) NULL,
    invoice_discount_amount DECIMAL(20,2) NULL,
    invoice_discount_percent DECIMAL(20,2) NULL,
    PRIMARY KEY (invoice_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

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
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS ip_invoice_item_amounts (
    item_amount_id INT(11) NOT NULL AUTO_INCREMENT,
    item_id INT(11) NOT NULL,
    item_subtotal DECIMAL(20,2) NOT NULL,
    item_tax_total DECIMAL(20,2) NOT NULL,
    item_discount DECIMAL(20,2) NULL,
    item_total DECIMAL(20,2) NOT NULL,
    PRIMARY KEY (item_amount_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

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
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

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