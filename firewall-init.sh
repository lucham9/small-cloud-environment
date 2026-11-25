#!/bin/bash
# Terraform template, not a standalone script. main.tf supplies its placeholders.
# No secret is embedded in this file or in instance user data. Never enable set -x.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
umask 077
retry() { for attempt in $(seq 1 90); do if "$@"; then return 0; fi; sleep 10; done; return 1; }

# Install the restrictive policy before waiting for packages. Ubuntu AWS images
# include iptables; do not permit unfiltered forwarding during first boot.
cat >/etc/sysctl.d/90-school-firewall.conf <<'SYSCTL'
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.conf.all.accept_source_route=0
SYSCTL

install -d -m 700 /etc/school
cat >/usr/local/sbin/school-firewall <<'FIREWALL'
#!/bin/bash
set -euo pipefail
# Single ENI design. All forwarded traffic enters/exits the same interface.
WAN=$(ip -4 route show default | awk 'NR==1 {print $5}')
test -n "$WAN"
RULES=$(mktemp)
trap 'rm -f "$RULES"' EXIT
cat >"$RULES" <<'FILTER'
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]
-A INPUT -i lo -j ACCEPT
-A INPUT -m conntrack --ctstate INVALID -j DROP
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A INPUT -p udp --sport 67 --dport 68 -j ACCEPT
-A INPUT -s ${monitor_ip}/32 -p tcp --dport 9100 -j ACCEPT
-A INPUT -p icmp --icmp-type fragmentation-needed -j ACCEPT
-A FORWARD -m conntrack --ctstate INVALID -j DROP
FILTER
if [ '${vpn_enabled}' = true ]; then
  cat >>"$RULES" <<'VPNFILTER'
-A INPUT -s ${peer_public_ip}/32 -p udp -m multiport --dports 500,4500 -j ACCEPT
# Require policy match even for established traffic; never forward cleartext VPN traffic.
-A FORWARD -s ${remote_cidr} -d ${vpc_cidr} -m policy --dir in --pol none -j DROP
-A FORWARD -s ${vpc_cidr} -d ${remote_cidr} -m policy --dir out --pol none -j DROP
-A FORWARD -s ${remote_cidr} -d ${vpc_cidr} -m policy --dir in --pol ipsec -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A FORWARD -s ${remote_cidr} -d ${vpc_cidr} -m policy --dir in --pol ipsec -p tcp -m multiport --dports 22,53,80,88,135,389,445,464,636,3268,3269,3389,9090,9389 -j ACCEPT
-A FORWARD -s ${remote_cidr} -d ${internal_cidr} -m policy --dir in --pol ipsec -p tcp --dport 49152:65535 -j ACCEPT
-A FORWARD -s ${remote_cidr} -d ${internal_cidr} -m policy --dir in --pol ipsec -p udp -m multiport --dports 53,88,123,389,464,1812,1813 -j ACCEPT
-A FORWARD -s ${remote_cidr} -d ${vpc_cidr} -m policy --dir in --pol ipsec -p icmp -j ACCEPT
-A FORWARD -s ${vpc_cidr} -d ${remote_cidr} -m policy --dir out --pol ipsec -j ACCEPT
# No other traffic with school-network addresses may fall through to internet rules.
-A FORWARD -s ${remote_cidr} -d ${vpc_cidr} -j DROP
VPNFILTER
fi
cat >>"$RULES" <<'FORWARD'
-A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A FORWARD -s ${internal_cidr} -p tcp -m multiport --dports 80,443 -j ACCEPT
FORWARD
for cidr in ${web_cidrs}; do
  echo "-A FORWARD -s $cidr -d ${web_ip}/32 -p tcp --dport 80 -m conntrack --ctstate DNAT -j ACCEPT" >>"$RULES"
done
cat >>"$RULES" <<'NAT'
COMMIT
*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
NAT
for cidr in ${web_cidrs}; do
  echo "-A PREROUTING -i $WAN -s $cidr -d ${firewall_ip}/32 -p tcp --dport 80 -j DNAT --to-destination ${web_ip}:80" >>"$RULES"
done
if [ '${vpn_enabled}' = true ]; then
  echo '-A POSTROUTING -s ${vpc_cidr} -d ${remote_cidr} -j ACCEPT' >>"$RULES"
