//! Apple-Silicon host detection. The low-memory profile and device defaults
//! are resolved at boot from the detection shell script (sysctl hw.memsize),
//! not here — this only needs the compile-time architecture fact.

const std = @import("std");
const builtin = @import("builtin");

pub fn isAppleSilicon() bool {
    return builtin.target.os.tag == .macos and builtin.target.cpu.arch == .aarch64;
}

/// MPS is the default on Apple Silicon; the boot script flips it off for
/// 8 GB machines by seeding `Model.low_mem`.
pub fn defaultUseMps() bool {
    return isAppleSilicon();
}

test "apple host detection is total" {
    _ = isAppleSilicon();
    _ = defaultUseMps();
}
