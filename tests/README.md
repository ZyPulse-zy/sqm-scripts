Run `tests/start-failure.sh` on Linux with iproute2, CAKE and enabled user,
mount and network namespaces. It runs the real `start-sqm` without editing it,
using a temporary `/etc/sqm` and a private network and sysfs mount. No host
qdisc, network configuration or SQM installation is changed.

Ten fixture cases exercise successful and failing preparation, enabled shaping
functions, missing functions, state publication and script-specific startup.
One kernel case makes the actual `piece_of_cake.qos` egress command reject an
invalid option, then checks the exit status, state file and absence of a CAKE
qdisc. Module loading and qdisc availability probes are bypassed in that case;
the test first verifies CAKE availability with a real temporary qdisc.

The default shell is `/bin/sh`. To exercise another POSIX shell, set
`SQM_TEST_SHELL` to its executable path (for BusyBox use an `ash` symlink).

This tests propagation of failures returned by the startup functions. It does
not add transactional rollback or detect intermediate command failures that a
custom shaping function itself ignores.

On CI runners which prohibit user-namespace mappings, root can instead create
private mount and network namespaces without changing the host namespace:

```sh
sudo env SQM_TEST_PARENT_NETNS="$(readlink /proc/self/ns/net)" \
  SQM_TEST_PARENT_MNTNS="$(readlink /proc/self/ns/mnt)" \
  unshare -mn tests/start-failure.sh --inside
```

The internal entry point refuses to run unless both namespace IDs differ from
the supplied parent IDs. Never disable the runner's user-namespace restrictions
for this test.

`runner-status.py` additionally checks the actual OpenWrt and standalone Linux
entry points with two private interfaces. It verifies that a failed CAKE start
remains visible after a successful, disabled or filtered interface, while other
interfaces continue to start. Exit status, state files and actual qdiscs are
checked together. OpenWrt-only cases cover an existing state file, no sections
and hotplug interface filtering. The selected shell is also used by `/bin/sh`
children inside the private mount namespace.

This test needs root, Python 3, BusyBox, iproute2 with CAKE, and overlayfs. Pass
an unmodified OpenWrt `package/base-files/files/lib/functions.sh`; it uses the
real `config_foreach` and `config_get`. Only the UCI storage backend supplies
fixture sections. The helper used for validation is from OpenWrt-ipq commit
`92a2d104145c8d265851c4b388a41bd8e9c21cd9`, with SHA-256
`e819c5a6ccc2737233a2e4497745518d55fcde48511fa324a2bed40c7a59db24`.

```sh
sudo env SQM_TEST_PARENT_NETNS="$(readlink /proc/self/ns/net)" \
  SQM_TEST_PARENT_MNTNS="$(readlink /proc/self/ns/mnt)" \
  unshare -mn python3 tests/runner-status.py \
    --openwrt-functions /path/to/lib/functions.sh \
    --shell /usr/bin/busybox --platform openwrt --report /tmp/sqm-openwrt.json
```

For standalone Linux, use `--platform linux` with `--shell /bin/dash` or a
BusyBox executable. The mount guard is checked before any mount or file write.
The helper, UCI fixture, `/etc/sqm`, sysfs and shell bind exist only in the
private mount namespace. The caller's interfaces and SQM installation are
never used. Module loading and availability probes are bypassed after a real
CAKE availability check. These tests do not claim transactional rollback or
router/firmware coverage.
