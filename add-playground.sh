#!/bin/bash

# Fix playground SSL certificate expansion
set -e

echo "🔧 Fixing SSL certificate expansion for playground..."

# Load environment variables
if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | xargs)
else
    echo "❌ Error: .env file not found!"
    exit 1
fi

echo "📋 Current configuration:"
echo "   Keycloak: $KEYCLOAK_HOSTNAME"
echo "   Kong: $KONG_HOSTNAME"
echo "   Konga: $KONGA_HOSTNAME"
echo "   Playground: $PLAYGROUND_HOSTNAME"

# Check if playground is running
echo "🔍 Checking playground status..."
docker compose ps fhir-playground

# Expand certificate using direct certbot run (not exec)
echo "🔐 Expanding SSL certificate using direct certbot..."
docker run --rm \
    --network $(basename $(pwd))_proxy-network \
    -v $(pwd)/certbot/conf:/etc/letsencrypt \
    -v $(pwd)/certbot/www:/var/www/certbot \
    certbot/certbot \
    certonly --webroot \
    -w /var/www/certbot \
    --email $SSL_EMAIL \
    -d $KEYCLOAK_HOSTNAME \
    -d $KONG_HOSTNAME \
    -d $KONGA_HOSTNAME \
    -d $PLAYGROUND_HOSTNAME \
    --expand \
    --agree-tos \
    --no-eff-email

# Reload nginx to use updated certificate
echo "🔄 Reloading nginx with new certificate..."
docker compose exec main-nginx nginx -t
docker compose exec main-nginx nginx -s reload

# Test all domains
echo ""
echo "🌐 Testing all domains..."
echo "========================="

for domain in $KEYCLOAK_HOSTNAME $KONG_HOSTNAME $KONGA_HOSTNAME $PLAYGROUND_HOSTNAME; do
    echo "📋 Testing $domain..."
    curl -I --connect-timeout 10 https://$domain/ 2>/dev/null | head -1 || echo "❌ $domain not responding"
    sleep 1
done

echo ""
echo "✅ SSL certificate expansion completed!"
echo ""
echo "🌐 All domains should now be working:"
echo "   🔐 Keycloak: https://$KEYCLOAK_HOSTNAME"
echo "   🚪 Kong Gateway: https://$KONG_HOSTNAME"
echo "   📊 Konga Admin: https://$KONGA_HOSTNAME"
echo "   🎮 FHIR Playground: https://$PLAYGROUND_HOSTNAME"