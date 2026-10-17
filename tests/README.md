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
