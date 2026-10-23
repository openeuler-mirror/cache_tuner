# cache_tuner

**English** | [简体中文](README.zh-CN.md)

`cache_tuner` provides cache-level tuning controls for supported Kunpeng
systems. The current implementation is `cache_stash`, a Linux kernel module
that exposes LLC and L2 cache stash settings through sysfs.

The module checks the CPU model, locates the relevant registers, and lets a
privileged user enable or disable the caches or select an L2 target core.

> **Warning:** `cache_stash` maps and writes hardware registers directly.
> Run it only on a compatible test machine and review the settings before using
> them on a production workload.

## Requirements

- Linux on ARM64.
- `MIDR_HISI_LINXICORE9100` (CPU part `0xD02`), such as Kunpeng 920 7270Z.
  The module rejects unsupported CPU models.
- Kernel headers that exactly match the running kernel.
- `gcc`, `make`, `kmod`, and `bc`.
- Root privileges to load the module and change settings.
- A privileged environment on compatible physical hardware. A privileged
  container can work if it shares the host kernel and target hardware access.

On openEuler, install the common dependencies with:

```bash
sudo dnf install -y gcc make kmod bc "kernel-devel-$(uname -r)"
```

Check that the kernel build tree is available before compiling:

```bash
uname -m
grep -m1 "CPU part" /proc/cpuinfo  # expected: 0xd02
test -d "/lib/modules/$(uname -r)/build" && echo "kernel headers: OK"
```

For a container build, use the same kernel release as the host and make the
matching `/usr/src/kernels` tree available. Loading and testing still require
the host kernel and appropriate device access.

## Quick start

From a fresh checkout, build and load the module:

```bash
git clone https://gitcode.com/openeuler/cache_tuner.git
cd cache_tuner

make -C cache_stash
sudo insmod cache_stash/cache_stash.ko
```

Confirm that the module and its sysfs interface are ready:

```bash
lsmod | grep cache_stash
ls /sys/kernel/cache_stash/
cat /sys/kernel/cache_stash/status
```

The `status` output reports the current LLC/L2 state, the selected L2 target,
and the detected hardware registers.

## Configure the cache

The interface is available under `/sys/kernel/cache_stash/`:

| Attribute | Access | Description |
| --- | --- | --- |
| `llc_enable` | read/write | `1` enables LLC stash, `0` disables it. |
| `l2_enable` | read/write | `1` enables L2 stash, `0` disables it. |
| `l2_target` | read/write | Reads/writes the L2 target mode and core ID. |
| `status` | read-only | Current settings and mapped-register details. |

The `l2_target` format is `<use_specific> <core_id>`. Use `0 0` for the default
target, or `1 <cpu>` to select an online CPU.

Examples:

```bash
# Read the current state
cat /sys/kernel/cache_stash/llc_enable
cat /sys/kernel/cache_stash/l2_enable
cat /sys/kernel/cache_stash/l2_target

# Enable both stashes and select the default L2 target
sudo sh -c 'echo 1 > /sys/kernel/cache_stash/llc_enable'
sudo sh -c 'echo 1 > /sys/kernel/cache_stash/l2_enable'
sudo sh -c 'echo "0 0" > /sys/kernel/cache_stash/l2_target'
```

Writes update all cache-stash registers detected for the configured hardware
topology. Settings are controlled through the module and are not a
per-process configuration interface. They apply immediately, are not stored in
a configuration file, and are not restored by `rmmod`.

To unload the module:

```bash
sudo rmmod cache_stash
make -C cache_stash clean
```

## Run the tests

The tests require root and a loaded module. Run them on a dedicated test
machine because they change cache settings:

```bash
# Run from the repository root after loading cache_stash
sudo bash cache_stash/test/test_functional.sh --skip-checks
sudo bash cache_stash/test/test_boundary.sh --skip-checks
sudo bash cache_stash/test/test_performance.sh --skip-checks

sudo rmmod cache_stash
```

The suites cover:

- `test_functional.sh`: sysfs attributes, state switching, and concurrent access.
- `test_boundary.sh`: invalid input and access-control checks.
- `test_performance.sh`: sysfs read/write latency measurements.

Each script writes a result log in the current directory.

## Troubleshooting

- **Kernel build tree not found:** install the `kernel-devel` package matching
  `uname -r`, then rerun `make`.
- **`insmod` reports `No such device`:** the architecture or CPU model is not
  supported. Check the reason with `sudo dmesg | tail`.
- **`insmod` or `rmmod` is missing:** install `kmod`.
- **`/sys/kernel/cache_stash/` does not appear:** check
  `sudo dmesg | tail` for CPU verification or register-mapping errors.
- **Build succeeds in a container but loading fails:** the module must match the
  running host kernel and execute on the physical target hardware.

## Project layout

```text
cache_stash/
├── Makefile
├── cache_stash.c       # module, register mapping, and sysfs interface
├── cache_stash.h       # hardware offsets and register bit definitions
└── test/               # functional, boundary, and performance tests
```

## License

See [LICENSE](LICENSE).
