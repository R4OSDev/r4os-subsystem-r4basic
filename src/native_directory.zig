//! BASIC's live ordinal contract over the native generation/revision cursor.
//! This value stays at its installed host address while a scan is active.
const std = @import("std");
const r4os = @import("r4os");

pub fn Reader(comptime Files: type, comptime Iterator: type) type {
    return struct {
        path: ?r4os.AbsoluteFilePath = null,
        iterator: ?Iterator = null,
        next_index: u32 = 0,
        const Self = @This();

        pub fn invalidate(self: *Self) void {
            self.iterator = null;
            self.path = null;
            self.next_index = 0;
        }

        pub fn read(self: *Self, files: Files, path: []const u8, index: u32, out: []u8) r4os.app_storage.DirectoryNext {
            if (self.path == null or !std.ascii.eqlIgnoreCase(self.path.?.bytes(), path) or
                index == 0 or index != self.next_index or self.iterator == null)
            {
                self.invalidate();
                self.path = r4os.AbsoluteFilePath.parse(path) catch return .{ .failure = r4os.abi.file_metadata2_error_invalid };
                self.iterator = files.iterate(self.path.?.asZ());
            }
            while (true) {
                const result = self.iterator.?.next(out);
                switch (result) {
                    .entry => {
                        const current = self.next_index;
                        self.next_index +|= 1;
                        if (current == index) return result;
                    },
                    .end, .failure => {
                        // A namespace restart is an error of this operation;
                        // never silently publish a suffix of a fresh scan.
                        self.invalidate();
                        return result;
                    },
                }
            }
        }
    };
}
