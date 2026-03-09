#!/bin/sh
set -e

realm="ad.${DOMAIN}"
REALM=$(echo "$realm" | tr '[:lower:]' '[:upper:]')

kdestroy -c /tmp/ccache
kinit -k -t /Administrator.keytab Administrator@$REALM -c /tmp/ccache
