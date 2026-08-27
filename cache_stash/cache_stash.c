#include <asm/cputype.h>
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/fs.h>
#include <linux/device.h>
#include <linux/slab.h>
#include <linux/io.h>
#include <linux/sysfs.h>
#include <linux/string.h>
#include <linux/uaccess.h>
#include <linux/types.h>
#include <linux/pci.h>
#include <linux/topology.h>
#include <linux/cpumask.h>
#include <linux/mutex.h>
#include "cache_stash.h"

/*
 * Compatibility with older kernels: newer openEuler kernels name this CPU
 * model MIDR_HISI_LINXICORE9100, while older ones (e.g. the 4.19-based
 * openEuler 20.03 LTS) name the same model MIDR_HISI_TSV200. Both resolve
 * to MIDR_CPU_MODEL(0x48, 0xD02), so fall back to the raw value when the
 * kernel headers lack the new name.
 */
#ifndef MIDR_HISI_LINXICORE9100
#define MIDR_HISI_LINXICORE9100 MIDR_CPU_MODEL(0x48, 0xD02)
#endif

/* Constants for address calculation */
#define PCIE_CORE_OFFSETS {PCIE_CORE_OFFSET_1, PCIE_CORE_OFFSET_2, PCIE_CORE_OFFSET_3}  /* 3 cores per IOdie */

/* Buffer size constant for input validation */
#define MAX_INPUT_EXTRA_LENGTH 16  // Maximum length for capturing extra input beyond expected values

struct kobject *llc_stash_kobj;

/* Mutex to protect concurrent access to shared registers */
static DEFINE_MUTEX(stash_mutex);

/* Flags to track current state of stashes */
static bool llc_stash_enabled = false;
static bool l2_stash_enabled = false;
static bool l2_use_specific_core = false;  /* Whether to use a specific core */
static int l2_stash_to_core = 0;           /* Specific core to stash to when enabled */

/* Structure to hold all calculated addresses */
struct reg_addr {
    unsigned long addr;
    void __iomem *vaddr;
};

/* Arrays to store all addresses to modify */
static struct reg_addr *llc_enable_addresses = NULL;
static struct reg_addr *l2_target_addresses = NULL;      /* L2 stash target */
static struct reg_addr *l2_enable_addresses = NULL; /* L2 stash enable */
static int llc_enable_total_addresses = 0;
static int l2_target_total_addresses = 0;
static int l2_enable_total_addresses = 0;

/*
 * Verify if the current CPU is ARM and has the correct partID (MIDR_HISI_LINXICORE9100)
 */
static bool verify_cpu_part(void)
{
#ifdef CONFIG_ARM64
    u64 midr = read_cpuid_id();
    u64 cpu_model = midr & MIDR_CPU_MODEL_MASK;
    
    if (cpu_model == MIDR_HISI_LINXICORE9100) {
        pr_info("Cache Stash Control: Verified CPU model MIDR_HISI_LINXICORE9100\n");
        return true;
    } else {
        pr_err("Cache Stash Control: Unsupported CPU model 0x%llx, "
               "only MIDR_HISI_LINXICORE9100 is supported\n", cpu_model);
        return false;
    }
#else
    pr_err("Cache Stash Control: Not running on ARM64 architecture\n");
    return false;
#endif
}

/*
 * Helper function to calculate the address based on the formula:
 * Register address = socket base + IODie offset + PCIe core offset + submodule offset + register offset
 */
static unsigned long calculate_reg_address(int socket_id, int iodie_id, unsigned long core_offset)
{
    unsigned long addr = 0;
    
    addr += (unsigned long)socket_id * SOCKET_BASE_INTERVAL;  /* Socket base */
    addr += (unsigned long)iodie_id * IODIE_OFFSET_INTERVAL;  /* IODie offset */
    addr += core_offset;                                      /* PCIe core offset */
    addr += PCIE_SUBMODULE_OFFSET;                            /* Submodule offset */
    addr += IOB_RX_REG_OFFSET;                                /* Register offset */
    
    return addr;
}

