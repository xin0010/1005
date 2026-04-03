FROM php:8.2-apache

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libzip-dev \
        libpng-dev \
        libjpeg62-turbo-dev \
        libfreetype6-dev \
        libcurl4-openssl-dev \
        libonig-dev \
        libxml2-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) mysqli pdo_mysql gd zip mbstring curl xml \
    && a2enmod rewrite \
    && printf '%s\n' '<Directory /var/www/html/public>' '    AllowOverride All' '    Require all granted' '</Directory>' > /etc/apache2/conf-available/public-root.conf \
    && a2enconf public-root \
    && sed -ri -e 's!/var/www/html!/var/www/html/public!g' /etc/apache2/sites-available/*.conf /etc/apache2/apache2.conf /etc/apache2/conf-available/*.conf \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /var/www/html
COPY . /var/www/html

RUN chown -R www-data:www-data /var/www/html/runtime /var/www/html/public/uploads /var/www/html/public/zy

EXPOSE 80
