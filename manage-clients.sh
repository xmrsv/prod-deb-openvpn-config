port 443
proto tcp-server
explicit-exit-notify 2
dev tun
topology subnet
ca /etc/openvpn/server/ca.crt
cert /etc/openvpn/server/server.crt
key /etc/openvpn/server/server.key
dh /etc/openvpn/server/dh.pem
crl-verify /etc/openvpn/server/crl.pem
tls-crypt /etc/openvpn/server/ta.key
server 10.231.83.0 255.255.255.0
ifconfig-pool-persist /var/log/openvpn/ipp.txt 3600
push "redirect-gateway def1 bypass-dhcp"
push "route 10.10.10.0 255.255.255.0"
push "dhcp-option DNS 10.10.10.1"
push "block-outside-dns"
keepalive 10 120
cipher AES-256-GCM
auth SHA256
tls-version-min 1.2
remote-cert-tls client
user nobody
group nogroup
persist-key
persist-tun
status /var/log/openvpn/openvpn-status.log
log-append /var/log/openvpn/openvpn.log
verb 3