/*
 * Helper function to count number of sockets by looking for PCI devices
 * In a real implementation, this might need to be adapted based on the specific hardware
 */
static int detect_socket_count(void)
{
    int max_socket_id = -1;
    int cpu;
    
    // Iterate through all CPUs to find the maximum socket ID
    for_each_possible_cpu(cpu) {
        int socket_id = topology_physical_package_id(cpu);
        if (socket_id > max_socket_id) {
            max_socket_id = socket_id;
        }
    }
    
    // Socket IDs start from 0, so the count is max_socket_id + 1
    return max_socket_id + 1;
}

static void cleanup_mapped_addresses(int failed_index)
{
    int i;
    
    // Clean up all successfully mapped addresses up to the failed index
    // Important: l2_enable_addresses reuses the virtual address mappings from llc_enable_addresses,
    // so we must NOT call iounmap() on l2_enable_addresses to avoid double-unmap.
    for (i = 0; i < failed_index; i++) {
        if (l2_target_addresses[i].vaddr) {
            iounmap(l2_target_addresses[i].vaddr);
            l2_target_addresses[i].vaddr = NULL;
        }
        if (llc_enable_addresses[i].vaddr) {
            iounmap(llc_enable_addresses[i].vaddr);
            llc_enable_addresses[i].vaddr = NULL;
        }
        if (l2_enable_addresses[i].vaddr) {
            l2_enable_addresses[i].vaddr = NULL;
        }
    }
}

static void free_address_arrays(void)
{
    // Free the memory for the arrays
    if (l2_enable_addresses) {
        kfree(l2_enable_addresses);
        l2_enable_addresses = NULL;
    }
    if (l2_target_addresses) {
        kfree(l2_target_addresses);
        l2_target_addresses = NULL;
    }
    if (llc_enable_addresses) {
        kfree(llc_enable_addresses);
        llc_enable_addresses = NULL;
    }
}

static int allocate_address_arrays(void)
{
    // Allocate memory for LLC addresses
    llc_enable_addresses = kcalloc(llc_enable_total_addresses, sizeof(struct reg_addr), GFP_KERNEL);
    if (!llc_enable_addresses) {
        pr_err("Cache Stash Control: Failed to allocate memory for LLC addresses\n");
        return -ENOMEM;
    }
    
    // Allocate memory for L2 addresses
    l2_target_addresses = kcalloc(l2_target_total_addresses, sizeof(struct reg_addr), GFP_KERNEL);
    if (!l2_target_addresses) {
        pr_err("Cache Stash Control: Failed to allocate memory for L2 addresses\n");
        free_address_arrays();
        return -ENOMEM;
    }
    
    // Allocate memory for L2 enable addresses
    l2_enable_addresses = kcalloc(l2_enable_total_addresses, sizeof(struct reg_addr), GFP_KERNEL);
    if (!l2_enable_addresses) {
        pr_err("Cache Stash Control: Failed to allocate memory for L2 enable addresses\n");
        free_address_arrays();
        return -ENOMEM;
    }
    
    return 0;
}

static int handle_single_core_mapping(int socket, int iodie, int core_idx, int addr_idx)
{
    const unsigned long pcie_core_offsets[] = PCIE_CORE_OFFSETS;
    unsigned long calc_addr;
    unsigned long l2_calc_addr;
    
    calc_addr = calculate_reg_address(socket, iodie, pcie_core_offsets[core_idx]);
    
    // Map LLC stash register
    llc_enable_addresses[addr_idx].addr = calc_addr;
    llc_enable_addresses[addr_idx].vaddr = ioremap(calc_addr, sizeof(u32));
    if (!llc_enable_addresses[addr_idx].vaddr) {
        pr_err("Cache Stash Control: Failed to map LLC register at 0x%lx\n", calc_addr);
        return -ENOMEM;
    }
    
    // Map L2 stash target register
    l2_calc_addr = calc_addr - IOB_RX_REG_OFFSET + IOB_RX_TARGET_REG_OFFSET;
    l2_target_addresses[addr_idx].addr = l2_calc_addr;
    l2_target_addresses[addr_idx].vaddr = ioremap(l2_calc_addr, sizeof(u32));
    if (!l2_target_addresses[addr_idx].vaddr) {
        pr_err("Cache Stash Control: Failed to map L2 target register at 0x%lx\n", l2_calc_addr);
        // Clean up LLC mapping before returning
        if (llc_enable_addresses[addr_idx].vaddr) {
            iounmap(llc_enable_addresses[addr_idx].vaddr);
            llc_enable_addresses[addr_idx].vaddr = NULL;
        }
        return -ENOMEM;
    }
    
    // L2 stash enable register shares the same physical address as LLC stash register
    // So reuse the LLC virtual address mapping for L2 enable to avoid redundant ioremap
    l2_enable_addresses[addr_idx].addr = calc_addr;
    l2_enable_addresses[addr_idx].vaddr = llc_enable_addresses[addr_idx].vaddr;
    
    return 0;
}

