#!/bin/bash

echo "==============================="
echo "   WordPress Stack Installer   "
echo "==============================="

# Setup Questions
read -p "Enter domain (e.g. site.local): " DOMAIN
read -p "WP Site Title: " TITLE
read -p "WP Admin User [admin]: " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}
read -s -p "WP Admin Pass: " ADMIN_PASS
echo ""

# Config & Passwords
DB_ROOT_PASSWORD=$(openssl rand -base64 16 | tr -d '/+=')
DB_PASSWORD=$(openssl rand -base64 16 | tr -d '/+=')

cp .env.dist .env
sed -i 's/\r//' .env
sed -i "s/^DOMAIN_NAME=.*/DOMAIN_NAME=$DOMAIN/" .env
sed -i "s/^DB_ROOT_PASSWORD=.*/DB_ROOT_PASSWORD=$DB_ROOT_PASSWORD/" .env
sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=$DB_PASSWORD/" .env
export $(grep -v '^#' .env | xargs)

# SSL & Config
mkdir -p wordpress db_data
sed "s/{{DOMAIN}}/$DOMAIN/g" nginx/ssl/domain.ext.dist > "nginx/ssl/$DOMAIN.ext"
sed "s/{{DOMAIN}}/$DOMAIN/g" nginx/conf.d/default.conf.dist > "nginx/conf.d/default.conf"

if [ ! -f "nginx/ssl/rootCA.pem" ]; then
    openssl genrsa -out nginx/ssl/rootCA.key 2048
    openssl req -x509 -new -nodes -key nginx/ssl/rootCA.key -sha256 -days 3650 -out nginx/ssl/rootCA.pem -subj "/C=PL/ST=Local/O=Dev/CN=LocalDevRootCA"
fi
openssl genrsa -out "nginx/ssl/$DOMAIN.key" 2048
openssl req -new -key "nginx/ssl/$DOMAIN.key" -out "nginx/ssl/$DOMAIN.csr" -subj "/C=PL/ST=Local/O=Dev/CN=$DOMAIN"
openssl x509 -req -in "nginx/ssl/$DOMAIN.csr" -CA nginx/ssl/rootCA.pem -CAkey nginx/ssl/rootCA.key -CAcreateserial -out "nginx/ssl/$DOMAIN.crt" -days 825 -sha256 -extfile "nginx/ssl/$DOMAIN.ext"

# Start Infrastructure
docker-compose up -d mysql wordpress nginx

# Wait for MySQL
echo "Waiting for MySQL to be ready..."
until docker-compose exec -e MYSQL_PWD="$DB_ROOT_PASSWORD" mysql mysqladmin ping -h"localhost" -u"root" --silent; do
    echo "Waiting..."
    sleep 2
done

# WP-CLI - Setup
# memory_limit=512M - prevents memory errors
echo "Creating config..."
docker-compose run --rm --entrypoint "php -d memory_limit=512M /usr/local/bin/wp" wpcli config create \
    --dbname="$DB_NAME" \
    --dbuser="$DB_USER" \
    --dbpass="$DB_PASSWORD" \
    --dbhost="mysql" \
    --force

echo "Installing..."
docker-compose run --rm wpcli wp core install \
    --url="https://$DOMAIN" \
    --title="$TITLE" \
    --admin_user="$ADMIN_USER" \
    --admin_password="$ADMIN_PASS" \
    --admin_email="admin@$DOMAIN" \
    --skip-email

# FIX PERMISSIONS
echo "Fixing permissions..."
docker-compose exec -u root wordpress chown -R www-data:www-data /var/www/html
docker-compose exec -u root nginx chmod -R 755 /var/www/html

echo "================================================="
echo "DONE! Visit: https://$DOMAIN"
echo "================================================="