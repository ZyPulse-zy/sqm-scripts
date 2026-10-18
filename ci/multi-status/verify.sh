#!/bin/bash
set -euo pipefail
source_dir=$(realpath "$1")
evidence_dir=$(realpath -m "$2")
mkdir -p "$evidence_dir"
helper="$evidence_dir/openwrt-functions.sh"
curl --retry 3 --connect-timeout 10 --max-time 60 -fsSL https://raw.githubusercontent.com/qosmio/openwrt-ipq/92a2d104145c8d265851c4b388a41bd8e9c21cd9/package/base-files/files/lib/functions.sh -o "$helper"
echo 'e819c5a6ccc2737233a2e4497745518d55fcde48511fa324a2bed40c7a59db24  '"$helper" | sha256sum -c -
git -C "$source_dir" rev-parse HEAD > "$evidence_dir/source-commit.txt"
original="$evidence_dir/original"
mkdir -p "$original"
git -C "$source_dir" archive 5eb9982a7a202442bf214a0d2ff947600098d3d3 | tar -x -C "$original"
cp "$source_dir/tests/runner-status.py" "$original/tests/runner-status.py"
if python3 "$source_dir/tests/runner-status.py" --openwrt-functions "$helper" --shell /usr/bin/busybox --platform openwrt > "$evidence_dir/isolation-guard.log" 2>&1; then
  echo 'Guard accepted caller namespaces'; exit 1
fi
grep -F 'Refusing test outside root, private mount/network namespaces' "$evidence_dir/isolation-guard.log"
run_isolated() {
  sudo env SQM_TEST_PARENT_NETNS="$(readlink /proc/self/ns/net)" SQM_TEST_PARENT_MNTNS="$(readlink /proc/self/ns/mnt)" unshare --net --mount "$@"
}
for variant in openwrt-busybox linux-dash linux-busybox; do
  platform=${variant%-*}; shell=${variant#*-}
  if run_isolated python3 "$original/tests/runner-status.py" --openwrt-functions "$helper" --shell "/usr/bin/$shell" --platform "$platform" --only bad-then-good > "$evidence_dir/original-$variant.log" 2>&1; then
    echo 'Original unexpectedly passed'; exit 1
  fi
  grep -F "'status': 0, 'expected_status': 1" "$evidence_dir/original-$variant.log"
  grep -F "'states': (False, True), 'qdiscs': (False, True)" "$evidence_dir/original-$variant.log"
  ! grep -q 'CalledProcessError' "$evidence_dir/original-$variant.log"
  run_isolated python3 "$source_dir/tests/runner-status.py" --openwrt-functions "$helper" --shell "/usr/bin/$shell" --platform "$platform" --report "$evidence_dir/fixed-$variant.json" | tee "$evidence_dir/fixed-$variant.log"
done
if run_isolated python3 "$original/tests/runner-status.py" --openwrt-functions "$helper" --shell /usr/bin/busybox --platform openwrt --only requested-good-then-skip > "$evidence_dir/original-hotplug-skip.log" 2>&1; then
  echo 'Original unexpectedly passed hotplug filter'; exit 1
fi
grep -F "'status': 1, 'expected_status': 0" "$evidence_dir/original-hotplug-skip.log"
! grep -q 'CalledProcessError' "$evidence_dir/original-hotplug-skip.log"
# Preserve the original single-interface regression coverage as well.
mkdir -p "$evidence_dir/shells"
ln -s "$(command -v busybox)" "$evidence_dir/shells/ash"
for shell in /bin/dash "$evidence_dir/shells/ash"; do
  run_isolated env SQM_TEST_SHELL="$shell" "$source_dir/tests/start-failure.sh" --inside | tee "$evidence_dir/single-$(basename "$shell").log"
done
for file in "$source_dir/src/run-openwrt.sh" "$source_dir/platform/linux/sqm-bin"; do
  dash -n "$file"
  busybox ash -n "$file"
done
git -C "$source_dir" diff --check