static int map_register_addresses(int num_sockets)
{
    int i, j, k;
    const int num_cores = CORES_PER_IODIE;
    int addr_idx = 0;
    int ret;
    
    for (i = 0; i < num_sockets; i++) {
        for (j = 0; j < IODIE_NUM; j++) {
            for (k = 0; k < num_cores; k++) {
                ret = handle_single_core_mapping(i, j, k, addr_idx);
                if (ret) {
                    cleanup_mapped_addresses(addr_idx);
                    return ret;
                }
                addr_idx++;
            }
        }
    }
    
    return 0;
}

/*
 * Initialize address arrays based on hardware topology for both LLC and L2 stashes
 */
static int initialize_addresses(void)
{
    int num_sockets;
    int ret;
    
    num_sockets = detect_socket_count();
    pr_info("Cache Stash Control: Detected %d sockets\n", num_sockets);
    
    // Calculate total number of addresses we need to handle
    llc_enable_total_addresses = num_sockets * IODIE_NUM * CORES_PER_IODIE;
    l2_target_total_addresses = llc_enable_total_addresses;
    l2_enable_total_addresses = llc_enable_total_addresses;
    
    // Step 1: Allocate memory for all address arrays
    ret = allocate_address_arrays();
    if (ret)
        return ret;
    
    // Step 2: Map all register addresses
    ret = map_register_addresses(num_sockets);
    if (ret) {
        free_address_arrays();
        return ret;
    }
    
    return 0;
}

static void initialize_register_states(void)
{
    u32 reg_val;
    unsigned int stash_field, l2_enable_bit, l2_target_field, l2_core_field;
    
    if (llc_enable_total_addresses > 0 && llc_enable_addresses[0].vaddr) {
        reg_val = readl(llc_enable_addresses[0].vaddr);
        stash_field = (reg_val >> LLC_STASH_FIELD_START_BIT) & LLC_STASH_FIELD_MASK;
        
        // Determine the current state based on the register's stash field
        // If stash_field equals LLC_STASH_ENABLE_VAL(0), then enable; otherwise disable
        llc_stash_enabled = (stash_field == LLC_STASH_ENABLE_VAL);
        
        pr_info("Cache Stash Control: Initial LLC register value: 0x%08x, stash field: 0x%x, enabled: %s\n",
                reg_val, stash_field, llc_stash_enabled ? "true" : "false");
    }
    
    if (l2_enable_total_addresses > 0 && l2_enable_addresses[0].vaddr) {
        reg_val = readl(l2_enable_addresses[0].vaddr);
        l2_enable_bit = (reg_val >> L2_STASH_ENABLE_BIT) & 0x1;
        
        // L2 stash enable state is determined by bit 11 of register 0x1C50
        l2_stash_enabled = (l2_enable_bit == L2_STASH_ENABLE_VAL);
        
        pr_info("Cache Stash Control: Initial L2 enable register value: 0x%08x, enable bit: 0x%x, enabled: %s\n",
                reg_val, l2_enable_bit, l2_stash_enabled ? "true" : "false");
    }
    
    if (l2_target_total_addresses > 0 && l2_target_addresses[0].vaddr) {
        reg_val = readl(l2_target_addresses[0].vaddr);
        l2_target_field = (reg_val >> L2_STASH_TARGET_START_BIT) & L2_STASH_TARGET_MASK;
        l2_core_field = (reg_val >> L2_STASH_CORE_START_BIT) & L2_STASH_CORE_MASK;
        
        // Check if using a specific core
        if (l2_target_field == L2_STASH_TARGET_SPECIFIC) {
            l2_use_specific_core = true;
            l2_stash_to_core = l2_core_field;
        } else if (l2_target_field == L2_STASH_TARGET_DEFAULT) {
            l2_use_specific_core = false;
        } else {
            l2_use_specific_core = false;  // Default behavior
        }
        
        pr_info("Cache Stash Control: Initial L2 target register value: 0x%08x, "
                "target: 0x%x, core: 0x%x, use specific core: %s\n",
                reg_val, l2_target_field, l2_core_field, l2_use_specific_core ? "true" : "false");
    }
}

