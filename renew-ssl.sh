# renew-ssl.sh
#!/bin/bash
echo "🔄 Renewing SSL certificates..."
docker compose exec certbot certbot renew --quiet
if [ $? -eq 0 ]; then
    echo "✅ Certificates renewed successfully"
    echo "🔄 Reloading nginx..."
    docker compose exec main-nginx nginx -s reload
    echo "✅ Nginx reloaded"
else
    echo "❌ Certificate renewal failed"
    exit 1
fi

---

# check-certificates.sh
#!/bin/bash
echo "🔍 Checking SSL certificate status..."
echo ""
echo "📋 Multi-domain certificate:"
docker compose exec certbot certbot certificates | grep -A 10 "Certificate Name"
echo ""
echo "📅 Certificate expiry check:"
echo | openssl s_client -servername openid.onfhir.cl -connect localhost:443 2>/dev/null | openssl x509 -noout -dates 2>/dev/null || echo "  ❌ Could not check certificate"

---

# ssl-cron-entry.txt
# SSL Certificate Auto-renewal - runs twice daily
# Add to crontab with: sudo crontab -e
0 12 * * * /path/to/your/project/renew-ssl.sh >> /var/log/ssl-renewal.log 2>&1
0 0 * * * /path/to/your/project/renew-ssl.sh >> /var/log/ssl-renewal.log 2>&1