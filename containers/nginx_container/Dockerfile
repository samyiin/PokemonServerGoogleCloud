FROM debian:bullseye-slim

RUN apt-get update && apt-get install -y \
    wget \
    build-essential \
    libpcre3-dev \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

RUN wget -O openssl.tar.gz https://github.com/openssl/openssl/archive/refs/tags/OpenSSL_1_0_2u.tar.gz && \
    tar -zxf openssl.tar.gz && \
    mv openssl-OpenSSL_1_0_2u openssl-1.0.2u

RUN wget http://nginx.org/download/nginx-1.18.0.tar.gz && \
    tar -zxf nginx-1.18.0.tar.gz

WORKDIR /build/nginx-1.18.0
RUN ./configure \
    --prefix=/etc/nginx \
    --sbin-path=/usr/sbin/nginx \
    --conf-path=/etc/nginx/nginx.conf \
    --error-log-path=/var/log/nginx/error.log \
    --http-log-path=/var/log/nginx/access.log \
    --with-http_ssl_module \
    --with-http_realip_module \
    --with-openssl=../openssl-1.0.2u \
    --with-openssl-opt=enable-ssl3 \
    --with-openssl-opt=enable-ssl3-method \
    --with-openssl-opt=enable-weak-ssl-ciphers \
    && make \
    && make install

RUN ln -sf /dev/stdout /var/log/nginx/access.log && \
    ln -sf /dev/stderr /var/log/nginx/error.log

EXPOSE 80 443

CMD ["nginx", "-g", "daemon off;"]
