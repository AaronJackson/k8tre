#!/bin/sh

set -e

realm="ad.${ENVIRONMENT}.${DOMAIN}"
REALM=$(echo "$realm" | tr '[:lower:]' '[:upper:]')

export KRB5CCNAME=/ccache

echo "Removing rDNS record"
MYIP=$(ip a | grep -A1 link/ether | grep inet | awk '{ print $2 }' | awk -F'/' '{ print $1 }')
MYRIP=$(echo $MYIP | awk -F. '{ print $4"."$3"."$2 }')
samba-tool dns delete dc0 10.in-addr.arpa $MYRIP PTR dc0.$REALM. --use-krb5-ccache=/ccache
