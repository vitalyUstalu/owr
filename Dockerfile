# Use specific fixed version of OpenResty (multi-arch manifest)
FROM openresty/openresty:1.27.1.2-alpine-fat

# Install luarocks + resty-jit-uuid
RUN apk add --no-cache luarocks \
    && luarocks install lua-resty-jit-uuid

# Copy nginx.conf
COPY configs/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf

# Copy Lua modules
COPY lua/ /etc/openresty/lua/

# Copy HTML files
COPY html/ /etc/openresty/html/

# Expose configured port
EXPOSE 8080

# Run OpenResty in foreground
CMD ["openresty", "-g", "daemon off;"]
