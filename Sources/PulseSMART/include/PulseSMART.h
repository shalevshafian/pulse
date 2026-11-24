#ifndef PULSE_SMART_H
#define PULSE_SMART_H
#include <stdint.h>

typedef struct {
    uint8_t critical_warning;
    uint8_t spare, spare_threshold, percent_used;
    /// In thousands of 512-byte blocks.
    uint64_t units_written, media_errors, unsafe_shutdowns, hours;
} pulse_smart;

/// Reads the NVMe health log of the Mac's own disk. Nothing is written and no rights are needed.
/// 0 on success; anything else when there is no such disk or it does not answer.
int pulse_smart_internal(pulse_smart *out);
#endif
