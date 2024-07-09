cd /var/www
docker compose build
docker compose up -d db --wait && docker compose up -d mautic_web --wait

echo "## Wait for basic-mautic_web-1 container to be fully running"
while ! docker exec basic-mautic_web-1 sh -c 'echo "Container is running"'; do
    echo "### Waiting for basic-mautic_web-1 to be fully running..."
    sleep 2
done

echo "## Check if Mautic is installed"
if docker compose exec -T mautic_web test -f /var/www/html/config/local.php && docker compose exec -T mautic_web grep -q "site_url" /var/www/html/config/local.php; then
    echo "## Mautic is installed already."
else
    # Check if the container exists and is running
    if docker ps --filter "name=basic-mautic_worker-1" --filter "status=running" -q | grep -q .; then
        echo "Stopping basic-mautic_worker-1 to avoid https://github.com/mautic/docker-mautic/issues/270"
        docker stop basic-mautic_worker-1
        echo "## Ensure the worker is stopped before installing Mautic"
        while docker ps -q --filter name=basic-mautic_worker-1 | grep -q .; do
            echo "### Waiting for basic-mautic_worker-1 to stop..."
            sleep 2
        done
    else
        echo "Container basic-mautic_worker-1 does not exist or is not running."
    fi
    echo "## Installing Mautic..."
    docker compose exec -T -u www-data -w /var/www/html mautic_web php ./bin/console mautic:install --force --admin_email {{EMAIL_ADDRESS}} --admin_password {{MAUTIC_PASSWORD}} http://{{IP_ADDRESS}}:{{PORT}}
fi

echo "## Starting all the containers"
docker compose up -d

DOMAIN="{{DOMAIN_NAME}}"

if [[ "$DOMAIN" == *"DOMAIN_NAME"* ]]; then
    echo "The DOMAIN variable is not set yet."
    exit 0
fi

DROPLET_IP=$(curl -s http://icanhazip.com)

echo "## Checking if $DOMAIN points to this DO droplet..."
DOMAIN_IP=$(dig +short $DOMAIN)
if [ "$DOMAIN_IP" != "$DROPLET_IP" ]; then
    echo "## $DOMAIN does not point to this droplet IP ($DROPLET_IP). Exiting..."
    exit 1
fi

echo "## $DOMAIN is available and points to this droplet. Nginx configuration..."

SOURCE_PATH="/var/www/nginx-virtual-host-$DOMAIN"
TARGET_PATH="/etc/nginx/sites-enabled/nginx-virtual-host-$DOMAIN"

# Remove the existing symlink if it exists
if [ -L "$TARGET_PATH" ]; then
    rm $TARGET_PATH
    echo "Existing symlink for $DOMAIN configuration removed."
fi

# Create a new symlink
ln -s $SOURCE_PATH $TARGET_PATH
echo "Symlink created for $DOMAIN configuration."

# Check if Nginx is running and reload to apply changes
if ! pgrep -x nginx > /dev/null; then
    echo "Nginx is not running, starting Nginx..."
    systemctl start nginx
else
    echo "Reloading Nginx to apply new configuration."
    nginx -s reload
fi

echo "## Proceeding with Let's Encrypt configuration..."

if [ ! -f "/etc/letsencrypt/live/$DOMAIN/README" ]; then
    echo "## Configuring Let's Encrypt for $DOMAIN..."

    # Stop Nginx to free up port 80 for Certbot
    systemctl stop nginx

    # Use Certbot to obtain a certificate
    certbot certonly --standalone -d $DOMAIN --non-interactive --agree-tos -m {{EMAIL_ADDRESS}}

    # Start Nginx again
    systemctl start nginx

    echo "## Let's Encrypt configured for $DOMAIN"
else
    echo "## Let's Encrypt is already configured for $DOMAIN"
fi

# Check if the cron job for renewal is already set
if ! crontab -l | grep -q 'certbot renew'; then
    echo "## Setting up cron job for Let's Encrypt certificate renewal..."
    (crontab -l 2>/dev/null; echo "0 0 1 * * certbot renew --post-hook 'systemctl reload nginx'") | crontab -
else
    echo "## Cron job for Let's Encrypt certificate renewal is already set"
fi

echo "## Script execution completed"
