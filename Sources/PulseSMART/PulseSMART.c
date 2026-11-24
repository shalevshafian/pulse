// The header of this interface is in the SDK and Swift cannot import it.
#include "PulseSMART.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>
#include <string.h>

/// An external disk is left alone: asking it could wake it.
static int is_internal_nvme(io_service_t service) {
    int capable = 0, internal = 0;
    CFTypeRef p = IORegistryEntryCreateCFProperty(service, CFSTR(kIOPropertyNVMeSMARTCapableKey), NULL, 0);
    if (p) { capable = CFGetTypeID(p) == CFBooleanGetTypeID() && CFBooleanGetValue(p); CFRelease(p); }
    p = IORegistryEntryCreateCFProperty(service, CFSTR("Protocol Characteristics"), NULL, 0);
    if (p) {
        if (CFGetTypeID(p) == CFDictionaryGetTypeID()) {
            CFTypeRef where = CFDictionaryGetValue(p, CFSTR("Physical Interconnect Location"));
            internal = where && CFEqual(where, CFSTR("Internal"));
        }
        CFRelease(p);
    }
    return capable && internal;
}

static int read_service(io_service_t service, pulse_smart *out) {
    IOCFPlugInInterface **plugin = NULL;
    IONVMeSMARTInterface **smart = NULL;
    SInt32 score = 0;
    if (IOCreatePlugInInterfaceForService(service, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score) != kIOReturnSuccess || !plugin) return 1;
    int failed = 1;
    if ((*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&smart) == S_OK && smart) {
        NVMeSMARTData d;
        memset(&d, 0, sizeof d);
        if ((*smart)->SMARTReadData(smart, &d) == kIOReturnSuccess) {
            out->critical_warning = d.CRITICAL_WARNING;
            out->spare = d.AVAILABLE_SPARE;
            out->spare_threshold = d.AVAILABLE_SPARE_THRESHOLD;
            out->percent_used = d.PERCENTAGE_USED;
            out->units_written = d.DATA_UNITS_WRITTEN[0];
            out->media_errors = d.MEDIA_ERRORS[0];
            out->unsafe_shutdowns = d.UNSAFE_SHUTDOWNS[0];
            out->hours = d.POWER_ON_HOURS[0];
            failed = 0;
        }
        (*smart)->Release(smart);
    }
    IODestroyPlugInInterface(plugin);
    return failed;
}

int pulse_smart_internal(pulse_smart *out) {
    io_iterator_t it = 0;
    int failed = 1;
    memset(out, 0, sizeof *out);
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDevice"), &it) != KERN_SUCCESS) return 1;
    for (io_service_t s; failed && (s = IOIteratorNext(it)); IOObjectRelease(s))
        if (is_internal_nvme(s)) failed = read_service(s, out);
    IOObjectRelease(it);
    return failed;
}
