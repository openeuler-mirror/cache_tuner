#ifndef _LLC_STASH_CONFIG_H
#define _LLC_STASH_CONFIG_H

/*
 * Cache Stash Control Driver Configuration Header
 *
 * This file contains configuration options that can be modified
 * to adapt the driver to different hardware platforms.
 */

/* Address calculation parameters */
#define SOCKET_BASE_INTERVAL     0x200000000000UL  /* 2TB per socket */
#define IODIE_OFFSET_INTERVAL    0x8000000000UL    /* 512GB per IOdie */
#define PCIE_CORE_OFFSET_1       0x101000000UL     /* First PCIe core offset */
#define PCIE_CORE_OFFSET_2       0x302000000UL     /* Second PCIe core offset */
#define PCIE_CORE_OFFSET_3       0x303000000UL     /* Third PCIe core offset */
#define PCIE_SUBMODULE_OFFSET    0x4000UL          /* 16KB per submodule */
#define IOB_RX_REG_OFFSET        0x1C30UL          /* IOB_RX register offset for LLC stash */
#define IOB_RX_TARGET_REG_OFFSET 0x1C38UL          /* IOB_RX register offset for L2 stash target */
#define IODIE_NUM                2
#define CORES_PER_IODIE          3                 /* Number of cores per IOdie */

/* Bit positions for LLC stash control */
#define LLC_STASH_FIELD_START_BIT    14                /* Start bit for LLC stash field */
#define LLC_STASH_FIELD_WIDTH        2                 /* Width of LLC stash field */
#define LLC_STASH_FIELD_MASK         0x3               /* Mask for LLC stash field */

/* Bit positions for L2 stash control */
#define L2_STASH_ENABLE_BIT          11                /* Bit 11 for L2 stash enable */
#define L2_STASH_TARGET_START_BIT    12                /* Start bit for L2 stash target field */
#define L2_STASH_TARGET_WIDTH        3                 /* Width of L2 stash target field */
#define L2_STASH_TARGET_MASK         0x7               /* Mask for L2 stash target field */
#define L2_STASH_CORE_START_BIT      16                /* Start bit for L2 stash core field */
#define L2_STASH_CORE_WIDTH          15                /* Width of L2 stash core field (15 bits for core value) */
#define L2_STASH_CORE_MASK           0x7FFF            /* Mask for L2 stash core field (15 bits) */

/* Register values for enabling/disabling LLC stash */
#define LLC_STASH_ENABLE_VAL     0x0               /* Bits 15:14 = 0b00 */
#define LLC_STASH_DISABLE_VAL    0x3               /* Bits 15:14 = 0b11 */

/* Register values for L2 stash */
#define L2_STASH_ENABLE_VAL      0x1               /* Bit 11 = 0b1 */
#define L2_STASH_DISABLE_VAL     0x0               /* Bit 11 = 0b0 */
#define L2_STASH_TARGET_DEFAULT  0x4               /* Default target value when no specific core */
#define L2_STASH_TARGET_SPECIFIC 0x7               /* Target value when specific core is set */

#endif /* _LLC_STASH_CONFIG_H */