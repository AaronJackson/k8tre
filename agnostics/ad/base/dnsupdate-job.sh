#!/bin/sh

set -e

realm="ad.${DOMAIN}"
REALM=$(echo "${realm}" | tr '[:lower:]' '[:upper:]')

kinit -k -t /Administrator.keytab Administrator@$REALM

samba_ip=$(dig +short "dc0.${DOMAIN}")
echo "Samba IP: $samba_ip"

(
    echo "gsstsig"
    echo "server $samba_ip"
    echo "zone $REALM"
    kubectl get pods -n ad -o yaml | \
	yq '.items[] |
         select(.kind == "Pod") |
         select(.metadata.annotations["external-dns.alpha.kubernetes.io/internal-hostname"]) |
         "\(.metadata.annotations[\"external-dns.alpha.kubernetes.io/internal-hostname\"]) \(.status.podIP)" ' | \
	     grep -i "$realm" | \
	     while read dns ip ; do
		 dns=$(echo "$dns" | tr ',' '\n' | grep -i "$realm")

		 echo "update delete $dns. A"
		 echo "update add $dns. 60 A $ip"
	     done
    echo "show"
    echo "send"
    echo "quit"
) | nsupdate

(
    echo "gsstsig"
    echo "server $samba_ip"
    echo "zone 10.in-addr.arpa"
    kubectl get pods -n ad -o yaml | \
	yq '.items[] |
         select(.kind == "Pod") |
         select(.metadata.annotations["external-dns.alpha.kubernetes.io/internal-hostname"]) |
         "\(.metadata.annotations[\"external-dns.alpha.kubernetes.io/internal-hostname\"]) \(.status.podIP)" ' | \
	     grep -i "$realm" | \
	     while read dns ip ; do
		 dns=$(echo "$dns" | tr ',' '\n' | grep -i "$realm")

		 # Convert IP to in-addr format
		 arpa=$(echo "$ip" | awk -F'.' '{ print $4 "." $3 "." $2 "." $1 ".in-addr.arpa" }')
		 echo "update delete $arpa PTR"
		 echo "update add $arpa 60 PTR $dns"
	     done
    echo "show"
    echo "send"
    echo "quit"
) | nsupdate



coredns=$(kubectl -n kube-system get configmap coredns -o yaml)
corefile=$(echo "$coredns" | yq '.data.Corefile')
echo "$corefile" > /tmp/corefile.orig

patch="## -- K8TRE AD
ad.k8tre-dev-eks.playground.dev.hic.dundee.ac.uk:53 {
    forward .  $samba_ip
}
10.in-addr.arpa:53 {
    forward . $samba_ip
}
## // K8TRE AD
"

# Remove previous patch
corefile=$(echo "$corefile" | sed '/## -- K8TRE AD/,/## \/\/ K8TRE AD/d')
corefile="$patch$corefile"

echo "$corefile" > /tmp/corefile.new

diff /tmp/corefile.new /tmp/corefile.orig || (
    kubectl create cm coredns \
	    --from-file=Corefile=/tmp/corefile.new \
	    --dry-run=client -o yaml | \
	kubectl -n kube-system patch cm coredns \
		--type merge \
		--patch-file /dev/stdin
    kubectl -n kube-system rollout restart deployment coredns
    echo "CoreDNS updates and rollout started"
)
