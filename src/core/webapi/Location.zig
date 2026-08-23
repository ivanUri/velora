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
const runtime_io = @import("../../support/io.zig");
const js = @import("../js/js.zig");

const URL = @import("URL.zig");
const U = @import("../browser/URL.zig");
const Frame = @import("../browser/Frame.zig");
const log = @import("../../support/log.zig");

const Location = @This();

_url: *URL,
// Location is tied to one browsing context. Calls through another WindowProxy
// must continue to read and navigate this owner, not the caller's frame.
_frame: ?*Frame = null,

pub fn init(raw_url: [:0]const u8, frame: *Frame) !*Location {
    const url = try URL.init(raw_url, null, &frame.js.execution);
    return frame._factory.create(Location{
        ._url = url,
        ._frame = frame,
    });
}

fn ownerFrame(self: *const Location, fallback: *Frame) *Frame {
    return self._frame orelse fallback;
}

/// Browsing-context URL is the source of truth after history.pushState /
/// replaceState. Relying only on cached `_url` can leave window.location
/// stale while document.URL already moved (signup.live.com SPA routes).
fn liveRaw(self: *const Location, frame: *Frame) [:0]const u8 {
    return self.ownerFrame(frame).url;
}

pub fn getPathname(self: *const Location, frame: *Frame) []const u8 {
    return U.getPathname(self.liveRaw(frame));
}

pub fn getProtocol(self: *const Location, frame: *Frame) []const u8 {
    return U.getProtocol(self.liveRaw(frame));
}

pub fn getHostname(self: *const Location, frame: *Frame) []const u8 {
    return U.getHostname(self.liveRaw(frame));
}

pub fn getHost(self: *const Location, frame: *Frame) []const u8 {
    return U.getHost(self.liveRaw(frame));
}

pub fn getPort(self: *const Location, frame: *Frame) []const u8 {
    return U.getPort(self.liveRaw(frame));
}

pub fn getOrigin(self: *const Location, frame: *Frame) ![]const u8 {
    const owner = self.ownerFrame(frame);
    return (try U.getOrigin(owner.call_arena, owner.url)) orelse "null";
}

pub fn getSearch(self: *const Location, frame: *Frame) []const u8 {
    return U.getSearch(self.liveRaw(frame));
}

pub fn getHash(self: *const Location, frame: *Frame) []const u8 {
    return U.getHash(self.liveRaw(frame));
}

pub fn setPathname(self: *const Location, pathname: []const u8, frame: *Frame) !void {
    const owner = self.ownerFrame(frame);
    const new_url = try U.setPathname(owner.url, pathname, owner.call_arena);
    return owner.scheduleNavigation(new_url, .{
        .reason = .script,
        .kind = .{ .push = null },
    }, .{ .script = owner });
}

pub fn setSearch(self: *const Location, search: []const u8, frame: *Frame) !void {
    const owner = self.ownerFrame(frame);
    const new_url = try U.setSearch(owner.url, search, owner.call_arena);
    return owner.scheduleNavigation(new_url, .{
        .reason = .script,
        .kind = .{ .push = null },
    }, .{ .script = owner });
}

pub fn setHash(self: *const Location, hash: []const u8, frame: *Frame) !void {
    const owner = self.ownerFrame(frame);
    // Build the complete URL here. Passing only "#fragment" makes the
    // navigation scheduler resolve it against the document fallback base URL;
    // for about:srcdoc that is the embedding document, not the child document
    // whose Location is being mutated.
    const new_url = try U.setHash(owner.url, hash, owner.call_arena);
    if (std.mem.eql(u8, owner.url, new_url)) return;

    // Fragment-only / clear-hash updates are same-document navigations.
    return owner.scheduleNavigation(new_url, .{
        .reason = .script,
        .kind = .{ .push = null },
    }, .{ .script = owner });
}

pub fn assign(self: *const Location, url: [:0]const u8, frame: *Frame) !void {
    const owner = self.ownerFrame(frame);
    return owner.scheduleNavigation(url, .{ .reason = .script, .kind = .{ .push = null } }, .{ .script = owner });
}

pub fn replace(self: *const Location, url: [:0]const u8, frame: *Frame) !void {
    const owner = self.ownerFrame(frame);
    return owner.scheduleNavigation(url, .{ .reason = .script, .kind = .{ .replace = null } }, .{ .script = owner });
}

pub fn reload(self: *const Location, frame: *Frame) !void {
    const owner = self.ownerFrame(frame);
    if (runtime_io.getenv("KOKO_NAVIGATION_TRACE") != null) {
        log.info(.browser, "Location.reload", .{
            .url = owner.url,
            .frame_id = owner._frame_id,
            .realm = owner.realmState(),
        });
    }
    // Reload is a document navigation even though its target URL is identical
    // to the current URL. Without force, scheduleNavigation's same-URL guard
    // correctly treats ordinary location assignments as no-ops but incorrectly
    // swallows Location.reload().
    return owner.scheduleNavigation(owner.url, .{
        .reason = .script,
        .kind = .reload,
        .force = true,
    }, .{ .script = owner });
}

pub fn toString(self: *const Location, frame: *Frame) [:0]const u8 {
    return self.liveRaw(frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Location);

    pub const Meta = struct {
        pub const name = "Location";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const toString = bridge.function(Location.toString, .{});
    pub const href = bridge.accessor(Location.toString, setHref, .{});
    fn setHref(self: *const Location, url: [:0]const u8, frame: *Frame) !void {
        return self.assign(url, frame);
    }

    pub const search = bridge.accessor(Location.getSearch, Location.setSearch, .{});
    pub const hash = bridge.accessor(Location.getHash, Location.setHash, .{});
    pub const pathname = bridge.accessor(Location.getPathname, Location.setPathname, .{});
    pub const hostname = bridge.accessor(Location.getHostname, null, .{});
    pub const host = bridge.accessor(Location.getHost, null, .{});
    pub const port = bridge.accessor(Location.getPort, null, .{});
    pub const origin = bridge.accessor(Location.getOrigin, null, .{});
    pub const protocol = bridge.accessor(Location.getProtocol, null, .{});
    pub const assign = bridge.function(Location.assign, .{});
    pub const replace = bridge.function(Location.replace, .{});
    pub const reload = bridge.function(Location.reload, .{});
};

const testing = @import("../../testing/testing.zig");
test "Location.reload queues a same-URL document navigation" {
    const frame = try testing.pageTest("hi.html", .{});
    defer testing.test_session.removePage();

    try Location.reload(frame.window._location, frame);

    const queued = frame._queued_navigation orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(.reload, queued.opts.kind);
    try std.testing.expect(queued.opts.force);
}

test "Location.replace queues a same-URL document navigation" {
    const frame = try testing.pageTest("hi.html", .{});
    defer testing.test_session.removePage();

    try Location.replace(frame.window._location, frame.url, frame);

    const queued = frame._queued_navigation orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(
        @import("navigation/root.zig").NavigationType.replace,
        queued.opts.kind.toNavigationType(),
    );
}
