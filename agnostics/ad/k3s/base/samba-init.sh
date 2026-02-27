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

    # Create management account credentials and put them in a configmap
    password=$(tr -dc 'A-Za-z0-9!?%=' < /dev/urandom | head -c 10)
    samba-tool user setpassword Administrator --newpassword "$password@"
    ktutil <<CMD
addent -password -p Administrator@$REALM -k 1 -e aes256-cts-hmac-sha1-96
$password@
wkt Administrator.keytab
CMD

    cp /samba/lib/private/krb5.conf /krb5.conf
    sed -i '/default_domain =/aadmin_server = 127.0.0.1\nkdc = 127.0.0.1' /krb5.conf
    sed -i '/dns_lookup_kdc/s/true/false/' /krb5.conf
    cat /krb5.conf
    export KRB5_CONFIG=/krb5.conf
    export KRB5CCNAME=/ccache
    kinit -k -t /Administrator.keytab "Administrator@$REALM"
    kubectl -n ad create configmap administrator.keytab --from-file Administrator.keytab \
	    -o yaml --dry-run=client | kubectl apply -f -
    
    MYIP=$(ip a | grep -A1 link/ether | grep inet | awk '{ print $2 }' | awk -F'/' '{ print $1 }')
    echo $MYIP
    nslookup dc0.$REALM 127.0.0.1 | grep -A1 Name: | grep Address | awk '{ print $2 }' | grep -v "$MYIP" | \
	while read ip ; do
	    echo "Replacing $ip with $MYIP"
	    # We love unnamed arguments!
	    # Usage: samba-tool dns update <server> <zone> <name> <A|AAAA|PTR|CNAME|NS|MX|SOA|SRV|TXT> <olddata> <newdata>
	    samba-tool dns update dc0 $REALM dc0 A $ip $MYIP --use-krb5-ccache=/ccache
	done

    # Check for an rDNS zone and create it if not
    (samba-tool dns zonelist --use-krb5-ccache=/ccache | grep "in-addr\.arpa") || (
	# Usage: samba-tool dns zonecreate <server> <zone> [options]
	# Usage: samba-tool dns add <server> <zone> <name> <A|AAAA|PTR|CNAME|NS|MX|SRV|TXT> <data>
	samba-tool dns zonecreate dc0 10.in-addr.arpa --use-krb5-ccache=/ccache
	samba-tool dns add dc0 10.in-addr.arpa '*' PTR dc0.$REALM. --use-krb5-ccache=/ccache
    )

    # Ensure there is a user for MSSQL and it has the correct SPNs
    (samba-tool user list | grep ^MSSQL$) || (
	# Usage: samba-tool user create <username> [<password>] [options]
	samba-tool user create --random-password MSSQL

	# Usage: samba-tool spn add <name> <user> [options]
	samba-tool spn add MSSQLSvc/SQL:1433 MSSQL
	samba-tool spn add MSSQLSvc/SQL.$REALM:1433 MSSQL
	samba-tool spn add MSSQLSvc/SQL MSSQL
	samba-tool spn add MSSQLSvc/SQL.$REALM MSSQL

	# This allows a CNAME from sql.ad.stg... to point to mssql.ad.svc.cluster
	samba-tool spn add MSSQLSvc/mssql.ad.svc.cluster.local:1433 MSSQL
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
) & 

/usr/sbin/samba -i

exit 0
