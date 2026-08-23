//
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
const Timer = @import("../../support/timer.zig");
const DOMNode = @import("../dom/Node.zig");
const Element = @import("../dom/Element.zig");
const Event = @import("../webapi/Event.zig");
const MouseEvent = @import("../webapi/event/MouseEvent.zig");
const KeyboardEvent = @import("../webapi/event/KeyboardEvent.zig");
const Frame = @import("Frame.zig");
const Session = @import("Session.zig");
const HumanInput = @import("HumanInput.zig");

fn dispatchInputAndChangeEvents(el: *Element, frame: *Frame) !void {
    const input_evt: *Event = try .initTrusted(comptime .wrap("input"), .{ .bubbles = true }, frame._page);
    frame._event_manager.dispatch(el.asEventTarget(), input_evt) catch |err| {
        @import("../../support/log.zig").err(.app, "dispatch input event failed", .{ .err = err });
    };

    const change_evt: *Event = try .initTrusted(comptime .wrap("change"), .{ .bubbles = true }, frame._page);
    frame._event_manager.dispatch(el.asEventTarget(), change_evt) catch |err| {
        @import("../../support/log.zig").err(.app, "dispatch change event failed", .{ .err = err });
    };
}

/// State required before an automation action can target an element.
///
/// This deliberately does not use bounding-box size as an actionability
/// signal.  Layout is approximate in a headless DOM and node-targeted actions
/// do not need viewport coordinates.  Connectedness, CSS visibility,
/// disabled/read-only state and pointer-events are stable DOM semantics and
/// therefore belong in the shared action layer rather than in each client.
pub const ActionKind = enum { click, fill };

pub fn actionableElement(node: *DOMNode, kind: ActionKind, frame: *Frame) !*Element {
    const el = node.is(Element) orelse return error.InvalidNodeType;
    if (!el.asNode().isConnected()) return error.ElementDetached;
    if (!el.checkVisibilityCached(null, frame)) return error.ElementNotVisible;
    if (el.isDisabled()) return error.ElementDisabled;

    if (kind == .click) {
        if (el.hasPointerEventsNone(null, frame)) return error.ElementNotReceivesEvents;
        if (el.getAttributeSafe(.wrap("aria-disabled"))) |disabled| {
            if (std.ascii.eqlIgnoreCase(disabled, "true")) return error.ElementDisabled;
        }
        return el;
    }

    if (el.getAttributeSafe(comptime .wrap("readonly")) != null) return error.ElementReadOnly;
    if (el.is(Element.Html.Input) == null and
        el.is(Element.Html.TextArea) == null and
        el.is(Element.Html.Select) == null)
    {
        return error.ElementNotEditable;
    }
    return el;
}

pub fn click(node: *DOMNode, frame: *Frame) !void {
    const el = try actionableElement(node, .click, frame);
    const owner = el.asNode().ownerFrame(frame);

    @import("InputController.zig").dispatchActivationOnElement(el, owner) catch |err| {
        @import("../../support/log.zig").err(.app, "click failed", .{ .err = err });
        return error.ActionFailed;
    };
}

pub fn hover(node: *DOMNode, frame: *Frame) !void {
    const el = node.is(Element) orelse return error.InvalidNodeType;

    const mouseover_event: *MouseEvent = try .initTrusted(comptime .wrap("mouseover"), .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
    }, frame);

    frame._event_manager.dispatch(el.asEventTarget(), mouseover_event.asEvent()) catch |err| {
        @import("../../support/log.zig").err(.app, "hover mouseover failed", .{ .err = err });
        return error.ActionFailed;
    };

    const mouseenter_event: *MouseEvent = try .initTrusted(comptime .wrap("mouseenter"), .{
        .composed = true,
    }, frame);

    frame._event_manager.dispatch(el.asEventTarget(), mouseenter_event.asEvent()) catch |err| {
        @import("../../support/log.zig").err(.app, "hover mouseenter failed", .{ .err = err });
        return error.ActionFailed;
    };
}

pub fn press(node: ?*DOMNode, key: []const u8, frame: *Frame) !void {
    const target = if (node) |n|
        (n.is(Element) orelse return error.InvalidNodeType).asEventTarget()
    else
        frame.document.asNode().asEventTarget();

    const keydown_event: *KeyboardEvent = try .initTrusted(comptime .wrap("keydown"), .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .key = key,
    }, frame);

    frame._event_manager.dispatch(target, keydown_event.asEvent()) catch |err| {
        @import("../../support/log.zig").err(.app, "press keydown failed", .{ .err = err });
        return error.ActionFailed;
    };

    const keyup_event: *KeyboardEvent = try .initTrusted(comptime .wrap("keyup"), .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .key = key,
    }, frame);

    frame._event_manager.dispatch(target, keyup_event.asEvent()) catch |err| {
        @import("../../support/log.zig").err(.app, "press keyup failed", .{ .err = err });
        return error.ActionFailed;
    };
}

pub fn selectOption(node: *DOMNode, value: []const u8, frame: *Frame) !void {
    const el = node.is(Element) orelse return error.InvalidNodeType;
    const select = el.is(Element.Html.Select) orelse return error.InvalidNodeType;

    select.setValue(value, frame) catch |err| {
        @import("../../support/log.zig").err(.app, "select setValue failed", .{ .err = err });
        return error.ActionFailed;
    };

    try dispatchInputAndChangeEvents(el, frame);
}

