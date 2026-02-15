FROM php:8.1-fpm-alpine

# Install nginx
RUN apk add --no-cache nginx

# Create app directory
WORKDIR /app

# Copy application files
COPY index.php /app/
COPY health_check.php /app/

# Configure nginx
RUN mkdir -p /run/nginx && \
    mkdir -p /var/log/nginx

# Create nginx configuration
RUN cat > /etc/nginx/nginx.conf <<'EOF'
user root;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent"';
    
    access_log /var/log/nginx/access.log main;
    sendfile on;
    keepalive_timeout 65;
    
    server {
        listen 80;
        server_name _;
        root /app;
        index index.php;
        
        location / {
            try_files $uri $uri/ /index.php$is_args$args;
        }
        
        location ~ \.php$ {
            fastcgi_pass 127.0.0.1:9000;
            fastcgi_index index.php;
            fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
            include fastcgi_params;
        }
    }
}
EOF

# Create startup script
RUN cat > /start.sh <<'EOF'
#!/bin/sh
# Start PHP-FPM in background
php-fpm -D

# Start nginx in foreground
nginx -g 'daemon off;'
EOF

RUN chmod +x /start.sh

EXPOSE 80

CMD ["/start.sh"]