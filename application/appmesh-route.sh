#!/bin/bash -e

# Copyright 2020 Rio Maulana

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#     http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

function print_help {
    echo "usage: $0 [status|enable|disable]"
    echo "Manage route configuration redirecting inbound and outbound network traffic into App Mesh envoy"
    echo ""
    echo "-h,--help print this help"
    echo "--envoy-uid The UID used by envoy container. (default: 1337)"
    echo "--app-ports The port used by web application. (default: 80)"
    echo "--egress-ignored-ips Comma separated destination IPs to not be routed through envoy. (default: 169.254.169.254,169.254.170.2)"
    echo "--egress-ignored-ports Comma separated list of ports for which egress traffic will be ignored. (always ignore port 22)"
}

POSITIONAL=()
POLICY_DOCUMENTS=()
POLICY_ARNS=()

while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -h|--help)
            print_help
            exit 1
            ;;
        --envoy-uid)
            APPMESH_IGNORE_UID="$2"
            shift
            shift
            ;;
        --app-port)
            APPMESH_APP_PORTS="$2"
            shift
            shift
            ;;
        --ignored-ips)
            APPMESH_EGRESS_IGNORED_IP="$2"
            shift
            shift
            ;;
        *)    # unknown option
            POSITIONAL+=("$1") # save it in an array for later
            shift # past argument
            ;;
    esac
done

set +u
set -- "${POSITIONAL[@]}" # restore positional parameters
OPERATION="$1"

APPMESH_IGNORE_UID="${APPMESH_IGNORE_UID:-1337}"
APPMESH_APP_PORTS="${APPMESH_APP_PORTS:-80}"
APPMESH_ENVOY_EGRESS_PORT="15001"
APPMESH_ENVOY_INGRESS_PORT="15000"
APPMESH_EGRESS_IGNORED_IP="${APPMESH_EGRESS_IGNORED_IP:-169.254.169.254,169.254.170.2}"
APPMESH_EGRESS_IGNORED_PORTS="${APPMESH_EGRESS_IGNORED_PORTS:-}"

log(){
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] $1"
}

# Egress traffic from the processess owned by the following UID/GID will be ignored.
if [ -z "$APPMESH_IGNORE_UID" ] && [ -z "$APPMESH_IGNORE_GID" ]; then
    log "Variables APPMESH_IGNORE_UID and/or APPMESH_IGNORE_GID must be set."
    log "Envoy must run under those IDs to be able to properly route its egress traffic."
    exit 1
fi

# Port numbers Application and Envoy are listening on.
if [ -z "$APPMESH_ENVOY_INGRESS_PORT" ] || [ -z "$APPMESH_ENVOY_EGRESS_PORT" ] || [ -z "$APPMESH_APP_PORTS" ]; then
    log "All of APPMESH_ENVOY_INGRESS_PORT, APPMESH_ENVOY_EGRESS_PORT and APPMESH_APP_PORTS variables must be set."
    log "If any one of them is not set we will not be able to route either ingress, egress, or both directions."
    exit 1
fi

# Comma separated list of ports for which egress traffic will be ignored, we always refuse to route SSH traffic.
if [ -z "$APPMESH_EGRESS_IGNORED_PORTS" ]; then
    APPMESH_EGRESS_IGNORED_PORTS="22"
else
    APPMESH_EGRESS_IGNORED_PORTS="$APPMESH_EGRESS_IGNORED_PORTS,22"
fi

#
# End of configurable options
#

APPMESH_LOCAL_ROUTE_TABLE_ID="100"
APPMESH_PACKET_MARK="0x1e7700ce"

function init() {
    iptables -t mangle -N APPMESH_INGRESS
    iptables -t nat -N APPMESH_INGRESS
    iptables -t nat -N APPMESH_EGRESS

    ip rule add fwmark "$APPMESH_PACKET_MARK" lookup $APPMESH_LOCAL_ROUTE_TABLE_ID
    ip route add local default dev lo table $APPMESH_LOCAL_ROUTE_TABLE_ID
}

function deinit() {
    ip route del local default dev lo table $APPMESH_LOCAL_ROUTE_TABLE_ID
    ip rule del fwmark "$APPMESH_PACKET_MARK" lookup $APPMESH_LOCAL_ROUTE_TABLE_ID

    iptables -t mangle -X APPMESH_INGRESS
    iptables -t nat -X APPMESH_INGRESS
    iptables -t nat -X APPMESH_EGRESS
}

function enable_egress_routing() {
    # Stuff to ignore
    [ ! -z "$APPMESH_IGNORE_UID" ] && \
        iptables -t nat -A APPMESH_EGRESS \
        -m owner --uid-owner $APPMESH_IGNORE_UID \
        -j RETURN

    [ ! -z "$APPMESH_IGNORE_GID" ] && \
        iptables -t nat -A APPMESH_EGRESS \
        -m owner --gid-owner $APPMESH_IGNORE_GID \
        -j RETURN

    [ ! -z "$APPMESH_EGRESS_IGNORED_PORTS" ] && \
        iptables -t nat -A APPMESH_EGRESS \
        -p tcp \
        -m multiport --dports "$APPMESH_EGRESS_IGNORED_PORTS" \
        -j RETURN

    [ ! -z "$APPMESH_EGRESS_IGNORED_IP" ] && \
        iptables -t nat -A APPMESH_EGRESS \
        -p tcp \
        -d "$APPMESH_EGRESS_IGNORED_IP" \
        -j RETURN

    # Redirect everything that is not ignored
    iptables -t nat -A APPMESH_EGRESS \
        -p tcp \
        -j REDIRECT --to $APPMESH_ENVOY_EGRESS_PORT

    # Apply APPMESH_EGRESS chain to non local traffic
    iptables -t nat -A OUTPUT \
        -p tcp \
        -m addrtype ! --dst-type LOCAL \
        -j APPMESH_EGRESS
}

function enable_ingress_redirect_routing() {
    # Route everything arriving at the application port to Envoy
    iptables -t nat -A APPMESH_INGRESS \
        -p tcp \
        -m multiport --dports "$APPMESH_APP_PORTS" \
        -j REDIRECT --to-port "$APPMESH_ENVOY_INGRESS_PORT"

    # Apply AppMesh ingress chain to everything non-local
    iptables -t nat -A PREROUTING \
        -p tcp \
        -m addrtype ! --src-type LOCAL \
        -j APPMESH_INGRESS
}

function enable_routing() {
    log "=== Enabling routing ==="
    enable_egress_routing
    enable_ingress_redirect_routing
}

function disable_routing() {
    log "=== Disabling routing ==="
    iptables -F
    iptables -F -t nat
    iptables -F -t mangle
}

function dump_status() {
    log "=== Routing rules ==="
    ip rule
    log "=== AppMesh routing table ==="
    ip route list table $APPMESH_LOCAL_ROUTE_TABLE_ID
    log "=== iptables FORWARD table ==="
    iptables -L -v -n
    log "=== iptables NAT table ==="
    iptables -t nat -L -v -n
    log "=== iptables MANGLE table ==="
    iptables -t mangle -L -v -n
}

case $OPERATION in
    "status")
        dump_status
        ;;
    "enable")
        init
        enable_routing
        ;;
    "disable")
        disable_routing
        deinit
        ;;
    *)
        log "Available commands: status, enable, disable"
        ;;
esac
