#!/bin/sh

set -e

mkdir /samba/etc
cat > /etc/samba/smb.conf <<CONF
    [global]
        tls verify peer = no_check
CONF

KRB5CCNAME="/Administrator.ccache"
realm="ad.${DOMAIN}"
REALM=$(echo "${realm}" | tr '[:lower:]' '[:upper:]')
SAMBA_OPTS="-H ldaps://dc0.$realm -U Administrator@$REALM --use-kerberos=required --use-krb5-ccache=$KRB5CCNAME"

kinit -k -t /Administrator.keytab -c "$KRB5CCNAME" "Administrator@$REALM"

(samba-tool user list $SAMBA_OPTS | grep ^MSSQL$) || (
    # Usage: samba-tool user create <username> [<password>] [options]
    samba-tool user create --random-password MSSQL $SAMBA_OPTS
    samba-tool user setpassword MSSQL --newpassword="$MSSQL_SA_PASSWORD" $SAMBA_OPTS

    # Usage: samba-tool spn add <name> <user> [options]
    samba-tool spn add MSSQLSvc/SQL:1433 MSSQL $SAMBA_OPTS
    samba-tool spn add MSSQLSvc/SQL.$REALM:1433 MSSQL $SAMBA_OPTS
    samba-tool spn add MSSQLSvc/SQL MSSQL $SAMBA_OPTS
    samba-tool spn add MSSQLSvc/SQL.$REALM MSSQL $SAMBA_OPTS
    samba-tool spn add MSSQLSvc/mssql.ad.svc.cluster.local:1433 MSSQL $SAMBA_OPTS

    # Usage: samba-tool dns add <server> <zone> <name> <type> <data> [options]
    samba-tool dns add dc0.$realm $REALM sql CNAME mssql.ad.svc.cluster.local --use-krb5-ccache="$KRB5CCNAME"
)
(samba-tool computer list $SAMBA_OPTS | grep ^SQL) || (
    # Usage: samba-tool computer create <name> [options]
    samba-tool computer create 'SQL$' --prepare-oldjoin $SAMBA_OPTS
    samba-tool spn add host/SQL 'SQL$' $SAMBA_OPTS
    samba-tool spn add host/SQL.$REALM SQL$ $SAMBA_OPTS
)

# Update the SQL$ and MSSQL keytab containing relevant host SPNs.
(
    #samba-tool user setpassword 'SQL$' --newpassword="$MSSQL_SA_PASSWORD" $SAMBA_OPTS
    echo "clear"
    (
	echo 'SQL$'
	echo 'MSSQL'
	samba-tool spn list 'SQL$' $SAMBA_OPTS | grep -e MSSQLSvc -e host
	samba-tool spn list 'MSSQL' $SAMBA_OPTS | grep -e MSSQLSvc -e host
    ) | while read principal ; do
	echo "addent -password -p $principal@$REALM -k 1 -e aes256-cts-hmac-sha1-96"
	echo "$MSSQL_SA_PASSWORD"
	echo "addent -password -p $principal@$REALM -k 1 -e aes128-cts-hmac-sha1-96"
	echo "$MSSQL_SA_PASSWORD"
	echo "addent -password -p $principal@$REALM -k 1 -e arcfour-hmac"
	echo "$MSSQL_SA_PASSWORD"
    done
    echo "wkt /tmp/mssql.keytab"
) | ktutil

klist -k -t -e /tmp/mssql.keytab

mkdir -p /var/opt/mssql/secrets/
mv /tmp/mssql.keytab /var/opt/mssql/secrets/mssql.keytab
chmod 660 /var/opt/mssql/secrets/mssql.keytab
chown 10001:10001 /var/opt/mssql/secrets/mssql.keytab


