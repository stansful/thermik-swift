// CThermikSPI.h — Thermik (MIT)
// 1) Private IOHIDEventSystem SPI. Exported by IOKit.framework (present in the SDK's IOKit.tbd) and declared in
//    Apple's open-source IOHIDFamily (APSL 2.0): IOHIDEventSystemClient.h, IOHIDServiceClient.h, IOHIDEvent.h.
//    Used by Stats, macmon, iSMC, Hot since 2020. Keep every call failure-tolerant (SENS §3, R8).
// 2) Public NVMe SMART plug-in header (public SDK header, but not exported by the Swift IOKit module; SYS §6.1).
#ifndef CTHERMIKSPI_H
#define CTHERMIKSPI_H

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>

CF_ASSUME_NONNULL_BEGIN

/// Opaque HID event (a CF type). CF_BRIDGED_TYPE lets Swift manage it with ARC.
typedef struct CF_BRIDGED_TYPE(id) __IOHIDEvent * IOHIDEventRef;

/// FULL client. The public IOHIDEventSystemClientCreateSimpleClient enumerates services but
/// IOHIDServiceClientCopyEvent returns NULL for every service on it (verified, SENS §3.1).
CF_RETURNS_RETAINED IOHIDEventSystemClientRef _Nullable
IOHIDEventSystemClientCreate(CFAllocatorRef _Nullable allocator);

int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);

/// type: kIOHIDEventTypeTemperature = 15, kIOHIDEventTypePower = 25. options = 0, timestamp = 0.
CF_RETURNS_RETAINED IOHIDEventRef _Nullable
IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);

/// field = IOHIDEventFieldBase(type) = type << 16.
double IOHIDEventGetFloatValue(IOHIDEventRef event, uint32_t field);

CF_ASSUME_NONNULL_END

#endif