/*
 * Helper function to write to all LLC stash control registers
 */
static void write_llc_stash_registers(unsigned int val)
{
    int i;
    u32 reg_val = 0;  /* Initialized: read by pr_debug even when the loop body never runs */

    mutex_lock(&stash_mutex);
    
    for (i = 0; i < llc_enable_total_addresses; i++) {
        /* Read current register value */
        reg_val = readl(llc_enable_addresses[i].vaddr);
        
        /* Clear bits for LLC stash, preserve other bits including L2 stash fields */
        reg_val &= ~(LLC_STASH_FIELD_MASK << LLC_STASH_FIELD_START_BIT);
        
        /* Set new value for bits, preserving other bits */
        reg_val |= ((val & LLC_STASH_FIELD_MASK) << LLC_STASH_FIELD_START_BIT);
        
        /* Write back the modified value */
        writel(reg_val, llc_enable_addresses[i].vaddr);
        
        /* Ensure the write operation completes before continuing */
        wmb();
        readl(llc_enable_addresses[i].vaddr);  // Read back to ensure write completed
    }
    pr_debug("Cache Stash: LLC registers updated value 0x%08x\n", reg_val);
    
    mutex_unlock(&stash_mutex);
}

/*
 * Helper function to write to all L2 stash enable registers (bit 11)
 */
static void write_l2_stash_enable_registers(unsigned int val)
{
    int i;
    u32 reg_val = 0;  /* Initialized: read by pr_debug even when the loop body never runs */

    mutex_lock(&stash_mutex);
    
    for (i = 0; i < l2_enable_total_addresses; i++) {
        /* Read current register value */
        reg_val = readl(l2_enable_addresses[i].vaddr);
        
        /* Clear bit for L2 stash enable, preserve other bits including LLC stash fields */
        reg_val &= ~(1U << L2_STASH_ENABLE_BIT);
        
        /* Set new value for bit, preserving other bits */
        reg_val |= ((val & 0x1) << L2_STASH_ENABLE_BIT);
        
        /* Write back the modified value */
        writel(reg_val, l2_enable_addresses[i].vaddr);
        
        /* Ensure the write operation completes before continuing */
        wmb();
        readl(l2_enable_addresses[i].vaddr);  // Read back to ensure write completed
    }
    pr_debug("L2 Stash Enable: registers updated value 0x%08x\n", reg_val);
    
    mutex_unlock(&stash_mutex);
}

/*
 * Helper function to write to all L2 stash target core registers (bits 14:12 and 30:16)
 */
