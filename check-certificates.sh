#!/bin/bash

# SSL Certificate Status Checker
# Shows detailed information about your SSL certificates

echo "🔍 SSL Certificate Status Report"
echo "=================================="
echo ""

# Load environment variables
if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | xargs)
fi

echo "📋 Checking certificates for:"
echo "   - $KEYCLOAK_HOSTNAME"
echo "   - $KONG_HOSTNAME"
echo "   - $KONGA_HOSTNAME"
echo ""

# 1. Check Let's Encrypt certificate details
echo "📜 Let's Encrypt Certificate Information:"
echo "----------------------------------------"
if docker compose ps certbot | grep -q "Up\|running"; then
    docker compose exec certbot certbot certificates 2>/dev/null || echo "❌ Could not get certificate info from certbot"
else
    echo "⚠️  Certbot container not running"
    # Check certificates directly from filesystem
    if [ -d "./certbot/conf/live" ]; then
        echo "📁 Found certificates in filesystem:"
        ls -la ./certbot/conf/live/
    fi
fi
echo ""

# 2. Check certificate expiry dates
echo "📅 Certificate Expiry Information:"
echo "--------------------------------"
for domain in $KEYCLOAK_HOSTNAME $KONG_HOSTNAME $KONGA_HOSTNAME; do
    echo "🔍 Checking $domain..."
    
    # Try to connect and get certificate info
    cert_info=$(echo | timeout 5 openssl s_client -servername $domain -connect $domain:443 2>/dev/null | openssl x509 -noout -dates 2>/dev/null)
    
    if [ $? -eq 0 ] && [ ! -z "$cert_info" ]; then
        echo "✅ $domain:"
        echo "$cert_info" | sed 's/^/   /'
        
        # Check if certificate expires soon (within 30 days)
        expire_date=$(echo "$cert_info" | grep "notAfter" | cut -d= -f2)
        expire_epoch=$(date -d "$expire_date" +%s 2>/dev/null)
        current_epoch=$(date +%s)
        days_until_expiry=$(( (expire_epoch - current_epoch) / 86400 ))
        
        if [ $days_until_expiry -lt 30 ]; then
            echo "   ⚠️  WARNING: Certificate expires in $days_until_expiry days!"
        else
            echo "   ✅ Certificate valid for $days_until_expiry more days"
        fi
    else
        echo "❌ $domain: Could not retrieve certificate information"
        echo "   (Domain might not be accessible or no SSL certificate)"
    fi
    echo ""
done

# 3. Check certificate subjects and SANs
echo "🏷️  Certificate Subject and Domains:"
echo "-----------------------------------"
if [ -f "./certbot/conf/live/$KEYCLOAK_HOSTNAME/fullchain.pem" ]; then
    echo "📋 Certificate covers these domains:"
    openssl x509 -in "./certbot/conf/live/$KEYCLOAK_HOSTNAME/fullchain.pem" -text -noout | grep -A1 "Subject Alternative Name" | tail -1 | sed 's/DNS://g' | sed 's/,/\n   -/g' | sed 's/^/   -/'
    echo ""
    
    echo "📋 Certificate issued by:"
    openssl x509 -in "./certbot/conf/live/$KEYCLOAK_HOSTNAME/fullchain.pem" -text -noout | grep "Issuer:" | sed 's/^/   /'
    echo ""
else
    echo "❌ Certificate file not found at ./certbot/conf/live/$KEYCLOAK_HOSTNAME/fullchain.pem"
    echo ""
fi

# 4. Check nginx SSL configuration
echo "⚙️  Nginx SSL Configuration:"
echo "---------------------------"
if docker compose ps main-nginx | grep -q "Up\|running"; then
    echo "✅ Main nginx is running"
    
    # Test nginx configuration
    nginx_test=$(docker compose exec main-nginx nginx -t 2>&1)
    if echo "$nginx_test" | grep -q "syntax is ok"; then
        echo "✅ Nginx configuration is valid"
    else
        echo "❌ Nginx configuration has errors:"
        echo "$nginx_test" | sed 's/^/   /'
    fi
else
    echo "❌ Main nginx is not running"
fi
echo ""

# 5. Check SSL connectivity for each domain
echo "🌐 SSL Connectivity Test:"
echo "------------------------"
for domain in $KEYCLOAK_HOSTNAME $KONG_HOSTNAME $KONGA_HOSTNAME; do
    echo "🔗 Testing HTTPS connection to $domain..."
    
    # Test HTTP status
    http_status=$(curl -s -o /dev/null -w "%{http_code}" -k https://$domain/ --connect-timeout 5 || echo "000")
    
    if [ "$http_status" != "000" ]; then
        echo "✅ $domain responds with HTTP $http_status"
        
        # Test SSL grade
        ssl_info=$(echo | timeout 5 openssl s_client -servername $domain -connect $domain:443 2>/dev/null | grep "Cipher\|Protocol")
        if [ ! -z "$ssl_info" ]; then
            echo "   🔐 SSL Info:"
            echo "$ssl_info" | sed 's/^/      /'
        fi
    else
        echo "❌ $domain: Connection failed or timeout"
    fi
    echo ""
done

# 6. Summary and recommendations
echo "📊 Summary and Recommendations:"
echo "==============================="

# Check if renewal is needed soon
if [ -f "./certbot/conf/live/$KEYCLOAK_HOSTNAME/fullchain.pem" ]; then
    cert_expiry=$(openssl x509 -in "./certbot/conf/live/$KEYCLOAK_HOSTNAME/fullchain.pem" -noout -enddate | cut -d= -f2)
    expiry_epoch=$(date -d "$cert_expiry" +%s 2>/dev/null)
    current_epoch=$(date +%s)
    days_left=$(( (expiry_epoch - current_epoch) / 86400 ))
    
    if [ $days_left -lt 30 ]; then
        echo "⚠️  Certificate expires in $days_left days - renewal recommended"
        echo "   Run: ./renew-ssl.sh"
    elif [ $days_left -lt 7 ]; then
        echo "🚨 Certificate expires in $days_left days - URGENT renewal needed!"
        echo "   Run: ./renew-ssl.sh"
    else
        echo "✅ Certificate is valid for $days_left more days"
    fi
else
    echo "❌ No certificate found - run SSL setup script"
fi

echo ""
echo "🔧 Useful commands:"
echo "   - Renew certificates: ./renew-ssl.sh"
echo "   - View nginx logs: docker compose logs main-nginx"
echo "   - Test certificate: openssl s_client -servername $KEYCLOAK_HOSTNAME -connect $KEYCLOAK_HOSTNAME:443"