realm="ad.${DOMAIN}"
REALM=$(echo "${realm}" | tr '[:lower:]' '[:upper:]')

(samba-tool user list | grep ^MSSQL$) || (
    # Usage: samba-tool user create <username> [<password>] [options]
    echo "Creating MSSQL user"
    samba-tool user create --random-password MSSQL
    samba-tool user setexpiry MSSQL --noexpiry

    # Usage: samba-tool spn add <name> <user> [options]
    samba-tool spn add MSSQLSvc/sql:1433 MSSQL
    samba-tool spn add MSSQLSvc/sql.$REALM:1433 MSSQL
    samba-tool spn add MSSQLSvc/sql MSSQL
    samba-tool spn add MSSQLSvc/sql.$REALM MSSQL
    samba-tool spn add MSSQLSvc/sql.ad.svc.cluster.local:1433 MSSQL
    samba-tool spn add host/sql MSSQL
    samba-tool spn add host/sql.$REALM MSSQL
    samba-tool spn add host/mssql.ad.svc.cluster.local
)

# Update the SQL$ and MSSQL keytab containing relevant host SPNs.
samba-tool domain exportkeytab mssql.keytab --principal MSSQL
samba-tool spn list MSSQL | grep -e MSSQLSvc -e host | \
    xargs -I{} samba-tool domain exportkeytab mssql.keytab --principal {}

kubectl -n ad create configmap mssql.keytab --from-file mssql.keytab \
        -o yaml --dry-run=client | kubectl apply -f -