static void write_l2_stash_target_registers(unsigned int target_val, unsigned int core_val)
{
    int i;
    u32 reg_val = 0;  /* Initialized: read by pr_debug even when the loop body never runs */
    
    mutex_lock(&stash_mutex);
    for (i = 0; i < l2_target_total_addresses; i++) {
        /* Read current register value */
        reg_val = readl(l2_target_addresses[i].vaddr);
        
        /* Clear bits for L2 stash target, preserve other bits including LLC stash fields */
        reg_val &= ~(L2_STASH_TARGET_MASK << L2_STASH_TARGET_START_BIT);
        
        /* Set new value for bits , preserving other bits */
        reg_val |= ((target_val & L2_STASH_TARGET_MASK) << L2_STASH_TARGET_START_BIT);
        
        /* Clear bits for L2 stash core value */
        reg_val &= ~(L2_STASH_CORE_MASK << L2_STASH_CORE_START_BIT);
        
        /* Set new value for bits if core_val is non-zero */
        if (core_val != 0) {
            reg_val |= ((core_val & L2_STASH_CORE_MASK) << L2_STASH_CORE_START_BIT);
        }
        /* If core_val is 0, the bits remain cleared (set to 0) */
        
        /* Write back the modified value */
        writel(reg_val, l2_target_addresses[i].vaddr);
        
        /* Ensure the write operation completes before continuing */
        wmb();
        readl(l2_target_addresses[i].vaddr);  // Read back to ensure write completed
    }
    pr_debug("L2 Stash Target: registers updated value 0x%08x (target: 0x%x, core: 0x%x)\n",
             reg_val,
             (reg_val >> L2_STASH_TARGET_START_BIT) & L2_STASH_TARGET_MASK,
             (reg_val >> L2_STASH_CORE_START_BIT) & L2_STASH_CORE_MASK);
    mutex_unlock(&stash_mutex);
}

/*
 * Sysfs attribute for enabling/disabling LLC stash
 */
static ssize_t llc_enable_show(struct kobject *kobj, struct kobj_attribute *attr,
                               char *buf)
{
    return sprintf(buf, "%d\n", llc_stash_enabled ? 1 : 0);
}

static ssize_t llc_enable_store(struct kobject *kobj, struct kobj_attribute *attr,
                                const char *buf, size_t count)
{
    bool new_state;
    int ret;

    ret = kstrtobool(buf, &new_state);
    if (ret)
        return ret;

    if (new_state == llc_stash_enabled)
        return count;

    if (new_state) {
        /* Enable LLC stash - set bits 15:14 to 0 */
        write_llc_stash_registers(LLC_STASH_ENABLE_VAL);
        llc_stash_enabled = true;
    } else {
        /* Disable LLC stash - set bits 15:14 to 3 */
        write_llc_stash_registers(LLC_STASH_DISABLE_VAL);
        llc_stash_enabled = false;
    }

    return count;
}

/*
 * Sysfs attribute for enabling/disabling L2 stash
 */
static ssize_t l2_enable_show(struct kobject *kobj, struct kobj_attribute *attr,
                              char *buf)
{
    return sprintf(buf, "%d\n", l2_stash_enabled ? 1 : 0);
}

static ssize_t l2_enable_store(struct kobject *kobj, struct kobj_attribute *attr,
                               const char *buf, size_t count)
{
    bool new_state;
    int ret;

    ret = kstrtobool(buf, &new_state);
    if (ret)
        return ret;

    if (new_state == l2_stash_enabled)
        return count;

    if (new_state) {
        /* Enable L2 stash - set bit 11 to 1 */
        write_l2_stash_enable_registers(L2_STASH_ENABLE_VAL);
        l2_stash_enabled = true;
    } else {
        /* Disable L2 stash - set bit 11 to 0 */
        write_l2_stash_enable_registers(L2_STASH_DISABLE_VAL);
        l2_stash_enabled = false;
    }

    return count;
}

/*
 * Sysfs attribute for configuring L2 stash target core
 */
static ssize_t l2_target_show(struct kobject *kobj, struct kobj_attribute *attr,
                              char *buf)
{
    return sprintf(buf, "%d %d\n", l2_use_specific_core ? 1 : 0, l2_stash_to_core);
}

