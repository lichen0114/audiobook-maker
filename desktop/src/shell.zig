//! Shell command assembly.
//!
//! The effects channel caps argv at 16 entries (`max_effect_argv`), which a
//! full `app.py` invocation blows past, and it exposes no env/cwd knobs. So
//! every backend spawn is routed through `/bin/sh -c "<command>"` (3 argv
//! entries): the command string carries the `cd`, the environment
//! assignments, and every quoted argument. This module builds that string
//! safely (POSIX single-quote escaping).

const std = @import("std");

/// A bounded, allocation-free string builder for shell commands.
pub const Cmd = struct {
    data: []u8,
    len: usize = 0,
    overflow: bool = false,

    pub fn init(buf: []u8) Cmd {
        return .{ .data = buf };
    }

    pub fn raw(self: *Cmd, s: []const u8) void {
        const room = self.data.len - self.len;
        if (s.len > room) {
            self.overflow = true;
            return;
        }
        @memcpy(self.data[self.len..][0..s.len], s);
        self.len += s.len;
    }

    fn byte(self: *Cmd, c: u8) void {
        self.raw(&[_]u8{c});
    }

    /// Append `s` wrapped in single quotes, escaping embedded single quotes
    /// as the canonical `'\''` sequence.
    pub fn quoted(self: *Cmd, s: []const u8) void {
        self.byte('\'');
        for (s) |c| {
            if (c == '\'') self.raw("'\\''") else self.byte(c);
        }
        self.byte('\'');
    }

    /// Append a leading space then the single-quoted token (argv element).
    pub fn arg(self: *Cmd, s: []const u8) void {
        self.byte(' ');
        self.quoted(s);
    }

    pub fn slice(self: *const Cmd) []const u8 {
        return self.data[0..self.len];
    }
};

test "Cmd quotes arguments and escapes single quotes" {
    var buf: [256]u8 = undefined;
    var c = Cmd.init(&buf);
    c.quoted("/usr/bin/python3");
    c.arg("--input");
    c.arg("/Users/x/My Book's.epub");
    try std.testing.expect(!c.overflow);
    try std.testing.expectEqualStrings(
        "'/usr/bin/python3' '--input' '/Users/x/My Book'\\''s.epub'",
        c.slice(),
    );
}

test "Cmd reports overflow instead of writing past the buffer" {
    var buf: [8]u8 = undefined;
    var c = Cmd.init(&buf);
    c.quoted("this is definitely longer than eight bytes");
    try std.testing.expect(c.overflow);
    try std.testing.expect(c.len <= buf.len);
}
