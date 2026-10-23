# cache_tuner

**简体中文** | [English](README.md)

`cache_tuner` 为受支持的鲲鹏系统提供缓存级调优能力。当前实现是
`cache_stash`，它是一个 Linux 内核模块，通过 sysfs 提供 LLC 和 L2
缓存 stash 控制。

模块会检查 CPU 型号并定位相关寄存器，允许特权用户启停缓存或选择 L2
目标核心。

> **警告：** `cache_stash` 会直接映射并写入硬件寄存器。请仅在兼容的测试机上
> 运行，并在生产环境使用前确认各项设置。

## 环境要求

- ARM64 架构的 Linux 系统。
- CPU 型号为 `MIDR_HISI_LINXICORE9100`（CPU part `0xD02`），例如鲲鹏
  920 7270Z。模块会拒绝在不受支持的 CPU 型号上加载。
- 与当前运行内核完全匹配的内核头文件。
- `gcc`、`make`、`kmod` 和 `bc`。
- 加载模块和修改设置所需的 root 权限。
- 可访问目标硬件的特权环境。若使用特权容器，该容器必须共享宿主机内核，
  并且能够访问目标硬件。

在 openEuler 上安装常用依赖：

```bash
sudo dnf install -y gcc make kmod bc "kernel-devel-$(uname -r)"
```

编译前检查内核构建树是否可用：

```bash
uname -m
grep -m1 "CPU part" /proc/cpuinfo  # 应输出 0xd02
test -d "/lib/modules/$(uname -r)/build" && echo "kernel headers: OK"
```

在容器中编译时，请使用与宿主机相同的内核版本，并提供匹配的
`/usr/src/kernels` 构建树。加载和测试仍然需要宿主机内核及相应的设备访问权限。

## 快速开始

在全新检出的仓库中编译并加载模块：

```bash
git clone https://gitcode.com/openeuler/cache_tuner.git
cd cache_tuner

make -C cache_stash
sudo insmod cache_stash/cache_stash.ko
```

确认模块和 sysfs 接口已经就绪：

```bash
lsmod | grep cache_stash
ls /sys/kernel/cache_stash/
cat /sys/kernel/cache_stash/status
```

`status` 会显示当前 LLC/L2 状态、选定的 L2 目标以及检测到的硬件寄存器。

## 配置缓存

接口位于 `/sys/kernel/cache_stash/`：

| 属性 | 权限 | 说明 |
| --- | --- | --- |
| `llc_enable` | 可读写 | `1` 启用 LLC stash，`0` 关闭。 |
| `l2_enable` | 可读写 | `1` 启用 L2 stash，`0` 关闭。 |
| `l2_target` | 可读写 | 读取或设置 L2 目标模式及核心编号。 |
| `status` | 只读 | 当前设置及已映射寄存器的详细信息。 |

`l2_target` 的格式为 `<use_specific> <core_id>`。使用 `0 0` 选择默认目标，
或使用 `1 <cpu>` 选择在线 CPU。

示例：

```bash
# 读取当前状态
cat /sys/kernel/cache_stash/llc_enable
cat /sys/kernel/cache_stash/l2_enable
cat /sys/kernel/cache_stash/l2_target

# 启用两种 stash，并选择默认 L2 目标
sudo sh -c 'echo 1 > /sys/kernel/cache_stash/llc_enable'
sudo sh -c 'echo 1 > /sys/kernel/cache_stash/l2_enable'
sudo sh -c 'echo "0 0" > /sys/kernel/cache_stash/l2_target'
```

写入操作会更新当前硬件拓扑下检测到的所有 cache-stash 寄存器。这些设置通过
模块控制，不是进程级配置接口；设置会立即生效，不会写入配置文件，也不会在
执行 `rmmod` 时自动恢复。

卸载模块：

```bash
sudo rmmod cache_stash
make -C cache_stash clean
```

## 运行测试

测试需要 root 权限，并要求模块已加载。测试会修改缓存设置，因此请仅在专用
测试机上运行：

```bash
# 加载 cache_stash 后，在仓库根目录运行
sudo bash cache_stash/test/test_functional.sh --skip-checks
sudo bash cache_stash/test/test_boundary.sh --skip-checks
sudo bash cache_stash/test/test_performance.sh --skip-checks

sudo rmmod cache_stash
```

测试套件包括：

- `test_functional.sh`：sysfs 属性、状态切换和并发访问。
- `test_boundary.sh`：非法输入和访问权限检查。
- `test_performance.sh`：sysfs 读写延迟测量。

每个脚本都会在当前目录生成结果日志。

## 常见问题

- **找不到内核构建树：** 安装与 `uname -r` 匹配的 `kernel-devel` 包，然后
  重新运行 `make`。
- **`insmod` 报错 `No such device`：** 当前架构或 CPU 型号不受支持。使用
  `sudo dmesg | tail` 查看具体原因。
- **缺少 `insmod` 或 `rmmod`：** 安装 `kmod`。
- **没有出现 `/sys/kernel/cache_stash/`：** 使用 `sudo dmesg | tail` 检查
  CPU 校验或寄存器映射是否报错。
- **容器中编译成功但加载失败：** 模块必须与运行中的宿主机内核匹配，并且
  必须运行在目标物理硬件上。

## 项目结构

```text
cache_stash/
├── Makefile
├── cache_stash.c       # 模块、寄存器映射和 sysfs 接口
├── cache_stash.h       # 硬件偏移量和寄存器位定义
└── test/               # 功能、边界和性能测试
```

## 许可证

参见 [LICENSE](LICENSE)。
