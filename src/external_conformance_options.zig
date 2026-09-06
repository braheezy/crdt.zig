//! Direct-`zig test` fallback for the external corpus import.
//!
//! The normal build injects the checked-in research corpus through
//! `build_options`; keeping this small fallback means the source module still
//! compiles when invoked directly without the build script.

const std = @import("std");

pub const available = false;
pub const full = false;
pub const trace_index = std.math.maxInt(usize);
pub const json = "[]";
