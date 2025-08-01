#!/bin/bash

# Full SSL setup script for all domains (Keycloak + Kong + Konga)
set -e

echo "🚀 Setting up SSL for all domains from scratch..."

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

# Create directory structure
echo "📁 Creating directory structure..."
mkdir -p main-nginx/ssl
mkdir -p certbot/conf
mkdir -p certbot/www

# Generate default self-signed certificate
echo "🔐 Generating temporary SSL certificate..."
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout main-nginx/ssl/default.key \
    -out main-nginx/ssl/default.crt \
    -subj "/C=US/ST=State/L=City/O=Org/CN=default"

# Create temporary nginx config for certificate validation
cat > main-nginx/nginx-temp.conf << 'EOF'
events {
    worker_connections 1024;
}

http {
    server {
        listen 80 default_server;
        server_name _;

        location /.well-known/acme-challenge/ {
            root /var/www/certbot;
        }

        location /health {
            access_log off;
            return 200 "temp-proxy-healthy\n";
            add_header Content-Type text/plain;
        }

        location / {
            return 200 "Certificate validation server";
            add_header Content-Type text/plain;
        }
    }
}
EOF

# Start backend services
echo "🚀 Starting backend services..."
docker compose up -d postgres kong-postgres kong-migration
sleep 15
docker compose up -d keycloak kong konga-prepare konga

# Start temporary nginx for certificate validation
echo "🌐 Starting temporary nginx for ACME challenge..."
docker run -d --name temp-main-nginx \
    --network $(basename $(pwd))_proxy-network \
    -p 80:80 \
    -v $(pwd)/main-nginx/nginx-temp.conf:/etc/nginx/nginx.conf:ro \
    -v $(pwd)/certbot/www:/var/www/certbot:ro \
    nginx:alpine

echo "⏳ Waiting for services to be ready..."
sleep 30

# Request certificates for all domains
echo "🔐 Requesting SSL certificates for all domains..."
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
    --agree-tos \
    --no-eff-email

# Stop temporary nginx
echo "🛑 Stopping temporary nginx..."
docker stop temp-main-nginx
docker rm temp-main-nginx

# Start main nginx with SSL
echo "🌐 Starting main nginx with SSL..."
docker compose up -d main-nginx

echo ""
echo "✅ Full SSL setup complete!"
echo ""
echo "🌐 Your services are now available at:"
echo "   🔐 Keycloak: https://$KEYCLOAK_HOSTNAME"
echo "   🔐 Keycloak Admin: https://$KEYCLOAK_HOSTNAME/admin"
echo "   🚪 Kong Gateway: https://$KONG_HOSTNAME"
echo "   🚪 Kong Admin API: https://$KONG_HOSTNAME/admin-api"
echo "   📊 Konga Admin: https://$KONGA_HOSTNAME"
echo ""
echo "📋 Next steps:"
echo "1. Test all services"
echo "2. Configure Konga with Kong Admin URL: http://kong:8001"
echo "3. Set up automatic renewal: ./renew-ssl.sh"