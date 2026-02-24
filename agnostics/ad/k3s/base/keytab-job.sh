#!/bin/sh

KRB5CCNAME="/Administrator.ccache"
realm="ad.${ENVIRONMENT}.${DOMAIN}"
REALM=$(echo "${realm}" | tr '[:lower:]' '[:upper:]')
SAMBA_OPTS="-H \"ldaps://dc0.$realm\" -U \"Administrator@$REALM\" --use-kerberos=required --use-krb5-ccache=\"$KRB5CCNAME\""

date
echo "Updating Kerberos keytab ConfigMaps"
echo "    SAMBA_OPTS: $SAMBA_OPTS"
echo "    REALM: $REALM"

mkdir /samba/etc
cat > /etc/samba/smb.conf <<CONF
[global]
    tls verify peer = no_check
CONF

cat > /config <<CONF
[libdefaults]
default_realm = $REALM
kdc_timesync = 1
ccache_type = 4
forwardable = true
proxiable = true
  
[realms]
$REALM = {
  kdc = DC0.$REALM
}

[domain_realm]
.$REALM = $REALM
.$realm = $REALM
ad = $REALM
AD = $REALM
.ad = $REALM
.AD = $REALM
CONF

kubectl -n jupyterhub create configmap "krb5.conf" --from-file /config -o yaml --dry-run=client | kubectl apply -f -
kubectl -n ad create configmap "krb5.conf" --from-file /config -o yaml --dry-run=client | kubectl apply -f -
cp /config /etc/krb5.conf

kinit -k -t /Administrator.keytab -c Administrator.ccache "Administrator@$REALM"

current_users=$(samba-tool user list $SAMBA_OPTS) 
current_groups=$(samba-tool group list $SAMBA_OPTS)

# CRDs for this are a bit messy.
# 
# `group.identity.k8tre.io` has two valid schemas
# depending on whether it's a subgroup or not. In the
# case of subgroup, it defines project as a list, when
# it should probably be limited to a single project.
#
# We can filter out the ones we want by checking for
# .spec.members
kubectl  -n keycloak get group -o yaml | yq -r '.items[] | select(.spec.members) | .spec | (.projects[0])' | sort -u > /tmp/projects.txt
while read project <&3 ; do
    # Create a user group in AD if it doesn't exist already.
    (echo "$current_groups" | grep "^project-$project$" >/dev/null) || (
        samba-tool group add "project-$project" $SAMBA_OPTS
    )
done 3< /tmp/projects.txt
rm /tmp/projects.txt

kubectl  -n keycloak get group -o yaml | yq -r '.items[] | select(.spec.members) | .spec | (.members[] + "-" + .projects[0] + "\t" + .projects[0])' > /tmp/usernames.txt
while read username project <&3 ; do
    (echo "$current_users" | grep "^$username$" >/dev/null) || (
        samba-tool user add "$username" --random-password $SAMBA_OPTS

        samba-tool group addmembers "project-$project" "$username" $SAMBA_OPTS

        password=$(tr -dc 'A-Za-z0-9!?%=' < /dev/urandom | head -c 32)
        samba-tool user setpassword "$username" --newpassword "$password" $SAMBA_OPTS

        # Create a keytab for this user principal. This only needs to be regenerated if the user's password changes.
        # It also needs to be moved over to an expect script cause this is a bit rubbish.
        (
            echo "clear"
            echo "addent -password -p $username@$REALM -k 1 -e aes256-cts-hmac-sha1-96"
            echo "$password"
            echo "wkt /keytab"
        ) | ktutil

        kubectl -n jupyterhub create configmap "$username.keytab" --from-file /keytab -o yaml --dry-run=client | kubectl apply -f -

        rm /keytab
    )
    
done 3< /tmp/usernames.txt
exit 0