static ssize_t l2_target_store(struct kobject *kobj, struct kobj_attribute *attr,
                               const char *buf, size_t count)
{
    int ret;
    int use_specific, core_value;
    char remaining[MAX_INPUT_EXTRA_LENGTH]; // Used to capture extra input
    const int EXPECTED_INPUT_COUNT = 2; // Number of expected input values (use_specific and core_value)
    
    /* Check first if there are exactly two integers */
    ret = sscanf(buf, "%d %d %15s", &use_specific, &core_value, remaining);
    // Only accept when there are exactly two numbers and no extra content
    if (ret != EXPECTED_INPUT_COUNT) {
        pr_err("L2 Stash Target: Invalid input format\n");
        return -EINVAL;
    }
    
    // Validate the range of use_specific and core_value
    if (use_specific < 0 || use_specific > 1) {
        pr_err("L2 Stash Target: Invalid use_specific value\n");
        return -EINVAL;
    }
    if (core_value < 0 || core_value > L2_STASH_CORE_MASK) {
        pr_err("L2 Stash Target: Invalid core_value value\n");
        return -EINVAL;
    }

    // Check if the target core number exceeds the total number of CPUs in the system
    if (use_specific && core_value >= num_online_cpus()) {
        pr_err("L2 Stash Target: Requested core %d exceeds total number of online CPUs %d\n",
               core_value, num_online_cpus());
        return -EINVAL;
    }

    if (use_specific) {
        /* Update to specific target core */
        write_l2_stash_target_registers(L2_STASH_TARGET_SPECIFIC, core_value);
        l2_use_specific_core = true;
        l2_stash_to_core = core_value;
    } else {
        /* Update to default target regardless of L2 stash enabled status */
        write_l2_stash_target_registers(L2_STASH_TARGET_DEFAULT, core_value);
        l2_use_specific_core = false;
        l2_stash_to_core = core_value;
    }

    return count;
}

static int format_llc_register_info(char *buf, int offset)
{
    int i, len = 0;
    u32 reg_val;
    unsigned int stash_field;
    
    if (!llc_enable_addresses || llc_enable_total_addresses <= 0) {
        len += sprintf(buf + offset, "No LLC addresses initialized\n");
    } else {
        for (i = 0; i < llc_enable_total_addresses; i++) {
            if (llc_enable_addresses[i].vaddr) {
                reg_val = readl(llc_enable_addresses[i].vaddr);
                stash_field = (reg_val >> LLC_STASH_FIELD_START_BIT) & LLC_STASH_FIELD_MASK;
                len += sprintf(buf + offset + len, "LLC Register 0x%lx: 0x%08x (stash field: 0x%x)\n",
                               llc_enable_addresses[i].addr, reg_val, stash_field);
            } else {
                len += sprintf(buf + offset + len, "LLC Register 0x%lx: unmapped\n", llc_enable_addresses[i].addr);
            }
        }
    }
    
    return len;
}

static int format_l2_register_info(char *buf, int offset)
{
    int i, len = 0;
    u32 reg_val;
    unsigned int l2_target_field, l2_core_field;
    
    if (!l2_target_addresses || l2_target_total_addresses <= 0) {
        len += sprintf(buf + offset, "No L2 addresses initialized\n");
    } else {
        for (i = 0; i < l2_target_total_addresses && i < l2_enable_total_addresses; i++) {
            if (l2_enable_addresses && l2_enable_addresses[i].vaddr &&
                l2_target_addresses && l2_target_addresses[i].vaddr) {
                reg_val = readl(l2_target_addresses[i].vaddr);
                l2_target_field = (reg_val >> L2_STASH_TARGET_START_BIT) & L2_STASH_TARGET_MASK;
                l2_core_field = (reg_val >> L2_STASH_CORE_START_BIT) & L2_STASH_CORE_MASK;
                len += sprintf(buf + offset + len, "L2 Register 0x%lx: 0x%08x "
                               "(use target field: 0x%x, target core field: 0x%x)\n",
                               l2_target_addresses[i].addr, reg_val, l2_target_field, l2_core_field);
            } else {
                len += sprintf(buf + offset + len, "L2 Register 0x%lx: unmapped\n",
                               l2_target_addresses ? l2_target_addresses[i].addr : 0);
            }
        }
    }
    
    return len;
}

/*
 * Sysfs attribute for checking the status of cache stashes
 */
