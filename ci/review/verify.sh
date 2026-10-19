#!/bin/bash
set -euo pipefail
source_dir=$(realpath "$1")
evidence_dir=$(realpath -m "$2")
lab_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$evidence_dir"
helper="$lab_dir/openwrt-functions.sh"
echo 'e819c5a6ccc2737233a2e4497745518d55fcde48511fa324a2bed40c7a59db24  '"$helper" | sha256sum -c -
test "$(git -C "$source_dir" rev-parse HEAD)" = b79b4447ca210594895dc4e8e41ed826f909c87b
test "$(git -C "$source_dir" rev-parse HEAD^)" = 77cf89e82ced9b215cc02f64fd471f5278b7d031
test "$(git -C "$source_dir" show -s --format='%an <%ae>')" = 'Yuen Su <zypulsecore@gmail.com>'
git -C "$source_dir" show -s --format=%B | grep -Fx 'Signed-off-by: Yuen Su <zypulsecore@gmail.com>'
git -C "$source_dir" diff HEAD^ --check
git -C "$source_dir" diff --name-only HEAD^ > "$evidence_dir/changed-files.txt"
printf '%s\n' platform/linux/sqm-bin src/functions.sh src/run-openwrt.sh src/start-sqm > "$evidence_dir/expected-files.txt"
cmp "$evidence_dir/changed-files.txt" "$evidence_dir/expected-files.txt"
test ! -d "$source_dir/tests"
git -C "$source_dir" show -s --format=fuller > "$evidence_dir/source-commit.txt"
for variant in original-pr original-base original-runner; do
    mkdir -p "$evidence_dir/$variant"
done
git -C "$source_dir" archive bf6f0e7913374624fa9348f7ab86e58e582f1862 | tar -x -C "$evidence_dir/original-pr"
git -C "$source_dir" archive 77cf89e82ced9b215cc02f64fd471f5278b7d031 | tar -x -C "$evidence_dir/original-base"
git -C "$source_dir" archive 5eb9982a7a202442bf214a0d2ff947600098d3d3 | tar -x -C "$evidence_dir/original-runner"
if env -u SQM_TEST_PARENT_NETNS -u SQM_TEST_PARENT_MNTNS SQM_TEST_ROOT="$source_dir" python3 "$lab_dir/tests/runner-status.py" --openwrt-functions "$helper" --shell /usr/bin/busybox --platform openwrt > "$evidence_dir/isolation-guard.log" 2>&1; then
    echo 'Guard accepted caller namespaces'; exit 1
fi
grep -F 'Refusing test outside root, private mount/network namespaces' "$evidence_dir/isolation-guard.log"
run_isolated() {
    local root="$1"
    shift
    sudo env SQM_TEST_ROOT="$root" SQM_TEST_PARENT_NETNS="$(readlink /proc/self/ns/net)" SQM_TEST_PARENT_MNTNS="$(readlink /proc/self/ns/mnt)" unshare --net --mount "$@"
}
mkdir -p "$evidence_dir/shells"
ln -sf "$(command -v busybox)" "$evidence_dir/shells/ash"
for shell in /bin/dash "$evidence_dir/shells/ash"; do
    name=$(basename "$shell")
    for testcase in missing-egress egress-only; do
        logfile="$evidence_dir/previous-$name-$testcase.log"
        if run_isolated "$evidence_dir/original-pr" env SQM_TEST_SHELL="$shell" SQM_TEST_ONLY="$testcase" "$lab_dir/tests/start-failure.sh" --inside > "$logfile" 2>&1; then
            echo "Previous PR unexpectedly accepted $testcase"; exit 1
        fi
        grep -F "$testcase: exit 1, expected 0" "$logfile"
    done
    logfile="$evidence_dir/base-$name-kernel-rejection.log"
    if run_isolated "$evidence_dir/original-base" env SQM_TEST_SHELL="$shell" SQM_TEST_ONLY=kernel-only "$lab_dir/tests/start-failure.sh" --inside > "$logfile" 2>&1; then
        echo 'Original unexpectedly propagated tc rejection'; exit 1
    fi
    grep -F 'tc rejection reported as success' "$logfile"
    run_isolated "$source_dir" env SQM_TEST_SHELL="$shell" "$lab_dir/tests/start-failure.sh" --inside | tee "$evidence_dir/single-$name.log"
    grep -F '14 startup cases passed' "$evidence_dir/single-$name.log"
done
for variant in openwrt-busybox linux-dash linux-busybox; do
    platform=${variant%-*}; shell=${variant#*-}
    logfile="$evidence_dir/original-$variant.log"
    if run_isolated "$evidence_dir/original-runner" python3 "$lab_dir/tests/runner-status.py" --openwrt-functions "$helper" --shell "/usr/bin/$shell" --platform "$platform" --only bad-then-good > "$logfile" 2>&1; then
        echo 'Original runner unexpectedly passed'; exit 1
    fi
    grep -F "'status': 0, 'expected_status': 1" "$logfile"
    grep -F "'states': (False, True), 'qdiscs': (False, True)" "$logfile"
    ! grep -q 'CalledProcessError' "$logfile"
    run_isolated "$source_dir" python3 "$lab_dir/tests/runner-status.py" --openwrt-functions "$helper" --shell "/usr/bin/$shell" --platform "$platform" --report "$evidence_dir/fixed-$variant.json" | tee "$evidence_dir/fixed-$variant.log"
done
logfile="$evidence_dir/original-hotplug-skip.log"
if run_isolated "$evidence_dir/original-runner" python3 "$lab_dir/tests/runner-status.py" --openwrt-functions "$helper" --shell /usr/bin/busybox --platform openwrt --only requested-good-then-skip > "$logfile" 2>&1; then
    echo 'Original unexpectedly passed hotplug filter'; exit 1
fi
grep -F "'status': 1, 'expected_status': 0" "$logfile"
! grep -q 'CalledProcessError' "$logfile"
for file in src/functions.sh src/start-sqm src/run-openwrt.sh platform/linux/sqm-bin; do
    dash -n "$source_dir/$file"
    busybox ash -n "$source_dir/$file"
    sha256sum "$source_dir/$file"
done > "$evidence_dir/source-sha256.txt"
echo '53 candidate cases passed: 14 per shell plus 25 real multi-interface runner cases'

