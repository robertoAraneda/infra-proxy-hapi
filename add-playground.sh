#!/bin/bash

# Add FHIR Playground and expand SSL certificate
set -e

echo "🎮 Adding FHIR Playground and expanding SSL certificate..."

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
echo "   Playground: $PLAYGROUND_HOSTNAME"
echo "   Email: $SSL_EMAIL"

# Start playground service
echo "🚀 Starting FHIR Playground..."
docker compose up -d fhir-playground

echo "⏳ Waiting for playground to be ready..."
sleep 15

# Test playground internally
echo "🔍 Testing playground (internal):"
docker compose exec main-nginx curl -I http://fhir-playground:80/ 2>/dev/null | head -1 || echo "❌ Playground not responding"

# Expand the certificate to include playground domain
echo "🔐 Expanding SSL certificate to include playground domain..."
docker compose exec certbot certbot certonly \
    --webroot \
    -w /var/www/certbot \
    --email $SSL_EMAIL \
    -d $KEYCLOAK_HOSTNAME \
    -d $KONG_HOSTNAME \
    -d $KONGA_HOSTNAME \
    -d $PLAYGROUND_HOSTNAME \
    --expand \
    --agree-tos \
    --no-eff-email

# Reload nginx to use updated certificate and configuration
echo "🔄 Reloading nginx with new configuration..."
docker compose exec main-nginx nginx -t
docker compose exec main-nginx nginx -s reload

# Test all domains
echo ""
echo "🌐 Testing all domains..."
echo "========================="

for domain in $KEYCLOAK_HOSTNAME $KONG_HOSTNAME $KONGA_HOSTNAME $PLAYGROUND_HOSTNAME; do
    echo "📋 Testing $domain..."
    curl -I --connect-timeout 10 https://$domain/ 2>/dev/null | head -1 || echo "❌ $domain not responding"
done

echo ""
echo "✅ FHIR Playground added successfully!"
echo ""
echo "🌐 All domains now available:"
echo "   🔐 Keycloak: https://$KEYCLOAK_HOSTNAME"
echo "   🔐 Keycloak Admin: https://$KEYCLOAK_HOSTNAME/admin"
echo "   🚪 Kong Gateway: https://$KONG_HOSTNAME"
echo "   🚪 Kong Admin API: https://$KONG_HOSTNAME/admin-api"
echo "   📊 Konga Admin: https://$KONGA_HOSTNAME"
echo "   🎮 FHIR Playground: https://$PLAYGROUND_HOSTNAME"
echo ""
echo "📋 Next steps:"
echo "1. Add DNS record in Cloudflare for: $PLAYGROUND_HOSTNAME"
echo "2. Test playground: curl https://$PLAYGROUND_HOSTNAME"
echo "3. Configure playground to connect to Kong Gateway FHIR endpoints"
echo ""
echo "🔧 Playground configuration:"
echo "   - The playground should connect to: https://gateway.onfhir.cl/fhir"
echo "   - For health checks: https://gateway.onfhir.cl/health"