#!/bin/bash

# Advanced Network Intrusion Detection System - Deployment Script
# This script automates the deployment process for the NIDS application

set -e  # Exit on any error

# Configuration
PROJECT_NAME="advanced-nids"
DEPLOY_DIR="/var/www/nids"
BACKUP_DIR="/var/backups/nids"
LOG_FILE="/var/log/nids-deploy.log"
VERSION=$(date +%Y%m%d_%H%M%S)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
    log "INFO: $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
    log "SUCCESS: $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
    log "WARNING: $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    log "ERROR: $1"
}

# Check if running as root or with sudo
check_permissions() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root or with sudo"
        exit 1
    fi
}

# Create necessary directories
create_directories() {
    print_status "Creating deployment directories..."
    
    mkdir -p "$DEPLOY_DIR"
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$(dirname "$LOG_FILE")"
    
    print_success "Directories created successfully"
}

# Backup existing deployment
backup_existing() {
    if [ -d "$DEPLOY_DIR" ] && [ "$(ls -A $DEPLOY_DIR)" ]; then
        print_status "Backing up existing deployment..."
        
        BACKUP_PATH="$BACKUP_DIR/backup_$VERSION.tar.gz"
        tar -czf "$BACKUP_PATH" -C "$DEPLOY_DIR" .
        
        print_success "Backup created: $BACKUP_PATH"
    else
        print_status "No existing deployment found, skipping backup"
    fi
}

# Install system dependencies
install_dependencies() {
    print_status "Installing system dependencies..."
    
    # Update package list
    apt-get update -qq
    
    # Install required packages
    apt-get install -y \
        nginx \
        python3 \
        python3-pip \
        git \
        curl \
        wget \
        ufw \
        fail2ban \
        logrotate
    
    # Install Node.js (optional, for development)
    if ! command -v node &> /dev/null; then
        curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
        apt-get install -y nodejs
    fi
    
    print_success "Dependencies installed successfully"
}

# Configure firewall
configure_firewall() {
    print_status "Configuring firewall..."
    
    # Enable UFW
    ufw --force enable
    
    # Allow SSH (be careful with this in production)
    ufw allow ssh
    
    # Allow HTTP and HTTPS
    ufw allow 80/tcp
    ufw allow 443/tcp
    
    # Allow custom port if specified
    if [ ! -z "$CUSTOM_PORT" ]; then
        ufw allow "$CUSTOM_PORT/tcp"
    fi
    
    print_success "Firewall configured successfully"
}

# Deploy application files
deploy_application() {
    print_status "Deploying application files..."
    
    # Copy application files
    cp index.html "$DEPLOY_DIR/"
    cp README.md "$DEPLOY_DIR/"
    cp LICENSE "$DEPLOY_DIR/"
    
    # Create additional directories
    mkdir -p "$DEPLOY_DIR/logs"
    mkdir -p "$DEPLOY_DIR/config"
    mkdir -p "$DEPLOY_DIR/exports"
    
    # Set proper permissions
    chown -R www-data:www-data "$DEPLOY_DIR"
    chmod -R 755 "$DEPLOY_DIR"
    chmod -R 775 "$DEPLOY_DIR/logs"
    chmod -R 775 "$DEPLOY_DIR/exports"
    
    print_success "Application deployed successfully"
}

# Configure Nginx
configure_nginx() {
    print_status "Configuring Nginx..."
    
    # Create Nginx configuration
    cat > /etc/nginx/sites-available/nids << EOF
server {
    listen 80;
    server_name ${DOMAIN_NAME:-localhost};
    root $DEPLOY_DIR;
    index index.html;

    # Security headers
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript application/javascript application/xml+rss application/json;

    # Main location
    location / {
        try_files \$uri \$uri/ =404;
    }

    # Security: Hide sensitive files
    location ~ /\\.git {
        deny all;
    }
    
    location ~ /\\.env {
        deny all;
    }
    
    location ~ /config/ {
        deny all;
    }

    # Logs location
    location /logs/ {
        auth_basic "Restricted Access";
        auth_basic_user_file /etc/nginx/.htpasswd;
        autoindex on;
    }

    # API endpoints (if any)
    location /api/ {
        # Add API configuration here if needed
        return 404;
    }

    # Error pages
    error_page 404 /404.html;
    error_page 500 502 503 504 /50x.html;
    
    # Logging
    access_log /var/log/nginx/nids_access.log;
    error_log /var/log/nginx/nids_error.log;
}
EOF

    # Enable the site
    ln -sf /etc/nginx/sites-available/nids /etc/nginx/sites-enabled/
    
    # Remove default site if it exists
    if [ -f /etc/nginx/sites-enabled/default ]; then
        rm /etc/nginx/sites-enabled/default
    fi
    
    # Test Nginx configuration
    nginx -t
    
    # Restart Nginx
    systemctl restart nginx
    systemctl enable nginx
    
    print_success "Nginx configured successfully"
}

# Configure SSL (Let's Encrypt)
configure_ssl() {
    if [ ! -z "$DOMAIN_NAME" ] && [ "$DOMAIN_NAME" != "localhost" ]; then
        print_status "Configuring SSL with Let's Encrypt..."
        
        # Install Certbot
        apt-get install -y certbot python3-certbot-nginx
        
        # Obtain certificate
        certbot --nginx -d "$DOMAIN_NAME" --non-interactive --agree-tos --email "${ADMIN_EMAIL:-admin@$DOMAIN_NAME}"
        
        # Set up auto-renewal
        echo "0 12 * * * /usr/bin/certbot renew --quiet" | crontab -
        
        print_success "SSL configured successfully"
    else
        print_warning "No domain name specified, skipping SSL configuration"
    fi
}

