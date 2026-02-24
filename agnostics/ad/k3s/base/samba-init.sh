#!/bin/sh

realm="ad.${ENVIRONMENT}.${DOMAIN}"
REALM=$(echo "$realm" | tr '[:lower:]' '[:upper:]')

if [ ! -f /samba/etc/smb.conf ] ; then
    mkdir -p /samba/etc /samba/lib /samba/logs
    samba-tool domain provision \
	       --domain=AD \
	       --realm="$REALM" \
	       --server-role=dc \
	       --dns-backend=SAMBA_INTERNAL
fi

(
    sleep 10

    samba_dnsupdate --use-samba-tool --no-credentials

    cp /samba/lib/private/krb5.conf /etc/krb5.conf
    sed -i '/default_domain =/aadmin_server = 127.0.0.1\nkdc = 127.0.0.1' /etc/krb5.conf

    # Create management account credentials and put them in a configmap
    password=$(tr -dc 'A-Za-z0-9!?%=' < /dev/urandom | head -c 10)
    samba-tool user setpassword Administrator --newpassword "$password@"
    ktutil <<CMD
addent -password -p Administrator@$REALM -k 1 -e aes256-cts-hmac-sha1-96
$password@
wkt Administrator.keytab
CMD

    kubectl -n ad create configmap administrator.keytab --from-file Administrator.keytab \
	    -o yaml --dry-run=client | kubectl apply -f -

    # Ensure there is a user for MSSQL and it has the correct SPNs
    (samba-tool user list | grep ^MSSQL$) || (
	samba-tool user create --random-password MSSQL
	samba-tool spn add MSSQLSvc/SQL:1433 MSSQL
	samba-tool spn add MSSQLSvc/SQL.$REALM:1433 MSSQL
	samba-tool spn add MSSQLSvc/SQL MSSQL
	samba-tool spn add MSSQLSvc/SQL.$REALM MSSQL

	# This allows a CNAME from sql.ad.stg... to point to sql.ad.svc.cluster
	samba-tool spn add MSSQLSvc/sql.ad.svc.cluster.local:1433 MSSQL
    )
    (samba-tool computer list | grep ^SQL) || (
	samba-tool computer create SQL$ --prepare-oldjoin
	samba-tool spn add host/sql SQL$
	samba-tool spn add host/sql.$REALM SQL$
    )
    samba-tool domain exportkeytab mssql.keytab --principal SQL$
    samba-tool domain exportkeytab mssql.keytab --principal MSSQL
    samba-tool spn list SQL$ | grep -e MSSQLSvc -e host | \
	xargs -I{} samba-tool domain exportkeytab mssql.keytab --principal {}

    kubectl -n ad create configmap mssql.keytab --from-file mssql.keytab \
	    -o yaml --dry-run=client | kubectl apply -f -

    pkill samba
)

exec /usr/sbin/samba -i 