static ssize_t status_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
    int len = 0;
    
    mutex_lock(&stash_mutex);
    
    len = sprintf(buf, "Current LLC Stash Status: %s\n"
                  "Current L2 Stash Status: %s\n"
                  "Current L2 Use Specific Core: %s\n"
                  "Current L2 Stash Target Core: %d\n"
                  "Total LLC addresses controlled: %d\n"
                  "Total L2 addresses controlled: %d\n\nLLC Register Details:\n",
                  llc_stash_enabled ? "Enabled" : "Disabled",
                  l2_stash_enabled ? "Enabled" : "Disabled",
                  l2_use_specific_core ? "Yes" : "No",
                  l2_stash_to_core,
                  llc_enable_total_addresses,
                  l2_target_total_addresses);
    
    // Format LLC register information
    len += format_llc_register_info(buf, len);
    
    // Add L2 section header
    len += sprintf(buf + len, "\nL2 Register Details:\n");
    
    // Format L2 register information
    len += format_l2_register_info(buf, len);
    
    mutex_unlock(&stash_mutex);
    return len;
}

/* Define sysfs attributes */
static struct kobj_attribute llc_enable_attr = __ATTR_RW(llc_enable);
static struct kobj_attribute l2_enable_attr = __ATTR_RW(l2_enable);
static struct kobj_attribute l2_target_attr = __ATTR_RW(l2_target);
static struct kobj_attribute status_attr = __ATTR_RO(status);

/* Create attribute group for sysfs */
static struct attribute *attrs[] = {
    &llc_enable_attr.attr,
    &l2_enable_attr.attr,
    &l2_target_attr.attr,
    &status_attr.attr,
    NULL,
};

static struct attribute_group attr_group = {
    .attrs = attrs,
};

/*
 * Module initialization function
 */
static int __init cache_stash_init(void)
{
    int ret;

    pr_info("Cache Stash Control Driver: Initializing...\n");

    /* Verify CPU architecture and part ID */
    if (!verify_cpu_part()) {
        pr_err("Cache Stash Control Driver: CPU verification failed, exiting\n");
        return -ENODEV;
    }

    /* Create a kobject under /sys/kernel/ */
    llc_stash_kobj = kobject_create_and_add("cache_stash", kernel_kobj);
    if (!llc_stash_kobj) {
        pr_err("Cache Stash Control Driver: Failed to create kobject\n");
        return -ENOMEM;
    }

    /* Initialize addresses based on hardware topology */
    ret = initialize_addresses();
    if (ret) {
        kobject_put(llc_stash_kobj);
        return ret;
    }

    /* Determine initial state based on actual register values */
    initialize_register_states();

    /* Create sysfs files */
    ret = sysfs_create_group(llc_stash_kobj, &attr_group);
    if (ret) {
        pr_err("Cache Stash Control Driver: Failed to create sysfs group\n");
        
        /* Clean up mappings and kobject */
        cleanup_mapped_addresses(llc_enable_total_addresses);
        free_address_arrays();
        kobject_put(llc_stash_kobj);
        return ret;
    }

    pr_info("Cache Stash Control Driver: Initialized successfully with %d LLC and %d L2 addresses\n",
            llc_enable_total_addresses, l2_target_total_addresses);
    return 0;
}

/*
 * Module exit function
 */
static void __exit cache_stash_exit(void)
{
    pr_info("Cache Stash Control Driver: Unloading...\n");

    /* Remove sysfs group */
    if (llc_stash_kobj)
        sysfs_remove_group(llc_stash_kobj, &attr_group);

    cleanup_mapped_addresses(llc_enable_total_addresses);
    free_address_arrays();

    /* Free kobject */
    if (llc_stash_kobj)
        kobject_put(llc_stash_kobj);

    pr_info("Cache Stash Control Driver: Unloaded\n");
}

module_init(cache_stash_init);
module_exit(cache_stash_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("YangYunYi");
MODULE_DESCRIPTION("Cache Stash Control Driver with Dynamic Address Calculation");
MODULE_VERSION("2.0");