pub fn setChecked(node: *DOMNode, checked: bool, frame: *Frame) !void {
    const el = node.is(Element) orelse return error.InvalidNodeType;
    const input = el.is(Element.Html.Input) orelse return error.InvalidNodeType;

    if (input._input_type != .checkbox and input._input_type != .radio) {
        return error.InvalidNodeType;
    }

    input.setChecked(checked, frame) catch |err| {
        @import("../../support/log.zig").err(.app, "setChecked failed", .{ .err = err });
        return error.ActionFailed;
    };

    // Match browser event order: click fires first, then input and change.
    const click_event: *MouseEvent = try .initTrusted(comptime .wrap("click"), .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
    }, frame);

    frame._event_manager.dispatch(el.asEventTarget(), click_event.asEvent()) catch |err| {
        @import("../../support/log.zig").err(.app, "dispatch click event failed", .{ .err = err });
    };

    try dispatchInputAndChangeEvents(el, frame);
}

pub fn fill(node: *DOMNode, text: []const u8, frame: *Frame) !void {
    const el = try actionableElement(node, .fill, frame);

    el.focus(frame) catch |err| {
        @import("../../support/log.zig").err(.app, "fill focus failed", .{ .err = err });
    };

    if (el.is(Element.Html.Select)) |select| {
        select.setValue(text, frame) catch |err| {
            @import("../../support/log.zig").err(.app, "fill select failed", .{ .err = err });
            return error.ActionFailed;
        };
        try dispatchInputAndChangeEvents(el, frame);
        return;
    }

    // Browser automation "fill" replaces the current editable value in one
    // trusted beforeinput/input transaction.  Synthesizing a key event after
    // mutating the value duplicated text and made controlled SPA inputs race
    // their own state updates.
    if (el.is(Element.Html.Input)) |input| {
        try input.select(frame);
        try input.innerInsert(text, frame);
        return;
    }
    if (el.is(Element.Html.TextArea)) |textarea| {
        try textarea.select(frame);
        try textarea.innerInsert(text, frame);
        return;
    }
    return error.InvalidNodeType;
}

pub fn scroll(node: ?*DOMNode, x: ?i32, y: ?i32, frame: *Frame) !void {
    if (node) |n| {
        const el = n.is(Element) orelse return error.InvalidNodeType;

        if (x) |val| {
            el.setScrollLeft(val, frame) catch |err| {
                @import("../../support/log.zig").err(.app, "setScrollLeft failed", .{ .err = err });
                return error.ActionFailed;
            };
        }
        if (y) |val| {
            el.setScrollTop(val, frame) catch |err| {
                @import("../../support/log.zig").err(.app, "setScrollTop failed", .{ .err = err });
                return error.ActionFailed;
            };
        }

        const scroll_evt: *Event = try .initTrusted(comptime .wrap("scroll"), .{ .bubbles = true }, frame._page);
        frame._event_manager.dispatch(el.asEventTarget(), scroll_evt) catch |err| {
            @import("../../support/log.zig").err(.app, "dispatch scroll event failed", .{ .err = err });
        };
    } else {
        const delta_y: f64 = if (y) |val| @floatFromInt(val) else 0;
        if (delta_y != 0) {
            try HumanInput.wheelScroll(frame, delta_y, .{});
        }
        frame.window.scrollTo(.{ .x = x orelse 0 }, y, frame) catch |err| {
            @import("../../support/log.zig").err(.app, "scroll failed", .{ .err = err });
            return error.ActionFailed;
        };
    }
}

pub fn waitForSelector(selector: [:0]const u8, timeout_ms: u32, session: *Session) !*DOMNode {
    var runner = try session.runner(.{});
    // Runner.waitForSelector follows pending/current frames across navigation
    // and pumps the event loop itself.  Waiting for `load` first consumed the
    // entire timeout on long-lived SPAs and then left no budget for the actual
    // selector.
    const el = try runner.waitForSelector(selector, timeout_ms);
    return el.asNode();
}

pub fn waitForActionableSelector(
    selector: [:0]const u8,
    timeout_ms: u32,
    kind: ActionKind,
    session: *Session,
) !*DOMNode {
    var timer = try Timer.start();
    var runner = try session.runner(.{});

    while (true) {
        const elapsed: u32 = @intCast(timer.read() / std.time.ns_per_ms);
        if (elapsed >= timeout_ms) return error.Timeout;

        const remaining = timeout_ms - elapsed;
        const node = try waitForSelector(selector, remaining, session);
        const frame = session.pendingOrCurrentFrame() orelse return error.FrameNotLoaded;
        const owner = node.ownerFrame(frame);
        _ = actionableElement(node, kind, owner) catch |err| switch (err) {
            error.ElementDetached,
            error.ElementNotVisible,
            error.ElementDisabled,
            error.ElementNotReceivesEvents,
            error.ElementReadOnly,
            => {
                _ = try runner.tick(.{ .ms = @min(remaining, 50) });
                continue;
            },
            else => return err,
        };
        return node;
    }
}
