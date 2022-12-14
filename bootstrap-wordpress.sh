#!/bin/bash -xe

cd /tmp

# Install jq
yum -y install jq

# Populate some variables from meta-data and tags
INSTANCE_ID=$(curl http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region)
NAME=$(aws ec2 describe-tags --region us-east-1 --filters "Name=key,Values=Name" "Name=resource-id,Values=$INSTANCE_ID" --output json | jq .Tags[0].Value -r)
STACK_NAME=$(aws ec2 describe-tags --region us-east-1 --filters "Name=key,Values=StackName" "Name=resource-id,Values=$INSTANCE_ID" --output json | jq .Tags[0].Value -r)





################################################################################
# BEGIN WordPress Setup
################################################################################

# TBD AWS Secrets Manager?
DB_USER=$(awk -F "=" '/DB_USER/ {print $2}' /root/.aws/bootstrap.properties)
DB_PASSWORD=$(awk -F "=" '/DB_PASSWORD/ {print $2}' /root/.aws/bootstrap.properties)
DB_NAME=$(awk -F "=" '/DB_DATABASE/ {print $2}' /root/.aws/bootstrap.properties)
DB_HOST=$(awk -F "=" '/DB_SERVER/ {print $2}' /root/.aws/bootstrap.properties)

# Get the latest LAMP packages for AWS Linux 2
amazon-linux-extras install -y lamp-mariadb10.2-php7.2 php7.2

# Install apache
yum install -y httpd

# Install php-xml
yum install -y php-xml.*

# Remove this later
echo "<?php phpinfo() ?>" > /var/www/html/info.php

# Download wordpress and install it in /var/www/html
cd /tmp
wget -O /tmp/latest.tar.gz http://wordpress.org/latest.tar.gz
tar -xzf /tmp/latest.tar.gz
rm -rf /var/www/html/wp-*
mv /tmp/wordpress/* /var/www/html
chown -R apache:apache /var/www/html
chmod 775 /var/www/html
cd /var/www/html

# Configure wordpress
mv wp-config-sample.php wp-config.php 
sed -i "s/define( *'DB_USER', '.*' *);/define( 'DB_USER', '${DB_USER}' );/" wp-config.php 
sed -i "s/define( *'DB_PASSWORD', '.*' *);/define( 'DB_PASSWORD', '${DB_PASSWORD}' );/" wp-config.php 
sed -i "s/define( *'DB_NAME', '.*' *);/define( 'DB_NAME', '${DB_NAME}' );/" wp-config.php 
sed -i "s/define( *'DB_HOST', '.*' *);/define( 'DB_HOST', '${DB_HOST}' );/" wp-config.php 


# Lock down wp-config.php
chmod 660 wp-config.php

# Configure cache expiry for static content
cat << EOF > /var/www/html/.htaccess
# BEGIN WordPress
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteBase /
RewriteRule ^index\.php$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]
</IfModule>
# END WordPress

<IfModule mod_expires.c>
ExpiresActive On

# Images
ExpiresByType image/jpeg "access plus 1 year"
ExpiresByType image/gif "access plus 1 year"
ExpiresByType image/png "access plus 1 year"
ExpiresByType image/webp "access plus 1 year"
ExpiresByType image/svg+xml "access plus 1 year"
ExpiresByType image/x-icon "access plus 1 year"
ExpiresByType image/x-icon "access 1 year"

# Video
ExpiresByType video/mp4 "access plus 1 year"
ExpiresByType video/mpeg "access plus 1 year"

# CSS, JavaScript
ExpiresByType text/css "access plus 1 year"
ExpiresByType text/javascript "access plus 1 year"
ExpiresByType application/javascript "access plus 1 year"

# Others
ExpiresByType application/pdf "access plus 1 year"
ExpiresByType application/x-shockwave-flash "access plus 1 year"
</IfModule>
EOF

# Lock down .htaccess
chmod 660 /var/www/html/.htaccess

# Start the httpd service and configure it to start on boot
systemctl enable httpd
systemctl start httpd

################################################################################
# END WordPress Setup
################################################################################

# Update the instance name to include the stack name
if [[ $NAME != *-$STACK_NAME ]]
then
    NEW_NAME="$NAME-$STACK_NAME"
    aws ec2 create-tags --resources $INSTANCE_ID --tags Key=Name,Value=$NEW_NAME --region $REGION
else
    NEW_NAME=$NAME
fi

# Run system updates
yum -y update

# Delete the ec2-user and its home directory
userdel ec2-user || true
rm -rf /home/ec2-user || true

# Call cfn-init, which reads the launch configration metadata and uses it to
# configure and runs cfn-hup as a service, so we can get a script run on updates to the metadata
/opt/aws/bin/cfn-init -v --stack ${STACK_NAME} --resource LaunchTemplate --configsets cfn_install --region ${REGION}

# Send a signal indicating we're done
/opt/aws/bin/cfn-signal -e $? --stack ${STACK_NAME} --resource WordPressScalingGroup --region ${REGION} || true
