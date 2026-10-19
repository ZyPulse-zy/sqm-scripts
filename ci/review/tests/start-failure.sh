#!/bin/sh
# Run the unmodified start-sqm entry point with a private /etc and fixtures.
# Requires Linux user/mount/network namespaces, iproute2 and sch_cake.
set -eu
root=$(CDPATH= cd -- "${SQM_TEST_ROOT:?set independent source directory}" && pwd)
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
sqm_prepare_script() { echo prepare >> "$CALL_LOG"; return "${PREPARE_STATUS:-0}"; }
egress() { echo egress >> "$CALL_LOG"; return "${EGRESS_STATUS:-0}"; }
ingress() { echo ingress >> "$CALL_LOG"; return "${INGRESS_STATUS:-0}"; }
case "${MISSING:-}" in egress) unset -f egress;; ingress) unset -f ingress;; both) unset -f egress ingress;; esac
if [ "${WRITE_FAIL:-0}" = 1 ]; then
    write_state_file() { return 1; }
fi
if [ "${CUSTOM:-0}" = 1 ]; then
    sqm_start() { echo custom >> "$CALL_LOG"; return "${CUSTOM_STATUS:-0}"; }
fi
EOF
checks=0
run_case() {
    name=$1 expected=$2 expected_state=$3 expected_calls=$4
    [ -z "${SQM_TEST_ONLY:-}" ] || [ "$name" = "$SQM_TEST_ONLY" ] || return 0
    shift 4
    rm -f "$tmp/state/lo.state"
    : > "$tmp/calls"
    rc=0
    env IFACE=lo DEV=lo SCRIPT=fixture.qos UPLINK=1000 DOWNLINK=1000 \
        TC=true IP=true INSMOD=true CALL_LOG="$tmp/calls" "$@" "${SQM_TEST_SHELL:-/bin/sh}" "$tmp/lib/start-sqm" \
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
    actual_calls=$(tr '\n' ' ' < "$tmp/calls")
    [ "$actual_calls" = "$expected_calls" ] || { echo "$name: calls [$actual_calls], expected [$expected_calls]" >&2; exit 1; }
    echo "$name: exit=$rc state=$expected_state calls=[$actual_calls]"
    checks=$((checks + 1))
}
run_case default-success 0 yes "prepare egress ingress "
run_case both-disabled 0 yes "prepare " UPLINK=0 DOWNLINK=0 MISSING=egress
run_case write-state-failure 1 no "prepare " UPLINK=0 DOWNLINK=0 WRITE_FAIL=1
run_case prepare-failure 1 no "prepare " PREPARE_STATUS=1
run_case egress-failure 1 no "prepare egress " EGRESS_STATUS=7
run_case ingress-failure 1 no "prepare ingress " UPLINK=0 INGRESS_STATUS=7
run_case missing-egress 0 yes "prepare ingress " MISSING=egress
run_case missing-ingress 0 yes "prepare " UPLINK=0 MISSING=ingress
run_case egress-only 0 yes "prepare egress " MISSING=ingress
run_case both-missing 0 yes "prepare " MISSING=both
run_case custom-success 0 yes "custom " CUSTOM=1
run_case custom-failure 7 no "custom " CUSTOM=1 CUSTOM_STATUS=7
# Real tc rejection through the actual piece_of_cake egress implementation.
ip link add sqmtest type dummy
ip link set sqmtest up
tc qdisc add dev sqmtest root cake bandwidth 1mbit
tc qdisc del dev sqmtest root
cat > "$tmp/lib/kernel.qos" <<'EOF'
. "$SQM_LIB_DIR/piece_of_cake.qos"
do_modules() { :; }
verify_qdisc() { :; }
if [ "${ONLY_EGRESS:-0}" = 1 ]; then unset -f ingress; fi
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
rc=0
env IFACE=sqmtest DEV=sqmtest SCRIPT=kernel.qos UPLINK=1000 DOWNLINK=1000 \
    TC=tc IP=ip INSMOD=true ONLY_EGRESS=1 \
    "${SQM_TEST_SHELL:-/bin/sh}" "$tmp/lib/start-sqm" >"$tmp/valid-out" 2>"$tmp/valid-log" || rc=$?
[ "$rc" -eq 0 ] || { cat "$tmp/valid-log"; echo 'valid egress-only CAKE script failed' >&2; exit 1; }
test -s "$tmp/state/sqmtest.state"
grep -q 'was started.*successfully' "$tmp/valid-log"
tc qdisc show dev sqmtest | grep -q 'qdisc cake'
checks=$((checks + 1))
echo "$checks startup cases passed (direction compatibility, function results, real CAKE rejection and egress-only shaping)"
