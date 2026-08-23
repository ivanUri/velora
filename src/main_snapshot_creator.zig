// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const js = @import("koko").js;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;

    var platform = try js.Platform.init();
    defer platform.deinit();

    const snapshot = try js.Snapshot.create();
    defer snapshot.deinit();

    var is_stdout = true;
    var file = std.Io.File.stdout();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next(); // executable name
    if (args.next()) |n| {
        is_stdout = false;
        file = try std.Io.Dir.cwd().createFile(init.io, n, .{});
    }
    defer if (!is_stdout) {
        file.close(init.io);
    };

    var buffer: [4096]u8 = undefined;
    var writer = file.writer(init.io, &buffer);
    try snapshot.write(&writer.interface);
    try writer.end();
}
