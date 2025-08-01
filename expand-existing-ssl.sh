#!/bin/bash

# Expand existing Keycloak certificate to include Kong and Konga domains
set -e

echo "🔄 Expanding existing SSL certificate to include new domains..."

# Load environment variables
if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | xargs)
else
    echo "❌ Error: .env file not found!"
    exit 1
fi

echo "📋 Configuration:"
echo "   Keycloak: $KEYCLOAK_HOSTNAME"
echo "   Kong: $KONG_HOSTNAME"
echo "   Konga: $KONGA_HOSTNAME"
echo "   Email: $SSL_EMAIL"

# Check if existing certificate exists
if [ ! -f "./certbot/conf/live/$KEYCLOAK_HOSTNAME/fullchain.pem" ]; then
    echo "❌ No existing certificate found for $KEYCLOAK_HOSTNAME"
    echo "Please run the full setup script instead"
    exit 1
fi

echo "✅ Found existing certificate for $KEYCLOAK_HOSTNAME"

# Start services if not running
echo "🚀 Starting services..."
docker-compose up -d postgres kong-postgres kong-migration
sleep 15
docker-compose up -d keycloak kong konga-prepare konga

echo "⏳ Waiting for services to be ready..."
sleep 30

# Expand the certificate to include new domains
echo "🔐 Expanding certificate to include all domains..."
docker-compose exec certbot certbot certonly \
    --webroot \
    -w /var/www/certbot \
    --email $SSL_EMAIL \
    -d $KEYCLOAK_HOSTNAME \
    -d $KONG_HOSTNAME \
    -d $KONGA_HOSTNAME \
    --expand \
    --agree-tos \
    --no-eff-email

# Start main nginx
echo "🌐 Starting main nginx..."
docker-compose up -d main-nginx

# Reload nginx to use updated certificate
echo "🔄 Reloading nginx..."
docker-compose exec main-nginx nginx -s reload

echo ""
echo "✅ Certificate expanded successfully!"
echo ""
echo "🌐 All domains now available:"
echo "   🔐 Keycloak: https://$KEYCLOAK_HOSTNAME"
echo "   🔐 Keycloak Admin: https://$KEYCLOAK_HOSTNAME/admin"
echo "   🚪 Kong Gateway: https://$KONG_HOSTNAME"
echo "   🚪 Kong Admin API: https://$KONG_HOSTNAME/admin-api"
echo "   📊 Konga Admin: https://$KONGA_HOSTNAME"
echo ""
echo "📋 Next steps:"
echo "1. Add DNS records in Cloudflare for:"
echo "   - $KONG_HOSTNAME"
echo "   - $KONGA_HOSTNAME"
echo "2. Configure Konga with Kong Admin URL: http://kong:8001"
echo "3. Test all services"