#!/bin/bash
set -euo pipefail

## The below is modified from https://github.com/activeeos/wireguard-docker

# Find a Wireguard interface
interfaces=`find /etc/wireguard -type f`
if [[ -z $interfaces ]]; then
    echo "$(date): Interface not found in /etc/wireguard" >&2
    exit 1
fi

for interface in $interfaces; do
    echo "$(date): Starting Wireguard $interface"
    wg-quick up $interface
done


## Verify thet wireguard module is installed:
wg_module=`find /lib/modules/$(uname -r) -type f -name '*.ko' | grep -i wireguard`
echo "Module output: $wg_module"

if [[ -z $wg_module ]]; then
    echo "$(date): Wireguard module not installed..  Installing" >&2
    apt update ; apt install -y linux-headers-amd64 wireguard-dkms
else
    echo "Wireguard module seems to be installed: $wg_module      Moving on... "
fi


# Add masquerade rule for NAT'ing VPN traffic bound for the Internet
if [[ $IPTABLES_MASQ -eq 1 ]]; then
    echo "Adding iptables NAT rule"
    iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
fi


# Fix route back to local network
if [[ -z $LOCAL_NETWORK ]]; then
    echo "$(date): ---INFO--- No network provides. Ignoring route back to local network"
else
    echo "$(date): ---INFO---  Adding route back to local network: $LOCAL_NETWORK"
    gw=$(ip route |awk '/default/ {print $3}')
    ip route add to $LOCAL_NETWORK via $gw dev eth0
fi


# get the expected VPN IP address from the interface config file
expected_ips=()
for interface in $interfaces; do
    expected_ip=$(grep -Po 'Endpoint\s=\s\K[^:]*' $interface)
    expected_ips+=($expected_ip)
done

# Handle shutdown behavior
function finish {
    echo "$(date): Shutting down Wireguard"
    for interface in $interfaces; do
        wg-quick down $interface
    done
    if [[ $IPTABLES_MASQ -eq 1 ]]; then
        iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
    fi

    exit 0
}

function fill_actual_ip {
    actual_ips=()
    actual_ip=$( wg | grep -Po 'endpoint:\s\K[^:]*')
    actual_ips+=($actual_ip)
}

trap finish SIGTERM SIGINT SIGQUIT


# check IP address every 10 seconds
fill_actual_ip
echo "$(date): ---INFO---  Endpoint in config: $expected_ips"
echo "$(date): ---INFO---  Active EndPoint : $actual_ips"

while [[ $expected_ips == $actual_ips ]];
do
    fill_actual_ip

    sleep 10;
done

echo "$(date): ---INFO---  Endpoint in config: $expected_ips"
echo "$(date): ---INFO---  Active EndPoint : $actual_ips"
echo "$(date): Expected IP to be $expected_ips but found $actual_ips. Activating killswitch."
