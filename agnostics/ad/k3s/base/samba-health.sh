#!/bin/sh
set -e

realm="ad.${ENVIRONMENT}.${DOMAIN}"
REALM=$(echo "$realm" | tr '[:lower:]' '[:upper:]')

kdestroy -c /tmp/ccache
kinit -k -t /Administrator.keytab Administratorx@$REALM -c /tmp/ccache