fi
# Exempt all negotiated IPsec traffic before internet masquerading.
echo '-A POSTROUTING -m policy --dir out --pol ipsec -j ACCEPT' >>"$RULES"
if [ -n '${web_cidrs}' ]; then
  # DNAT+SNAT gives symmetric replies and permits a narrow web SG source.
  echo '-A POSTROUTING -d ${web_ip}/32 -p tcp --dport 80 -m conntrack --ctstate DNAT -j SNAT --to-source ${firewall_ip}' >>"$RULES"
fi
echo "-A POSTROUTING -s ${internal_cidr} -o $WAN -j MASQUERADE" >>"$RULES"
cat >>"$RULES" <<'MANGLE'
COMMIT
*mangle
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
COMMIT
MANGLE
iptables-restore --wait 10 <"$RULES"
# This machine has no IPv6 addresses or routes; also reject IPv6 locally.
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT DROP
for flag in rp_filter accept_redirects send_redirects accept_source_route; do
  for setting in /proc/sys/net/ipv4/conf/*/"$flag"; do echo 0 >"$setting"; done
done
FIREWALL
chmod 700 /usr/local/sbin/school-firewall

cat >/etc/systemd/system/school-firewall.service <<'UNIT'
[Unit]
Description=School firewall and NAT policy
Wants=network-online.target
After=network-online.target
Before=strongswan.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/school-firewall
ExecStartPost=/usr/sbin/sysctl -w net.ipv4.ip_forward=1
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
sysctl --system >/dev/null
systemctl enable --now school-firewall

retry apt-get update
retry apt-get install -y iptables prometheus-node-exporter curl
systemctl enable --now prometheus-node-exporter
if command -v snap >/dev/null; then snap start amazon-ssm-agent || true; fi

if [ '${vpn_enabled}' = true ]; then
  retry apt-get install -y charon-systemd strongswan-swanctl libcharon-extra-plugins python3-boto3
  install -d -m 700 /etc/swanctl
  cat >/usr/local/sbin/school-vpn-config <<'PY'
#!/usr/bin/python3
# Fetch the PSK in memory using the instance role; never print it or use CLI args.
import os
import re
import tempfile
import boto3

psk = boto3.client("ssm", region_name="us-east-2").get_parameter(
    Name="${psk_parameter_arn}", WithDecryption=True
)["Parameter"]["Value"]
if not re.fullmatch(r"[A-Za-z0-9+/=_-]{32,128}", psk):
    raise ValueError("VPN PSK must be 32-128 safe ASCII characters; use 64 hex characters")
config = """connections {
  school {
    version = 2
    local_addrs = ${firewall_ip}
    remote_addrs = ${peer_public_ip}
    encap = yes
    mobike = no
    proposals = aes256-sha256-modp2048
    dpd_delay = 30s
    local {
      auth = psk
      id = ${firewall_public}
    }
    remote {
      auth = psk
      id = ${peer_public_ip}
    }
    children {
      school-lan {
        local_ts = ${vpc_cidr}
        remote_ts = ${remote_cidr}
        mode = tunnel
        esp_proposals = aes256-sha256-modp2048
        start_action = trap|start
        dpd_action = restart
        rekey_time = 1h
      }
    }
  }
}
secrets {
  ike-school {
    id-local = ${firewall_public}
    id-remote = ${peer_public_ip}
    secret = """ + '"' + psk + '"' + """
  }
}
"""
fd, path = tempfile.mkstemp(prefix=".school-", dir="/etc/swanctl")
try:
    with os.fdopen(fd, "w") as stream:
        stream.write(config)
    os.chmod(path, 0o600)
    os.replace(path, "/etc/swanctl/swanctl.conf")
finally:
    if os.path.exists(path):
        os.unlink(path)
PY
  chmod 700 /usr/local/sbin/school-vpn-config
  cat >/etc/systemd/system/school-vpn-refresh.service <<'UNIT'
[Unit]
Description=Retrieve school VPN PSK and reload configuration
Wants=network-online.target
After=network-online.target strongswan.service school-firewall.service
Requires=strongswan.service school-firewall.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/school-vpn-config
ExecStart=/usr/sbin/swanctl --load-all
UMask=0077
UNIT
  cat >/etc/systemd/system/school-vpn-refresh.timer <<'UNIT'
[Unit]
Description=Retry VPN setup and refresh rotated PSK
[Timer]
OnBootSec=60s
OnUnitActiveSec=5min
Persistent=true
[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable --now strongswan
  systemctl enable --now school-vpn-refresh.timer
  systemctl start school-vpn-refresh.service || true
fi
