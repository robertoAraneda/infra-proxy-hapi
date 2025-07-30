#!/bin/bash

# Keycloak-only SSL setup script with reverse proxy structure
# Ready for easy expansion to multiple services later

set -e

echo "🚀 Setting up Keycloak with reverse proxy and SSL..."

# Load environment variables
if [ -f .env-multi-domain ]; then
    export $(cat .env-multi-domain | grep -v '^#' | xargs)
else
    echo "❌ Error: .env-multi-domain file not found!"
    echo "Please create .env-multi-domain with your domain configurations"
    exit 1
fi

# Check required variables
if [ -z "$KEYCLOAK_HOSTNAME" ] || [ -z "$SSL_EMAIL" ]; then
    echo "❌ Error: Missing required environment variables"
    echo "Required: KEYCLOAK_HOSTNAME, SSL_EMAIL"
    exit 1
fi

echo "📋 Configuration:"
echo "   Keycloak domain: $KEYCLOAK_HOSTNAME"
echo "   SSL email: $SSL_EMAIL"

# Create directory structure
echo "📁 Creating directory structure..."
mkdir -p main-nginx/ssl
mkdir -p keycloak-nginx
mkdir -p certbot/conf
mkdir -p certbot/www

# Generate default self-signed certificate for unknown domains
echo "🔐 Generating default SSL certificate..."
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout main-nginx/ssl/default.key \
    -out main-nginx/ssl/default.crt \
    -subj "/C=US/ST=State/L=City/O=Org/CN=default"

# Update main nginx config with actual domain
echo "⚙️  Updating nginx configuration with your domain..."
sed -i.bak "s/auth\.yourdomain\.com/$KEYCLOAK_HOSTNAME/g" main-nginx/nginx.conf

# Step 1: Start services without SSL first
echo "🔄 Step 1: Starting services for certificate validation..."

# Create temporary main nginx config for certificate requests
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

# Start main services
docker compose -f docker-compose-main-proxy.yml up -d postgres keycloak keycloak-nginx

# Start temporary main nginx
docker run -d --name temp-main-nginx \
    --network $(basename $(pwd))_proxy-network \
    -p 80:80 \
    -v $(pwd)/main-nginx/nginx-temp.conf:/etc/nginx/nginx.conf:ro \
    -v $(pwd)/certbot/www:/var/www/certbot:ro \
    nginx:alpine

echo "⏳ Waiting for services to be ready..."
sleep 30

echo "🔐 Step 2: Requesting SSL certificate..."

# Request certificate for Keycloak domain
docker run --rm \
    --network $(basename $(pwd))_proxy-network \
    -v $(pwd)/certbot/conf:/etc/letsencrypt \
    -v $(pwd)/certbot/www:/var/www/certbot \
    certbot/certbot \
    certonly --webroot \
    -w /var/www/certbot \
    --email $SSL_EMAIL \
    -d $KEYCLOAK_HOSTNAME \
    --agree-tos \
    --no-eff-email

# Stop temporary nginx
docker stop temp-main-nginx
docker rm temp-main-nginx

echo "🚀 Step 3: Starting full SSL setup..."

# Start main nginx with SSL
docker compose -f docker-compose-main-proxy.yml up -d main-nginx

echo "🔄 Step 4: Setting up certificate renewal..."

# Create renewal script
cat > renew-keycloak-ssl.sh << 'EOF'
#!/bin/bash
docker compose -f docker-compose-main-proxy.yml exec certbot certbot renew --quiet
docker compose -f docker-compose-main-proxy.yml exec main-nginx nginx -s reload
EOF

chmod +x renew-keycloak-ssl.sh

echo ""
echo "✅ Keycloak SSL setup complete!"
echo ""
echo "🌐 Your Keycloak is now available at:"
echo "   🔐 Keycloak: https://$KEYCLOAK_HOSTNAME"
echo "   🔐 Keycloak Admin: https://$KEYCLOAK_HOSTNAME/admin"
echo ""
echo "📋 Next steps:"
echo "1. Make sure $KEYCLOAK_HOSTNAME points to this server's IP address"
echo "2. Test the setup by visiting https://$KEYCLOAK_HOSTNAME"
echo "3. Set up automatic certificate renewal with: ./renew-keycloak-ssl.sh"
echo ""
echo "🔧 To add more services later:"
echo "1. Add them to docker-compose-main-proxy.yml"
echo "2. Add upstream and server blocks to main-nginx/nginx.conf"
echo "3. Update .env-multi-domain with new domain"
echo "4. Request new certificate with certbot"
echo ""
echo "📁 Architecture ready for expansion:"
echo "   - Main reverse proxy handles all traffic on ports 80/443"
echo "   - Internal services run on isolated networks"
echo "   - SSL certificates managed centrally"