#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Check actual SQM runners and CAKE in private mount/network namespaces.

Pass an unmodified OpenWrt base-files lib/functions.sh as --openwrt-functions.
Only the UCI storage backend and module/availability probes are fixtures.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--openwrt-functions", type=Path, required=True)
    parser.add_argument("--shell", type=Path, required=True)
    parser.add_argument("--platform", choices=("openwrt", "linux"), required=True)
    parser.add_argument("--only")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    for namespace in ("net", "mnt"):
        parent = os.environ.get("SQM_TEST_PARENT_" + namespace.upper() + "NS")
        if (
            os.geteuid() != 0
            or not parent
            or parent == os.readlink("/proc/self/ns/" + namespace)
        ):
            raise SystemExit(
                "Refusing test outside root, private mount/network namespaces"
            )
    root = Path(__file__).resolve().parent.parent
    helper = args.openwrt_functions.resolve(strict=True).read_bytes()
    shell = args.shell.resolve(strict=True)
    ip = str(Path(shutil.which("ip")).resolve())
    tc = str(Path(shutil.which("tc")).resolve())
    mounts = []
    results = []

    def run(*words, **kwargs):
        return subprocess.run(
            words, check=True, text=True, capture_output=True, **kwargs
        )

    with tempfile.TemporaryDirectory(prefix="sqm-runner-test-") as directory:
        tmp = Path(directory)
        shutil.copytree(root / "src", tmp / "lib")
        shutil.copyfile(shell, tmp / "shell")
        (tmp / "shell").chmod(0o755)
        (tmp / "bin").mkdir()
        (tmp / "bin/sh").symlink_to(tmp / "shell")
        if Path("/etc/alternatives").is_dir():
            shutil.copytree("/etc/alternatives", tmp / "alternatives", symlinks=True)
        # /bin/sh children must use the selected shell, too. All bind/overlay
        # mounts are made only after checking both namespace boundaries.
        try:
            run("mount", "--make-rprivate", "/")
            for name in ("upper", "overlay-work"):
                (tmp / name).mkdir()
            run(
                "mount",
                "-t",
                "overlay",
                "overlay",
                "-o",
                f"lowerdir=/usr/lib,upperdir={tmp}/upper,workdir={tmp}/overlay-work",
                "/usr/lib",
            )
            mounts.append("/usr/lib")
            Path("/lib/functions.sh").write_bytes(helper)
            Path("/lib/config").mkdir(exist_ok=True)
            Path("/lib/config/uci.sh").write_text(
                "uci_load() { . /etc/sqm/sections; }\n"
            )
            run("mount", "-t", "tmpfs", "tmpfs", "/etc")
            mounts.append("/etc")
            if (tmp / "alternatives").is_dir():
                shutil.copytree(
                    tmp / "alternatives", "/etc/alternatives", symlinks=True
                )
            run("mount", "-t", "sysfs", "sysfs", "/sys")
            mounts.append("/sys")
            sh_target = str(Path("/bin/sh").resolve())
            run("mount", "--bind", str(tmp / "shell"), sh_target)
            mounts.append(sh_target)
            Path("/etc/sqm").mkdir()
            state = tmp / "state"
            state.mkdir(mode=0o700)
            (state / "available_qdiscs").mkdir()
            Path("/etc/sqm/sqm.conf").write_text(
                f"SQM_LIB_DIR='{tmp}/lib'\nSQM_STATE_DIR='{state}'\n"
                f"SQM_QDISC_STATE_DIR='{state}/available_qdiscs'\nSQM_SYSLOG=0\n"
            )
            (tmp / "lib/kernel.qos").write_text(
                '. "$SQM_LIB_DIR/piece_of_cake.qos"\n'
                "do_modules() { :; }\nverify_qdisc() { :; }\n"
            )
            for device in ("sqm-a", "sqm-b"):
                run(ip, "link", "add", device, "type", "dummy")
                run(ip, "link", "set", device, "up")
            # Fail clearly if the test kernel does not provide CAKE.
            run(
                tc, "qdisc", "add", "dev", "sqm-a", "root", "cake", "bandwidth", "1mbit"
            )
            run(tc, "qdisc", "del", "dev", "sqm-a", "root")
            cases = [
                ("bad-then-good", ("bad", "good"), "", 1, (False, True)),
                ("good-then-bad", ("good", "bad"), "", 1, (True, False)),
                ("bad-then-disabled", ("bad", "disabled"), "", 1, (False, False)),
                ("good-then-good", ("good", "good"), "", 0, (True, True)),
                ("all-disabled", ("disabled", "disabled"), "", 0, (False, False)),
                (
                    "requested-good-then-skip",
                    ("good", "bad"),
                    "sqm-a",
                    0,
                    (True, False),
                ),
                (
                    "requested-bad-then-skip",
                    ("bad", "good"),
                    "sqm-a",
                    1,
                    (False, False),
                ),
            ]
            if args.platform == "openwrt":
                cases.extend(
                    [
                        (
                            "requested-skip-then-good",
                            ("bad", "good"),
                            "sqm-b",
                            0,
                            (False, True),
                        ),
                        ("skip-all", ("bad", "bad"), "sqm-none", 0, (False, False)),
                        (
                            "already-running",
                            ("running", "disabled"),
                            "",
                            0,
                            (True, False),
                        ),
                        ("no-sections", (), "", 0, (False, False)),
                    ]
                )
            for name, sections, requested, expected, expected_states in cases:
                if args.only and args.only != name:
                    continue
                for file in state.glob("*.state"):
                    file.unlink()
                for file in Path("/etc/sqm").glob("*.iface.conf"):
                    file.unlink()
                for device in ("sqm-a", "sqm-b"):
                    subprocess.run(
                        [tc, "qdisc", "del", "dev", device, "root"], capture_output=True
                    )
                config = []
                for index, kind in enumerate(sections):
                    device = ("sqm-a", "sqm-b")[index]
                    enabled = int(kind != "disabled")
                    options = "invalid_sqm_option" if kind == "bad" else ""
                    config.extend(
                        [
                            f"config queue section{index}",
                            f"option interface {device}",
                            f"option enabled {enabled}",
                            "option upload 1000",
                            "option download 0",
                            "option script kernel.qos",
                            "option qdisc cake",
                            f"option eqdisc_opts '{options}'",
                        ]
                    )
                    Path(f"/etc/sqm/{device}.iface.conf").write_text(
                        f"SCRIPT=kernel.qos\nUPLINK=1000\nDOWNLINK=0\nENABLED={enabled}\nEQDISC_OPTS='{options}'\n"
                    )
                    if kind == "running":
                        (state / f"{device}.state").write_text(
                            "existing-state-sentinel\n"
                        )
                        run(
                            tc,
                            "qdisc",
                            "add",
                            "dev",
                            device,
                            "root",
                            "cake",
                            "bandwidth",
                            "1mbit",
                        )
                Path("/etc/sqm/sections").write_text("\n".join(config) + "\n")
                runner = (
                    tmp / "lib/run-openwrt.sh"
                    if args.platform == "openwrt"
                    else root / "platform/linux/sqm-bin"
                )
                env = dict(
                    os.environ,
                    TC=tc,
                    IP=ip,
                    DEV="lo",
                    INSMOD="true",
                    SQM_DEBUG="0",
                    SQM_SYSLOG="0",
                )
                result = subprocess.run(
                    [str(tmp / "bin/sh"), str(runner), "start", requested],
                    env=env,
                    text=True,
                    capture_output=True,
                )
                actual_states = tuple(
                    (state / f"{device}.state").exists()
                    for device in ("sqm-a", "sqm-b")
                )
                actual_qdiscs = tuple(
                    "qdisc cake" in run(tc, "qdisc", "show", "dev", device).stdout
                    for device in ("sqm-a", "sqm-b")
                )
                record = dict(
                    name=name,
                    status=result.returncode,
                    expected_status=expected,
                    states=actual_states,
                    qdiscs=actual_qdiscs,
                    log=result.stderr,
                )
                results.append(record)
                assert actual_states == expected_states, record
                assert actual_qdiscs == expected_states, record
                for index, kind in enumerate(sections):
                    if expected_states[index] and kind != "running":
                        device = ("sqm-a", "sqm-b")[index]
                        saved = (state / f"{device}.state").read_text()
                        assert f'IFACE="{device}"' in saved, record
                        assert 'QDISC="cake"' in saved, record
                        assert 'UPLINK="1000"' in saved, record
                assert "not found" not in result.stderr, record
                if any(
                    kind == "bad"
                    and (not requested or requested == ("sqm-a", "sqm-b")[index])
                    for index, kind in enumerate(sections)
                ):
                    assert "invalid_sqm_option" in result.stderr, record
                if name == "already-running":
                    assert (
                        state / "sqm-a.state"
                    ).read_text() == "existing-state-sentinel\n", record
                assert result.returncode == expected, record
            assert results, "No selected cases"
        finally:
            for target in reversed(mounts):
                # Python may still map libraries from the private overlay.
                # Detach only that private mount; the namespace dies on exit.
                subprocess.run(
                    ["umount", *(["-l"] if target == "/usr/lib" else []), target],
                    check=True,
                )
    report = dict(
        passed=True,
        platform=args.platform,
        shell=str(shell),
        cases=len(results),
        openwrt_functions_sha256=hashlib.sha256(helper).hexdigest(),
        results=results,
    )
    if args.report:
        args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(
        f"{args.platform}/{shell.name}: {len(results)} runner cases passed with real CAKE"
    )


if __name__ == "__main__":
    main()
