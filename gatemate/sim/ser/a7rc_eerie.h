// SPDX-License-Identifier: CERN-OHL-P-2.0
// TASK-6170: what openPCIE_BFM's Artix-7 RC model expects of the pci_eerie W8 endpoint
// (-DA7RC_EP_EXPECT='"a7rc_eerie.h"'): IDs and BAR sizes, as gatemate/rtl/eerie_w8_core.v.
#ifndef A7RC_EERIE_H
#define A7RC_EERIE_H

#define EP_VENDOR_ID          0x1397
#define EP_DEVICE_ID          0x4D32

// BAR0 4 KB, 32-bit memory, not prefetchable; BAR1-5 not implemented
static const uint32_t ep_bar_size[FW_NUM_BARS] = {0xfffff000, 0x00000000, 0x00000000,
                                                  0x00000000, 0x00000000, 0x00000000};

// eerie_bar0_app: 0x00..0x08 read-only (ID, clock count, status), 0x0C..0x3C scratch, mirrored
#endif
