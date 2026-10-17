#!/bin/sh
# Run the unmodified start-sqm entry point with a private /etc and fixtures.
# Requires Linux user/mount/network namespaces, iproute2 and sch_cake.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "${1:-}" != --inside ]; then
    SQM_TEST_PARENT_NETNS=$(readlink /proc/self/ns/net)
    SQM_TEST_PARENT_MNTNS=$(readlink /proc/self/ns/mnt)
    export SQM_TEST_PARENT_NETNS SQM_TEST_PARENT_MNTNS
    exec unshare -Urnm "$0" --inside
fi
# Refuse the internal entry point without proof of both isolation boundaries.
[ -n "${SQM_TEST_PARENT_NETNS:-}" ] && [ -n "${SQM_TEST_PARENT_MNTNS:-}" ]
[ "$(readlink /proc/self/ns/net)" != "$SQM_TEST_PARENT_NETNS" ]
[ "$(readlink /proc/self/ns/mnt)" != "$SQM_TEST_PARENT_MNTNS" ]
tmp=$(mktemp -d)
[ ! -d /etc/alternatives ] || cp -RP /etc/alternatives "$tmp/alternatives"
mount -t tmpfs tmpfs /etc
mount -t sysfs sysfs /sys
mkdir -p /etc/sqm
[ ! -d "$tmp/alternatives" ] || cp -RP "$tmp/alternatives" /etc/
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
cp -R "$root/src" "$tmp/lib"
mkdir "$tmp/state"
cat > /etc/sqm/sqm.conf <<EOF
SQM_LIB_DIR='$tmp/lib'
SQM_STATE_DIR='$tmp/state'
SQM_SYSLOG=0
EOF
cat > "$tmp/lib/fixture.qos" <<'EOF'
do_modules() { :; }
verify_qdisc() { :; }
nft_log_restart() { :; }
sqm_prepare_script() { return "${PREPARE_STATUS:-0}"; }
egress() { return "${EGRESS_STATUS:-0}"; }
ingress() { return "${INGRESS_STATUS:-0}"; }
case "${MISSING:-}" in egress) unset -f egress;; ingress) unset -f ingress;; esac
if [ "${WRITE_FAIL:-0}" = 1 ]; then
    write_state_file() { return 1; }
fi
if [ "${CUSTOM:-0}" = 1 ]; then
    sqm_start() { return "${CUSTOM_STATUS:-0}"; }
fi
EOF
checks=0
run_case() {
    name=$1 expected=$2 expected_state=$3
    [ -z "${SQM_TEST_ONLY:-}" ] || [ "$name" = "$SQM_TEST_ONLY" ] || return 0
    shift 3
    rm -f "$tmp/state/lo.state"
    rc=0
    env IFACE=lo DEV=lo SCRIPT=fixture.qos UPLINK=1000 DOWNLINK=1000 \
        TC=true IP=true INSMOD=true "$@" "${SQM_TEST_SHELL:-/bin/sh}" "$tmp/lib/start-sqm" \
        >"$tmp/out" 2>"$tmp/log" || rc=$?
    [ "$rc" -eq "$expected" ] || { cat "$tmp/log"; echo "$name: exit $rc, expected $expected" >&2; exit 1; }
    if [ "$expected_state" = yes ]; then
        test -s "$tmp/state/lo.state"
        grep -q 'was started.*successfully' "$tmp/log"
    else
        test ! -e "$tmp/state/lo.state"
        ! grep -q 'was started.*successfully' "$tmp/log"
        ! grep -q 'shaping activated' "$tmp/log"
    fi
    checks=$((checks + 1))
}
run_case default-success 0 yes
run_case both-disabled 0 yes UPLINK=0 DOWNLINK=0 MISSING=egress
run_case write-state-failure 1 no UPLINK=0 DOWNLINK=0 WRITE_FAIL=1
run_case prepare-failure 1 no PREPARE_STATUS=1
run_case egress-failure 1 no EGRESS_STATUS=7
run_case ingress-failure 1 no UPLINK=0 INGRESS_STATUS=7
run_case missing-egress 1 no MISSING=egress
run_case missing-ingress 1 no UPLINK=0 MISSING=ingress
run_case custom-success 0 yes CUSTOM=1
run_case custom-failure 7 no CUSTOM=1 CUSTOM_STATUS=7
# Real tc rejection through the actual piece_of_cake egress implementation.
ip link add sqmtest type dummy
ip link set sqmtest up
tc qdisc add dev sqmtest root cake bandwidth 1mbit
tc qdisc del dev sqmtest root
cat > "$tmp/lib/kernel.qos" <<'EOF'
. "$SQM_LIB_DIR/piece_of_cake.qos"
do_modules() { :; }
verify_qdisc() { :; }
EOF
rc=0
env IFACE=sqmtest DEV=sqmtest SCRIPT=kernel.qos UPLINK=1000 DOWNLINK=0 \
    TC=tc IP=ip INSMOD=true EQDISC_OPTS=invalid_sqm_option \
    "${SQM_TEST_SHELL:-/bin/sh}" "$tmp/lib/start-sqm" >"$tmp/out" 2>"$tmp/log" || rc=$?
[ "$rc" -ne 0 ] || { cat "$tmp/log"; echo 'tc rejection reported as success' >&2; exit 1; }
test ! -e "$tmp/state/sqmtest.state"
! grep -q 'shaping activated\|was started.*successfully' "$tmp/log"
! tc qdisc show dev sqmtest | grep -q 'qdisc cake'
checks=$((checks + 1))
echo "$checks startup cases passed (fixtures + real kernel tc rejection)"
