#!/bin/sh
set -e

# Ensure data directory exists (needed by the entrypoint's initialize_datadir)
mkdir -p /var/lib/invoiceplane

# Start the original entrypoint in the background.
# It will configure InvoicePlane and start nginx.
/sbin/entrypoint.sh app:nginx &
EP_PID=$!

# Give the entrypoint time to create the nginx config and start nginx
sleep 3

# Overwrite the generated InvoicePlane.conf with our custom config
cp /etc/nginx/custom-site.conf /etc/nginx/sites-enabled/InvoicePlane.conf

# Reload nginx to pick up the new config
nginx -s reload 2>/dev/null || true

# Wait for the original process
wait $EP_PID