# Configure monitoring
configure_monitoring() {
    print_status "Configuring monitoring..."
    
    # Create monitoring script
    cat > /usr/local/bin/nids-monitor.sh << 'EOF'
#!/bin/bash

# NIDS Monitoring Script
LOG_FILE="/var/log/nids-monitor.log"
DEPLOY_DIR="/var/www/nids"

# Check if Nginx is running
if ! systemctl is-active --quiet nginx; then
    echo "$(date): Nginx is not running, attempting to restart" >> "$LOG_FILE"
    systemctl restart nginx
fi

# Check disk space
DISK_USAGE=$(df "$DEPLOY_DIR" | awk 'NR==2 {print $5}' | sed 's/%//')
if [ "$DISK_USAGE" -gt 90 ]; then
    echo "$(date): High disk usage: ${DISK_USAGE}%" >> "$LOG_FILE"
fi

# Clean old logs
find "$DEPLOY_DIR/logs" -name "*.log" -type f -mtime +30 -delete 2>/dev/null

# Check for updates (optional)
# Add update checking logic here
EOF

    chmod +x /usr/local/bin/nids-monitor.sh
    
    # Add to crontab
    echo "*/5 * * * * /usr/local/bin/nids-monitor.sh" | crontab -
    
    print_success "Monitoring configured successfully"
}

# Configure log rotation
configure_logrotate() {
    print_status "Configuring log rotation..."
    
    cat > /etc/logrotate.d/nids << EOF
$DEPLOY_DIR/logs/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    copytruncate
    postrotate
        systemctl reload nginx > /dev/null 2>&1 || true
    endscript
}

/var/log/nids*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    copytruncate
}
EOF

    print_success "Log rotation configured successfully"
}

# Create startup script
create_startup_script() {
    print_status "Creating startup script..."
    
    cat > /etc/systemd/system/nids.service << EOF
[Unit]
Description=Advanced Network Intrusion Detection System
After=network.target nginx.service
Requires=nginx.service

[Service]
Type=oneshot
ExecStart=/bin/echo "NIDS Web Interface Ready"
RemainAfterExit=true
StandardOutput=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable nids.service
    systemctl start nids.service
    
    print_success "Startup script created successfully"
}

# Validate deployment
validate_deployment() {
    print_status "Validating deployment..."
    
    # Check if files exist
    if [ ! -f "$DEPLOY_DIR/index.html" ]; then
        print_error "index.html not found in deployment directory"
        exit 1
    fi
    
    # Check Nginx status
    if ! systemctl is-active --quiet nginx; then
        print_error "Nginx is not running"
        exit 1
    fi
    
    # Check if site is accessible
    if command -v curl &> /dev/null; then
        HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/)
        if [ "$HTTP_STATUS" != "200" ]; then
            print_warning "HTTP request returned status: $HTTP_STATUS"
        else
            print_success "Site is accessible via HTTP"
        fi
    fi
    
    print_success "Deployment validation completed"
}

# Print deployment information
print_deployment_info() {
    echo ""
    echo "=================================="
    echo "  DEPLOYMENT COMPLETED"
    echo "=================================="
    echo ""
    echo "Application URL: http://${DOMAIN_NAME:-localhost}/"
    if [ ! -z "$DOMAIN_NAME" ] && [ "$DOMAIN_NAME" != "localhost" ]; then
        echo "HTTPS URL: https://$DOMAIN_NAME/"
    fi
    echo "Deploy Directory: $DEPLOY_DIR"
    echo "Backup Directory: $BACKUP_DIR"
    echo "Log File: $LOG_FILE"
    echo ""
    echo "Useful commands:"
    echo "  - View logs: tail -f $LOG_FILE"
    echo "  - Check Nginx status: systemctl status nginx"
    echo "  - Restart Nginx: systemctl restart nginx"
    echo "  - View application logs: tail -f $DEPLOY_DIR/logs/*.log"
    echo ""
    echo "Security notes:"
    echo "  - Change default passwords"
    echo "  - Configure proper authentication"
    echo "  - Review firewall settings"
    echo "  - Monitor system regularly"
    echo ""
}

# Cleanup function
cleanup() {
    print_status "Cleaning up temporary files..."
    # Add cleanup commands here
    print_success "Cleanup completed"
}

# Main deployment function
main() {
    print_status "Starting Advanced NIDS deployment..."
    
    # Check command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --domain)
                DOMAIN_NAME="$2"
                shift 2
                ;;
            --email)
                ADMIN_EMAIL="$2"
                shift 2
                ;;
            --port)
                CUSTOM_PORT="$2"
                shift 2
                ;;
            --skip-ssl)
                SKIP_SSL=true
                shift
                ;;
            --skip-firewall)
                SKIP_FIREWALL=true
                shift
                ;;
            --help)
                echo "Usage: $0 [OPTIONS]"
                echo "Options:"
                echo "  --domain DOMAIN    Domain name for the application"
                echo "  --email EMAIL      Admin email for SSL certificates"
                echo "  --port PORT        Custom port for firewall"
                echo "  --skip-ssl         Skip SSL configuration"
                echo "  --skip-firewall    Skip firewall configuration"
                echo "  --help             Show this help message"
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    # Run deployment steps
    check_permissions
    create_directories
    backup_existing
    install_dependencies
    
    if [ "$SKIP_FIREWALL" != true ]; then
        configure_firewall
    fi
    
    deploy_application
    configure_nginx
    
    if [ "$SKIP_SSL" != true ]; then
        configure_ssl
    fi
    
    configure_monitoring
    configure_logrotate
    create_startup_script
    validate_deployment
    cleanup
    
    print_deployment_info
    print_success "Advanced NIDS deployment completed successfully!"
}

# Run main function with all arguments
main "$@"
