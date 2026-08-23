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

const js = @import("../js/js.zig");
const Frame = @import("../browser/Frame.zig");
const build_config = @import("build_config");

const v8 = js.v8;

const Caller = @import("../js/Caller.zig");
const Context = @import("../js/Context.zig");
const TaggedOpaque = @import("../js/TaggedOpaque.zig");

const IS_DEBUG = @import("builtin").mode == .Debug;

pub fn Builder(comptime T: type) type {
    return struct {
        pub const @"type" = T;
        pub const ClassId = u16;

        pub fn constructor(comptime func: anytype, comptime opts: Constructor.Opts) Constructor {
            return Constructor.init(T, func, opts);
        }

        pub fn accessor(comptime getter: anytype, comptime setter: anytype, comptime opts: Caller.Function.Opts) Accessor {
            return Accessor.init(T, getter, setter, opts);
        }

        pub fn function(comptime func: anytype, comptime opts: Caller.Function.Opts) Function {
            return Function.init(T, func, opts);
        }

        pub fn indexed(comptime getter_func: anytype, comptime enumerator_func: anytype, comptime opts: Indexed.Opts) Indexed {
            return Indexed.init(T, getter_func, enumerator_func, null, null, opts);
        }

        pub fn indexedWithSetterDeleter(comptime getter_func: anytype, comptime enumerator_func: anytype, setter_func: anytype, deleter_func: anytype, comptime opts: Indexed.Opts) Indexed {
            return Indexed.init(T, getter_func, enumerator_func, setter_func, deleter_func, opts);
        }

        pub fn namedIndexed(comptime getter_func: anytype, setter_func: anytype, deleter_func: anytype, comptime enumerator_func: anytype, comptime opts: NamedIndexed.Opts) NamedIndexed {
            return NamedIndexed.init(T, getter_func, setter_func, deleter_func, enumerator_func, opts);
        }

        pub fn iterator(comptime func: anytype, comptime opts: Iterator.Opts) Iterator {
            return Iterator.init(T, func, opts);
        }

        pub fn callable(comptime func: anytype, comptime opts: Callable.Opts) Callable {
            return Callable.init(T, func, opts);
        }

        pub fn property(value: anytype, opts: Property.Opts) Property {
            switch (@typeInfo(@TypeOf(value))) {
                .bool => return Property.init(.{ .bool = value }, opts),
                .null => return Property.init(.null, opts),
                .comptime_int, .int => return Property.init(.{ .int = value }, opts),
                .comptime_float, .float => return Property.init(.{ .float = value }, opts),
                .pointer => |ptr| switch (ptr.size) {
                    .one => {
                        const one_info = @typeInfo(ptr.child);
                        if (one_info == .array and one_info.array.child == u8) {
                            return Property.init(.{ .string = value }, opts);
                        }
                    },
                    else => {},
                },
                else => {},
            }
            @compileError("Property for " ++ @typeName(@TypeOf(value)) ++ " hasn't been defined yet");
        }

        // WebIDL attributes (e.g. Navigator.userAgent, Screen.width) MUST be
        // exposed as accessor properties on the interface prototype, not as
        // data properties. This means
        //   Object.getOwnPropertyDescriptor(Navigator.prototype, "userAgent")
        // returns {get: <native fn>, set: undefined, configurable: true,
        //          enumerable: true} — not {value: ..., writable: ...}.
        //
        // `attribute(value, ...)` is a shorthand for declaring a read-only
        // attribute whose value is a compile-time constant: it synthesizes a
        // tiny getter that returns `value` and routes through `accessor(...)`.
        // Use `accessor(getter, setter, ...)` directly when the value depends
        // on instance state.
        //
        // Use `property(...)` only for WebIDL constants (e.g. Node.ELEMENT_NODE)
        // which the spec defines as data properties.
        pub fn attribute(comptime value: anytype, comptime opts: Caller.Function.Opts) Accessor {
            const V = @TypeOf(value);
            const Closure = switch (@typeInfo(V)) {
                .bool => struct {
                    fn get(_: *const T) bool {
                        return value;
                    }
                },
                .comptime_int => struct {
                    fn get(_: *const T) i64 {
                        return value;
                    }
                },
                .int => struct {
                    fn get(_: *const T) V {
                        return value;
                    }
                },
                .comptime_float => struct {
                    fn get(_: *const T) f64 {
                        return value;
                    }
                },
                .float => struct {
                    fn get(_: *const T) V {
                        return value;
                    }
                },
                .null => struct {
                    fn get(_: *const T) ?bool {
                        return null;
                    }
                },
                .pointer => |ptr| switch (ptr.size) {
                    .one => blk: {
                        const child = @typeInfo(ptr.child);
                        if (child == .array and child.array.child == u8) {
                            break :blk struct {
                                fn get(_: *const T) []const u8 {
                                    return value;
                                }
                            };
                        }
                        @compileError("bridge.attribute: unsupported pointer type " ++ @typeName(V));
                    },
                    else => @compileError("bridge.attribute: unsupported pointer size for " ++ @typeName(V)),
                },
                else => @compileError("bridge.attribute: unsupported type " ++ @typeName(V)),
            };
            return Accessor.init(T, Closure.get, null, opts);
        }

        const PrototypeChainEntry = @import("../js/TaggedOpaque.zig").PrototypeChainEntry;
        pub fn prototypeChain() [prototypeChainLength(T)]PrototypeChainEntry {
            var entries: [prototypeChainLength(T)]PrototypeChainEntry = undefined;

            entries[0] = .{ .offset = 0, .index = JsApiLookup.getId(T.JsApi) };

            if (entries.len == 1) {
                return entries;
            }

            var Prototype = T;
            inline for (entries[1..]) |*entry| {
                const Next = PrototypeType(Prototype).?;
                entry.* = .{
                    .index = JsApiLookup.getId(Next.JsApi),
                    .offset = @offsetOf(Prototype, "_proto"),
                };
                Prototype = Next;
            }
            return entries;
        }
    };
}

pub const Constructor = struct {
    arity: c_int,
    func: *const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void,

    const Opts = struct {
        dom_exception: bool = false,
        // When true, the constructor function receives `new.target` (as a
        // js.Function) as its first parameter. Used by HTMLElement to support
        // direct instantiation of custom elements via `new MyElement()`.
        new_target: bool = false,
    };

    fn init(comptime T: type, comptime func: anytype, comptime opts: Opts) Constructor {
        return .{
            .arity = comptime Function.getArity(@TypeOf(func), if (opts.new_target) 1 else 0),
            .func = struct {
                fn wrap(handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
                    const v8_isolate = v8.v8__FunctionCallbackInfo__GetIsolate(handle).?;
                    var caller: Caller = undefined;
                    if (!caller.init(v8_isolate)) {
                        return;
                    }
                    defer caller.deinit();

                    caller.constructor(T, func, handle.?, .{
                        .dom_exception = opts.dom_exception,
                        .new_target = opts.new_target,
                    });
                }
            }.wrap,
        };
    }
};

pub const Function = struct {
    static: bool,
    arity: usize,
    noop: bool = false,
    wpt_only: bool = false,
    js_name: ?[:0]const u8 = null,
    cache: ?Caller.Function.Opts.Caching = null,
    func: *const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void,

    fn init(comptime T: type, comptime func: anytype, comptime opts: Caller.Function.Opts) Function {
        return .{
            .cache = opts.cache,
            .static = opts.static,
            .wpt_only = opts.wpt_only,
            .js_name = if (opts.js_name) |n| n else null,
            .arity = opts.length orelse getArity(@TypeOf(func), if (opts.static) 0 else 1),
            .func = if (opts.noop) noopFunction else struct {
                fn wrap(handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
                    Caller.Function.call(T, handle.?, func, opts);
                }
            }.wrap,
        };
    }

    pub fn noopFunction(_: ?*const v8.FunctionCallbackInfo) callconv(.c) void {}

    fn getArity(comptime T: type, comptime start: usize) usize {
        const Execution = js.Execution;

        const Page = @import("../browser/Page.zig");
        const Session = @import("../browser/Session.zig");

        var count: usize = 0;
        var params = @typeInfo(T).@"fn".params;
        for (params[start..]) |p| { // start at 1, skip self
            const PT = p.type.?;
            if (PT == *Frame or PT == *const Frame) {
                break;
            }

            if (PT == *Page or PT == *const Page) {
                break;
            }

            if (PT == *Execution or PT == *const Execution) {
                break;
            }

            if (PT == *Session or PT == *const Session) {
                break;
            }

            if (@typeInfo(PT) == .optional) {
                break;
            }
            count += 1;
        }
        return count;
    }
};

pub const Accessor = struct {
    static: bool = false,
    deletable: bool = true,
    wpt_only: bool = false,
    cache: ?Caller.Function.Opts.Caching = null,
    getter: ?*const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void = null,
    setter: ?*const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void = null,

    fn init(comptime T: type, comptime getter: anytype, comptime setter: anytype, comptime opts: Caller.Function.Opts) Accessor {
        var accessor = Accessor{
            .cache = opts.cache,
            .static = opts.static,
            .wpt_only = opts.wpt_only,
            .deletable = opts.deletable,
        };

        if (@typeInfo(@TypeOf(getter)) != .null) {
            accessor.getter = struct {
                fn wrap(handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
                    Caller.Function.call(T, handle.?, getter, opts);
                }
            }.wrap;
        }

        if (@typeInfo(@TypeOf(setter)) != .null) {
            accessor.setter = struct {
                fn wrap(handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
                    Caller.Function.call(T, handle.?, setter, opts);
                }
            }.wrap;
        }

        return accessor;
    }
};

pub const Indexed = struct {
    getter: *const fn (idx: u32, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8,
    setter: ?*const fn (idx: u32, c_value: ?*const v8.Value, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 = null,
    deleter: ?*const fn (idx: u32, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 = null,
    enumerator: ?*const fn (handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8,
    descriptor: ?*const fn (idx: u32, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) void = null,

    const Opts = struct {
        as_typed_array: bool = false,
        null_as_undefined: bool = false,
        enumerable: bool = false,
        legacy_platform_receiver: bool = false,
    };

    fn init(comptime T: type, comptime getter: anytype, comptime enumerator: anytype, comptime setter: anytype, comptime deleter: anytype, comptime opts: Opts) Indexed {
        const call_opts = comptime Caller.CallOpts{
            .as_typed_array = opts.as_typed_array,
            .null_as_undefined = opts.null_as_undefined,
            .legacy_platform_receiver = opts.legacy_platform_receiver,
        };

        var indexed = Indexed{
            .enumerator = null,
            .descriptor = null,
            .setter = null,
            .deleter = null,
            .getter = struct {
                fn wrap(idx: u32, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 {
                    const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
                    var caller: Caller = undefined;
                    if (!caller.init(v8_isolate)) {
                        return 0;
                    }
                    defer caller.deinit();

                    return caller.getIndex(T, getter, idx, handle.?, call_opts);
                }
            }.wrap,
        };

        if (@typeInfo(@TypeOf(enumerator)) != .null) {
            indexed.enumerator = struct {
                fn wrap(handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 {
                    const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
                    var caller: Caller = undefined;
                    if (!caller.init(v8_isolate)) {
                        return 0;
                    }
                    defer caller.deinit();
                    return caller.getEnumerator(T, enumerator, handle.?, call_opts);
                }
            }.wrap;
        }

        if (@typeInfo(@TypeOf(setter)) != .null) {
            indexed.setter = struct {
                fn wrap(idx: u32, c_value: ?*const v8.Value, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 {
                    const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
                    var caller: Caller = undefined;
                    if (!caller.init(v8_isolate)) {
                        return 0;
                    }
                    defer caller.deinit();
                    return caller.setIndex(T, setter, idx, c_value.?, handle.?, call_opts);
                }
            }.wrap;
        }

        if (@typeInfo(@TypeOf(deleter)) != .null) {
            indexed.deleter = struct {
                fn wrap(idx: u32, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 {
                    const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
                    var caller: Caller = undefined;
                    if (!caller.init(v8_isolate)) {
                        return 0;
                    }
                    defer caller.deinit();
                    return caller.deleteIndex(T, deleter, idx, handle.?, call_opts);
                }
            }.wrap;
        }

        if (opts.enumerable) {
            indexed.descriptor = struct {
                fn wrap(idx: u32, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) void {
                    const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
                    var caller: Caller = undefined;
                    if (!caller.init(v8_isolate)) {
                        return;
                    }
                    defer caller.deinit();
                    caller.getIndexedDescriptor(T, getter, idx, handle.?, call_opts);
                }
            }.wrap;
        }

        return indexed;
    }
};

pub const NamedIndexed = struct {
    getter: *const fn (c_name: ?*const v8.Name, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8,
    setter: ?*const fn (c_name: ?*const v8.Name, c_value: ?*const v8.Value, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 = null,
    deleter: ?*const fn (c_name: ?*const v8.Name, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 = null,
    enumerator: ?*const fn (handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 = null,
    descriptor: ?*const fn (c_name: ?*const v8.Name, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) void = null,

    const Opts = struct {
        as_typed_array: bool = false,
        null_as_undefined: bool = false,
        enumerable: bool = false,
        legacy_platform_receiver: bool = false,
    };

    fn init(comptime T: type, comptime getter: anytype, setter: anytype, deleter: anytype, comptime enumerator: anytype, comptime opts: Opts) NamedIndexed {
        const call_opts = comptime Caller.CallOpts{
            .as_typed_array = opts.as_typed_array,
            .null_as_undefined = opts.null_as_undefined,
            .legacy_platform_receiver = opts.legacy_platform_receiver,
        };

        const getter_fn = struct {
            fn wrap(c_name: ?*const v8.Name, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 {
                const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
                var caller: Caller = undefined;
                if (!caller.init(v8_isolate)) {
                    return 0;
                }
                defer caller.deinit();

                return caller.getNamedIndex(T, getter, c_name.?, handle.?, call_opts);
            }
        }.wrap;

        const setter_fn = if (@typeInfo(@TypeOf(setter)) == .null) null else struct {
            fn wrap(c_name: ?*const v8.Name, c_value: ?*const v8.Value, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 {
                const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
                var caller: Caller = undefined;
                if (!caller.init(v8_isolate)) {
                    return 0;
                }
                defer caller.deinit();

                return caller.setNamedIndex(T, setter, c_name.?, c_value.?, handle.?, call_opts);
            }
        }.wrap;

        const deleter_fn = if (@typeInfo(@TypeOf(deleter)) == .null) null else struct {
            fn wrap(c_name: ?*const v8.Name, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 {
                const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
                var caller: Caller = undefined;
                if (!caller.init(v8_isolate)) {
                    return 0;
                }
                defer caller.deinit();

                return caller.deleteNamedIndex(T, deleter, c_name.?, handle.?, call_opts);
            }
        }.wrap;

        const enumerator_fn = if (@typeInfo(@TypeOf(enumerator)) == .null) null else struct {
            fn wrap(handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 {
                const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
                var caller: Caller = undefined;
                if (!caller.init(v8_isolate)) {
                    return 0;
                }
                defer caller.deinit();
                return caller.getEnumerator(T, enumerator, handle.?, call_opts);
            }
        }.wrap;

        const descriptor_fn = if (opts.enumerable) struct {
            fn wrap(c_name: ?*const v8.Name, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) void {
                const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
                var caller: Caller = undefined;
                if (!caller.init(v8_isolate)) {
                    return;
                }
                defer caller.deinit();
                caller.getNamedDescriptor(T, getter, c_name.?, handle.?, call_opts);
            }
        }.wrap else null;

        return .{
            .getter = getter_fn,
            .setter = setter_fn,
            .deleter = deleter_fn,
            .enumerator = enumerator_fn,
            .descriptor = descriptor_fn,
        };
    }
};

pub const Iterator = struct {
    func: *const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void,
    async: bool,

    const Opts = struct {
        async: bool = false,
        null_as_undefined: bool = false,
    };

    fn init(comptime T: type, comptime struct_or_func: anytype, comptime opts: Opts) Iterator {
        if (@typeInfo(@TypeOf(struct_or_func)) == .type) {
            return .{
                .async = opts.async,
                .func = struct {
                    fn wrap(handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
                        const info = Caller.FunctionCallbackInfo{ .handle = handle.? };
                        info.getReturnValue().set(info.getThis());
                    }
                }.wrap,
            };
        }

        return .{
            .async = opts.async,
            .func = struct {
                fn wrap(handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
                    return Caller.Function.call(T, handle.?, struct_or_func, .{
                        .null_as_undefined = opts.null_as_undefined,
                    });
                }
            }.wrap,
        };
    }
};

pub const Callable = struct {
    func: *const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void,

    const Opts = struct {
        null_as_undefined: bool = false,
    };

    fn init(comptime T: type, comptime func: anytype, comptime opts: Opts) Callable {
        return .{ .func = struct {
            fn wrap(handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
                Caller.Function.call(T, handle.?, func, .{
                    .null_as_undefined = opts.null_as_undefined,
                });
            }
        }.wrap };
    }
};

pub const Property = struct {
    value: Value,
    template: bool,
    readonly: bool,

    const Value = union(enum) {
        null,
        int: i64,
        float: f64,
        bool: bool,
        string: []const u8,
    };

    const Opts = struct {
        template: bool,
        readonly: bool = true,
    };

    fn init(value: Value, opts: Opts) Property {
        return .{
            .value = value,
            .template = opts.template,
            .readonly = opts.readonly,
        };
    }
};

pub fn unknownWindowPropertyCallback(c_name: ?*const v8.Name, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 {
    const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;

    // During snapshot creation, there's no Context in embedder data yet.
    // I hate this check, but there doesn't seem to be a way to add this method
    // to the global, without triggering it during snapshot creation.
    const v8_context = v8.v8__Isolate__GetCurrentContext(v8_isolate) orelse return 0;
    const ctx: *Context = @ptrCast(@alignCast(v8.v8__Context__GetAlignedPointerFromEmbedderData(v8_context, 1) orelse return 0));

    var caller: Caller = undefined;
    caller.initWithContext(ctx, v8_context);
    defer caller.deinit();

    const local = &caller.local;

    var hs: js.HandleScope = undefined;
    hs.init(local.isolate);
    defer hs.deinit();

    const property: []const u8 = js.String.toSlice(.{ .local = local, .handle = @ptrCast(c_name.?) }) catch {
        return 0;
    };

    // Prefer the creation context of `this` (contentWindow / nested global).
    // GetCurrentContext is often the *caller* when parent reads frameW.x —
    // must not look up names on the parent frame.
    var pc = Caller.PropertyCallbackInfo{ .handle = handle.? };
    const lookup_frame: ?*Frame = blk: {
        const this_obj = pc.getThis();
        if (v8.v8__Object__GetCreationContext(this_obj)) |creation| {
            if (v8.v8__Context__GetAlignedPointerFromEmbedderData(creation, 1)) |ptr| {
                const rctx: *Context = @ptrCast(@alignCast(ptr));
                break :blk switch (rctx.global) {
                    .frame => |f| f,
                    .worker => null,
                };
            }
        }
        break :blk switch (local.ctx.global) {
            .frame => |f| f,
            .worker => null,
        };
    };

    if (lookup_frame) |frame| {
        // HTML named access: direct child browsing contexts by name.
        if (frame.findNamedChildWindow(property)) |child_win| {
            const js_val = local.zigValueToJs(child_win, .{}) catch return 0;
            pc.getReturnValue().set(js_val);
            return 1;
        }
        if (frame.document.getElementById(property, frame)) |el| {
            const js_val = local.zigValueToJs(el, .{}) catch return 0;
            pc.getReturnValue().set(js_val);
            return 1;
        }
    }

    if (comptime IS_DEBUG) {
        if (std.mem.startsWith(u8, property, "__")) {
            // some frameworks will extend built-in types using a __ prefix
            // these should always be safe to ignore.
            return 0;
        }

        const ignored = std.StaticStringMap(void).initComptime(.{
            .{ "Deno", {} },
            .{ "process", {} },
            .{ "ShadyDOM", {} },
            .{ "ShadyCSS", {} },

            // a lot of sites seem to like having their own window.config.
            .{ "config", {} },

            .{ "litNonce", {} },
            .{ "litHtmlVersions", {} },
            .{ "litElementVersions", {} },
            .{ "litHtmlPolyfillSupport", {} },
            .{ "litElementHydrateSupport", {} },
            .{ "litElementPolyfillSupport", {} },
            .{ "reactiveElementVersions", {} },

            .{ "CLOSURE_FLAGS", {} },
            .{ "__REACT_DEVTOOLS_GLOBAL_HOOK__", {} },
            .{ "ApplePaySession", {} },
        });
        if (!ignored.has(property)) {
            var buf: [2048]u8 = undefined;
            const key = std.fmt.bufPrint(&buf, "Window:{s}", .{property}) catch return 0;
            logUnknownProperty(local, key) catch return 0;
        }
    }

    // not intercepted
    return 0;
}

// Only used for debugging
pub fn unknownObjectPropertyCallback(comptime JsApi: type) *const fn (?*const v8.Name, ?*const v8.PropertyCallbackInfo) callconv(.c) u8 {
    if (comptime !IS_DEBUG) {
        @compileError("unknownObjectPropertyCallback should only be used in debug builds");
    }

    return struct {
        fn wrap(c_name: ?*const v8.Name, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 {
            const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;

            var caller: Caller = undefined;
            if (!caller.init(v8_isolate)) {
                return 0;
            }
            defer caller.deinit();

            const local = &caller.local;

            var hs: js.HandleScope = undefined;
            hs.init(local.isolate);
            defer hs.deinit();

            const property: []const u8 = js.String.toSlice(.{ .local = local, .handle = @ptrCast(c_name.?) }) catch {
                return 0;
            };

            if (std.mem.startsWith(u8, property, "__")) {
                // some frameworks will extend built-in types using a __ prefix
                // these should always be safe to ignore.
                return 0;
            }

            if (std.mem.startsWith(u8, property, "jQuery")) {
                return 0;
            }

            if (JsApi == @import("../webapi/cdata/Text.zig").JsApi or JsApi == @import("../webapi/cdata/Comment.zig").JsApi) {
                if (std.mem.eql(u8, property, "tagName")) {
                    // knockout does this, a lot.
                    return 0;
                }
            }

            if (JsApi == @import("../webapi/element/Html.zig").JsApi or JsApi == @import("../dom/Element.zig").JsApi or JsApi == @import("../webapi/element/html/Custom.zig").JsApi) {
                // react ?
                if (std.mem.eql(u8, property, "props")) return 0;
                if (std.mem.eql(u8, property, "hydrated")) return 0;
                if (std.mem.eql(u8, property, "isHydrated")) return 0;
            }

            if (JsApi == @import("../webapi/Console.zig").JsApi) {
                if (std.mem.eql(u8, property, "firebug")) return 0;
            }

            const ignored = std.StaticStringMap(void).initComptime(.{});
            if (!ignored.has(property)) {
                var buf: [2048]u8 = undefined;
                const key = std.fmt.bufPrint(&buf, "{s}:{s}", .{ if (@hasDecl(JsApi.Meta, "name")) JsApi.Meta.name else @typeName(JsApi), property }) catch return 0;
                logUnknownProperty(local, key) catch return 0;
            }
            // not intercepted
            return 0;
        }
    }.wrap;
}

fn logUnknownProperty(local: *const js.Local, key: []const u8) !void {
    const ctx = local.ctx;
    const gop = try ctx.unknown_properties.getOrPut(ctx.arena, key);
    if (gop.found_existing) {
        gop.value_ptr.count += 1;
    } else {
        gop.key_ptr.* = try ctx.arena.dupe(u8, key);
        gop.value_ptr.* = .{
            .count = 1,
            .first_stack = try ctx.arena.dupe(u8, (try local.stackTrace()) orelse "???"),
        };
    }
}

// Given a Type, returns the length of the prototype chain, including self
fn prototypeChainLength(comptime T: type) usize {
    var l: usize = 1;
    var Next = T;
    while (PrototypeType(Next)) |N| {
        Next = N;
        l += 1;
    }
    return l;
}

// Given a Type, gets its prototype Type (if any)
fn PrototypeType(comptime T: type) ?type {
    if (!@hasField(T, "_proto")) {
        return null;
    }
    return Struct(std.meta.fieldInfo(T, ._proto).type);
}

fn flattenTypes(comptime Types: []const type) [countFlattenedTypes(Types)]type {
    @setEvalBranchQuota(10_000);
    var index: usize = 0;
    var flat: [countFlattenedTypes(Types)]type = undefined;
    for (Types) |T| {
        if (@hasDecl(T, "registerTypes")) {
            for (T.registerTypes()) |TT| {
                flat[index] = TT.JsApi;
                index += 1;
            }
        } else {
            flat[index] = T.JsApi;
            index += 1;
        }
    }
    return flat;
}

fn countFlattenedTypes(comptime Types: []const type) usize {
    @setEvalBranchQuota(10_000);
    var c: usize = 0;
    for (Types) |T| {
        c += if (@hasDecl(T, "registerTypes")) T.registerTypes().len else 1;
    }
    return c;
}

//  T => T
// *T => T
pub fn Struct(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .@"struct" => T,
        .pointer => |ptr| ptr.child,
        else => @compileError("Expecting Struct or *Struct, got: " ++ @typeName(T)),
    };
}

pub const JsApiLookup = struct {
    /// Integer type we use for `JsApiLookup` enum. Can be u8 at min.
    pub const BackingInt = std.math.IntFittingRange(0, @max(std.math.maxInt(u8), JsApis.len));

    /// Imagine we have a type `Cat` which has a getter:
    ///
    ///    fn get_owner(self: *Cat) *Owner {
    ///        return self.owner;
    ///    }
    ///
    /// When we execute `caller.getter`, we'll end up doing something like:
    ///
    ///    const res = @call(.auto, Cat.get_owner, .{cat_instance});
    ///
    /// How do we turn `res`, which is an *Owner, into something we can return
    /// to v8? We need the ObjectTemplate associated with Owner. How do we
    /// get that? Well, we store all the ObjectTemplates in an array that's
    /// tied to env. So we do something like:
    ///
    ///    env.templates[index_of_owner].initInstance(...);
    ///
    /// But how do we get that `index_of_owner`? `Index` is an enum
    /// that looks like:
    ///
    ///    pub const Enum = enum(BackingInt) {
    ///        cat = 0,
    ///        owner = 1,
    ///        ...
    ///    }
    ///
    /// (`BackingInt` is calculated at comptime regarding to interfaces we have)
    /// So to get the template index of `owner`, simply do:
    ///
    ///    const index_id = types.getId(@TypeOf(res));
    ///
    pub const Enum = blk: {
        var field_names: [JsApis.len][]const u8 = undefined;
        var field_values: [JsApis.len]BackingInt = undefined;
        for (JsApis, 0..) |JsApi, i| {
            field_names[i] = @typeName(JsApi);
            field_values[i] = @intCast(i);
        }

        break :blk @Enum(BackingInt, .exhaustive, &field_names, &field_values);
    };

    /// Returns a boolean indicating if a type exist in the lookup.
    pub inline fn has(t: type) bool {
        return @hasField(Enum, @typeName(t));
    }

    /// Returns the `Enum` for the given type.
    pub inline fn getIndex(t: type) Enum {
        return @field(Enum, @typeName(t));
    }

    /// Returns the ID for the given type.
    pub inline fn getId(t: type) BackingInt {
        return @intFromEnum(getIndex(t));
    }
};

pub const SubType = enum {
    @"error",
    array,
    arraybuffer,
    dataview,
    date,
    generator,
    iterator,
    map,
    node,
    promise,
    proxy,
    regexp,
    set,
    typedarray,
    wasmvalue,
    weakmap,
    weakset,
    webassemblymemory,
};

// APIs for Page/Window contexts. Used by Snapshot.zig for Page snapshot creation.
pub const PageJsApis = flattenTypes(&.{
    @import("../webapi/AbortController.zig"),
    @import("../webapi/AbortSignal.zig"),
    @import("../webapi/BatteryManager.zig"),
    @import("../webapi/CData.zig"),
    @import("../webapi/cdata/Comment.zig"),
    @import("../webapi/cdata/Text.zig"),
    @import("../webapi/cdata/CDATASection.zig"),
    @import("../webapi/cdata/ProcessingInstruction.zig"),
    @import("../webapi/collections.zig"),
    @import("../webapi/Console.zig"),
    @import("../webapi/Chrome.zig"),
    @import("../webapi/Crypto.zig"),
    @import("../webapi/Permissions.zig"),
    @import("../webapi/MediaCapabilities.zig"),
    @import("../webapi/StorageManager.zig"),
    @import("../webapi/CSS.zig"),
    @import("../webapi/css/CSSRule.zig"),
    @import("../webapi/css/CSSRuleList.zig"),
    @import("../webapi/css/CSSStyleDeclaration.zig"),
    @import("../webapi/css/CSSStyleRule.zig"),
    @import("../webapi/css/CSSStyleSheet.zig"),
    @import("../webapi/css/CSSStyleProperties.zig"),
    @import("../webapi/css/FontFace.zig"),
    @import("../webapi/css/FontFaceSet.zig"),
    @import("../webapi/css/MediaQueryList.zig"),
    @import("../webapi/css/StyleSheetList.zig"),
    @import("../dom/Document.zig"),
    @import("../webapi/HTMLDocument.zig"),
    @import("../webapi/XMLDocument.zig"),
    @import("../webapi/History.zig"),
    @import("../webapi/KeyValueList.zig"),
    @import("../dom/DocumentFragment.zig"),
    @import("../dom/DocumentType.zig"),
    @import("../webapi/ShadowRoot.zig"),
    @import("../dom/DOMException.zig"),
    @import("../dom/DOMImplementation.zig"),
    @import("../dom/DOMTreeWalker.zig"),
    @import("../dom/DOMNodeIterator.zig"),
    @import("../dom/DOMRectReadOnly.zig"),
    @import("../dom/DOMRect.zig"),
    @import("../dom/SVGRect.zig"),
    @import("../dom/DOMMatrixReadOnly.zig"),
    @import("../dom/DOMMatrix.zig"),
    @import("../dom/DOMPointReadOnly.zig"),
    @import("../dom/DOMPoint.zig"),
    @import("../dom/DOMParser.zig"),
    @import("../webapi/XMLSerializer.zig"),
    @import("../webapi/AbstractRange.zig"),
    @import("../webapi/Range.zig"),
    @import("../webapi/StaticRange.zig"),
    @import("../dom/NodeFilter.zig"),
    @import("../dom/Element.zig"),
    @import("../webapi/element/DOMStringMap.zig"),
    @import("../webapi/element/Attribute.zig"),
    @import("../webapi/element/Html.zig"),
    @import("../webapi/element/html/IFrame.zig"),
    @import("../webapi/element/html/Anchor.zig"),
    @import("../webapi/element/html/Area.zig"),
    @import("../webapi/element/html/Audio.zig"),
    @import("../webapi/element/html/Base.zig"),
    @import("../webapi/element/html/Body.zig"),
    @import("../webapi/element/html/BR.zig"),
    @import("../webapi/element/html/Button.zig"),
    @import("../webapi/element/html/Canvas.zig"),
    @import("../webapi/element/html/Custom.zig"),
    @import("../webapi/element/html/Data.zig"),
    @import("../webapi/element/html/DataList.zig"),
    @import("../webapi/element/html/Details.zig"),
    @import("../webapi/element/html/Dialog.zig"),
    @import("../webapi/element/html/Directory.zig"),
    @import("../webapi/element/html/DList.zig"),
    @import("../webapi/element/html/Div.zig"),
    @import("../webapi/element/html/Embed.zig"),
    @import("../webapi/element/html/FieldSet.zig"),
    @import("../webapi/element/html/Font.zig"),
    @import("../webapi/element/html/FrameSet.zig"),
    @import("../webapi/element/html/Form.zig"),
    @import("../webapi/element/html/Generic.zig"),
    @import("../webapi/element/html/Head.zig"),
    @import("../webapi/element/html/Heading.zig"),
    @import("../webapi/element/html/HR.zig"),
    @import("../webapi/element/html/Html.zig"),
    @import("../webapi/element/html/Image.zig"),
    @import("../webapi/element/html/Input.zig"),
    @import("../webapi/element/html/Label.zig"),
    @import("../webapi/element/html/Legend.zig"),
    @import("../webapi/element/html/LI.zig"),
    @import("../webapi/element/html/Link.zig"),
    @import("../webapi/element/html/Map.zig"),
    @import("../webapi/element/html/Media.zig"),
    @import("../webapi/element/html/Meta.zig"),
    @import("../webapi/element/html/Meter.zig"),
    @import("../webapi/element/html/Mod.zig"),
    @import("../webapi/element/html/Object.zig"),
    @import("../webapi/element/html/OL.zig"),
    @import("../webapi/element/html/OptGroup.zig"),
    @import("../webapi/element/html/Option.zig"),
    @import("../webapi/element/html/Output.zig"),
    @import("../webapi/element/html/Paragraph.zig"),
    @import("../webapi/element/html/Picture.zig"),
    @import("../webapi/element/html/Param.zig"),
    @import("../webapi/element/html/Pre.zig"),
    @import("../webapi/element/html/Progress.zig"),
    @import("../webapi/element/html/Quote.zig"),
    @import("../webapi/element/html/Script.zig"),
    @import("../webapi/element/html/Select.zig"),
    @import("../webapi/element/html/Slot.zig"),
    @import("../webapi/element/html/Source.zig"),
    @import("../webapi/element/html/Span.zig"),
    @import("../webapi/element/html/Style.zig"),
    @import("../webapi/element/html/Table.zig"),
    @import("../webapi/element/html/TableCaption.zig"),
    @import("../webapi/element/html/TableCell.zig"),
    @import("../webapi/element/html/TableCol.zig"),
    @import("../webapi/element/html/TableRow.zig"),
    @import("../webapi/element/html/TableSection.zig"),
    @import("../webapi/element/html/Template.zig"),
    @import("../webapi/element/html/TextArea.zig"),
    @import("../webapi/element/html/Time.zig"),
    @import("../webapi/element/html/Title.zig"),
    @import("../webapi/element/html/Track.zig"),
    @import("../webapi/element/html/Video.zig"),
    @import("../webapi/element/html/UL.zig"),
    @import("../webapi/element/html/Unknown.zig"),
    @import("../webapi/element/html/ValidityState.zig"),
    @import("../webapi/element/html/Marquee.zig"),
    @import("../webapi/element/Svg.zig"),
    @import("../webapi/element/svg/Generic.zig"),
    @import("../webapi/element/svg/Anchor.zig"),
    @import("../webapi/encoding/TextDecoder.zig"),
    @import("../webapi/encoding/TextEncoder.zig"),
    @import("../webapi/encoding/TextEncoderStream.zig"),
    @import("../webapi/encoding/TextDecoderStream.zig"),
    @import("../webapi/Event.zig"),
    @import("../webapi/event/CompositionEvent.zig"),
    @import("../webapi/event/CustomEvent.zig"),
    @import("../webapi/event/ErrorEvent.zig"),
    @import("../webapi/event/MessageEvent.zig"),
    @import("../webapi/event/ConnectEvent.zig"),
    @import("../webapi/event/ProgressEvent.zig"),
    @import("../webapi/event/NavigationCurrentEntryChangeEvent.zig"),
    @import("../webapi/event/PageTransitionEvent.zig"),
    @import("../webapi/event/PopStateEvent.zig"),
    @import("../webapi/event/UIEvent.zig"),
    @import("../webapi/event/MouseEvent.zig"),
    @import("../webapi/event/PointerEvent.zig"),
    @import("../webapi/event/KeyboardEvent.zig"),
    @import("../webapi/event/FocusEvent.zig"),
    @import("../webapi/event/WheelEvent.zig"),
    @import("../webapi/event/InputDeviceCapabilities.zig"),
    @import("../webapi/event/Touch.zig"),
    @import("../webapi/event/TouchList.zig"),
    @import("../webapi/event/TouchEvent.zig"),
    @import("../webapi/event/TextEvent.zig"),
    @import("../webapi/event/InputEvent.zig"),
    @import("../webapi/event/PromiseRejectionEvent.zig"),
    @import("../webapi/event/SubmitEvent.zig"),
    @import("../webapi/event/FormDataEvent.zig"),
    @import("../webapi/event/DragEvent.zig"),
    @import("../webapi/event/HashChangeEvent.zig"),
    @import("../webapi/event/ToggleEvent.zig"),
    // CookieChangeEvent waits on CookieStore CookieListItem surface (Koko parity).
    @import("../webapi/DataTransfer.zig"),
    @import("../webapi/MessageChannel.zig"),
    @import("../webapi/MessagePort.zig"),
    @import("../webapi/audio/audio.zig"),
    @import("../webapi/speech/SpeechSynthesis.zig"),
    @import("../webapi/idb.zig"),
    @import("../webapi/cache_storage.zig"),
    @import("../webapi/cookie_store.zig"),
    @import("../webapi/scheduler_api.zig"),
    @import("../webapi/task_scheduling.zig"),
    @import("../webapi/credentials_api.zig"),
    @import("../webapi/broadcast_channel.zig"),
    @import("../webapi/trusted_types.zig"),
    @import("../webapi/dom_notification.zig"),
    @import("../webapi/navigator_extras.zig"),
    @import("../webapi/rtc_bindings.zig"),
    @import("../webapi/shared_worker.zig"),
    @import("../webapi/Worker.zig"),
    @import("../webapi/media/MediaError.zig"),
    @import("../webapi/media/MediaRecorder.zig"),
    @import("../webapi/media/MediaSource.zig"),
    @import("../webapi/media/SourceBuffer.zig"),
    @import("../webapi/media/TextTrackCue.zig"),
    @import("../webapi/media/VTTCue.zig"),
    @import("../webapi/animation/Animation.zig"),
    @import("../webapi/EventTarget.zig"),
    @import("../webapi/Location.zig"),
    @import("../webapi/Navigator.zig"),
    @import("../webapi/NetworkInformation.zig"),
    @import("../webapi/NavigatorUAData.zig"),
    @import("../webapi/net/FormData.zig"),
    @import("../webapi/net/Headers.zig"),
    @import("../webapi/net/Request.zig"),
    @import("../webapi/net/Response.zig"),
    @import("../webapi/net/URLSearchParams.zig"),
    @import("../webapi/net/XMLHttpRequest.zig"),
    @import("../webapi/net/XMLHttpRequestEventTarget.zig"),
    @import("../webapi/net/XMLHttpRequestUpload.zig"),
    @import("../webapi/net/EventSource.zig"),
    @import("../webapi/net/WebSocket.zig"),
    @import("../webapi/event/CloseEvent.zig"),
    @import("../webapi/XPathEvaluator.zig"),
    @import("../webapi/XPathExpression.zig"),
    @import("../webapi/XPathResult.zig"),
    @import("../webapi/ModelContext.zig"),
    @import("../webapi/streams/ReadableStream.zig"),
    @import("../webapi/streams/ReadableStreamDefaultReader.zig"),
    @import("../webapi/streams/ReadableStreamDefaultController.zig"),
    @import("../webapi/streams/WritableStream.zig"),
    @import("../webapi/streams/WritableStreamDefaultWriter.zig"),
    @import("../webapi/streams/WritableStreamDefaultController.zig"),
    @import("../webapi/streams/TransformStream.zig"),
    @import("../webapi/streams/CompressionStream.zig"),
    @import("../webapi/streams/DecompressionStream.zig"),
    @import("../dom/Node.zig"),
    @import("../webapi/storage/storage.zig"),
    @import("../webapi/URL.zig"),
    @import("../webapi/Window.zig"),
    @import("../webapi/Performance.zig"),
    @import("../webapi/EventCounts.zig"),
    @import("../webapi/PluginArray.zig"),
    @import("../webapi/MutationObserver.zig"),
    @import("../webapi/IntersectionObserver.zig"),
    @import("../webapi/CustomElementRegistry.zig"),
    @import("../webapi/ResizeObserver.zig"),
    @import("../webapi/IdleDeadline.zig"),
    @import("../webapi/Blob.zig"),
    @import("../webapi/File.zig"),
    @import("../webapi/FileList.zig"),
    @import("../webapi/FileReader.zig"),
    @import("../webapi/Screen.zig"),
    @import("../webapi/VisualViewport.zig"),
    @import("../webapi/PerformanceObserver.zig"),
    @import("../webapi/navigation/Navigation.zig"),
    @import("../webapi/navigation/NavigationHistoryEntry.zig"),
    @import("../webapi/navigation/NavigationActivation.zig"),
    @import("../webapi/canvas/CanvasGradient.zig"),
    @import("../webapi/canvas/CanvasRenderingContext2D.zig"),
    @import("../webapi/canvas/TextMetrics.zig"),
    @import("../webapi/canvas/WebGLRenderingContext.zig"),
    @import("../webapi/canvas/WebGL2RenderingContext.zig").WebGL2RenderingContext,
    @import("../webapi/canvas/OffscreenCanvas.zig"),
    @import("../webapi/canvas/OffscreenCanvasRenderingContext2D.zig"),
    @import("../webapi/SubtleCrypto.zig"),
    @import("../webapi/CryptoKey.zig"),
    @import("../webapi/Selection.zig"),
    @import("../webapi/ImageData.zig"),
    @import("../webapi/window_stubs.zig"),
});

// APIs available on Worker context globals (constructors like URL, Headers, etc.)
// This is a subset of PageJsApis plus WorkerGlobalScope.
// TODO: Expand this list to include all worker-appropriate APIs.
pub const WorkerJsApis = flattenTypes(&.{
    @import("../webapi/DedicatedWorkerGlobalScope.zig"),
    @import("../webapi/SharedWorkerGlobalScope.zig"),
    @import("../webapi/WorkerGlobalScope.zig"),
    @import("../webapi/WorkerLocation.zig"),
    @import("../webapi/WorkerNavigator.zig"),
    @import("../webapi/NavigatorUAData.zig"),
    @import("../webapi/PluginArray.zig"),
    @import("../webapi/EventTarget.zig"),
    @import("../webapi/Event.zig"),
    @import("../webapi/event/MessageEvent.zig"),
    @import("../webapi/event/ConnectEvent.zig"),
    @import("../dom/DOMException.zig"),
    @import("../webapi/net/URLSearchParams.zig"),
    @import("../webapi/encoding/TextEncoder.zig"),
    @import("../webapi/encoding/TextDecoder.zig"),
    @import("../webapi/Blob.zig"),
    @import("../webapi/File.zig"),
    @import("../webapi/Console.zig"),
    @import("../webapi/Crypto.zig"),
    @import("../webapi/net/FormData.zig"),
    @import("../webapi/net/Headers.zig"),
    @import("../webapi/net/Request.zig"),
    @import("../webapi/net/Response.zig"),
    @import("../webapi/streams/TransformStream.zig"),
    @import("../webapi/streams/CompressionStream.zig"),
    @import("../webapi/streams/DecompressionStream.zig"),
    @import("../webapi/streams/ReadableStream.zig"),
    @import("../webapi/streams/ReadableStreamDefaultReader.zig"),
    @import("../webapi/streams/ReadableStreamDefaultController.zig"),
    @import("../webapi/streams/WritableStream.zig"),
    @import("../webapi/streams/WritableStreamDefaultWriter.zig"),
    @import("../webapi/streams/WritableStreamDefaultController.zig"),
    @import("../webapi/encoding/TextEncoderStream.zig"),
    @import("../webapi/encoding/TextDecoderStream.zig"),
    @import("../webapi/AbortSignal.zig"),
    @import("../webapi/AbortController.zig"),
    @import("../webapi/URL.zig"),
    @import("../webapi/canvas/CanvasGradient.zig"),
    @import("../webapi/canvas/TextMetrics.zig"),
    @import("../webapi/canvas/OffscreenCanvas.zig"),
    @import("../webapi/canvas/OffscreenCanvasRenderingContext2D.zig"),
    @import("../webapi/ImageData.zig"),
    @import("../webapi/canvas/WebGLRenderingContext.zig"),
    @import("../webapi/canvas/WebGL2RenderingContext.zig").WebGL2RenderingContext,
    @import("../webapi/net/XMLHttpRequest.zig"),
    @import("../webapi/net/XMLHttpRequestEventTarget.zig"),
    @import("../webapi/FileReader.zig"),
    @import("../webapi/broadcast_channel.zig"),
    @import("../webapi/MessageChannel.zig"),
    @import("../webapi/MessagePort.zig"),
    @import("../webapi/Worker.zig"),
    @import("../webapi/SubtleCrypto.zig"),
    @import("../webapi/CryptoKey.zig"),
    // @import("../webapi/Performance.zig"),
});

// Master list of ALL JS APIs across all contexts.
// Used by Env (class IDs, templates), JsApiLookup, and anywhere that needs
// to know about all possible types. Individual snapshots use their own
// subsets (PageJsApis, WorkerSnapshot.JsApis).
pub const SharedWorkerJsApis = flattenTypes(&.{
    @import("../webapi/SharedWorkerGlobalScope.zig"),
    @import("../webapi/WorkerGlobalScope.zig"),
    @import("../webapi/WorkerLocation.zig"),
    @import("../webapi/WorkerNavigator.zig"),
    @import("../webapi/NavigatorUAData.zig"),
    @import("../webapi/PluginArray.zig"),
    @import("../webapi/EventTarget.zig"),
    @import("../webapi/Event.zig"),
    @import("../webapi/event/MessageEvent.zig"),
    @import("../webapi/event/ConnectEvent.zig"),
    @import("../dom/DOMException.zig"),
    @import("../webapi/net/URLSearchParams.zig"),
    @import("../webapi/encoding/TextEncoder.zig"),
    @import("../webapi/encoding/TextDecoder.zig"),
    @import("../webapi/Blob.zig"),
    @import("../webapi/File.zig"),
    @import("../webapi/Console.zig"),
    @import("../webapi/Crypto.zig"),
    @import("../webapi/net/FormData.zig"),
    @import("../webapi/net/Headers.zig"),
    @import("../webapi/net/Request.zig"),
    @import("../webapi/net/Response.zig"),
    @import("../webapi/streams/TransformStream.zig"),
    @import("../webapi/streams/CompressionStream.zig"),
    @import("../webapi/streams/DecompressionStream.zig"),
    @import("../webapi/streams/ReadableStream.zig"),
    @import("../webapi/streams/ReadableStreamDefaultReader.zig"),
    @import("../webapi/streams/ReadableStreamDefaultController.zig"),
    @import("../webapi/streams/WritableStream.zig"),
    @import("../webapi/streams/WritableStreamDefaultWriter.zig"),
    @import("../webapi/streams/WritableStreamDefaultController.zig"),
    @import("../webapi/encoding/TextEncoderStream.zig"),
    @import("../webapi/encoding/TextDecoderStream.zig"),
    @import("../webapi/AbortSignal.zig"),
    @import("../webapi/AbortController.zig"),
    @import("../webapi/URL.zig"),
    @import("../webapi/canvas/CanvasGradient.zig"),
    @import("../webapi/canvas/TextMetrics.zig"),
    @import("../webapi/canvas/OffscreenCanvas.zig"),
    @import("../webapi/canvas/OffscreenCanvasRenderingContext2D.zig"),
    @import("../webapi/canvas/WebGLRenderingContext.zig"),
    @import("../webapi/canvas/WebGL2RenderingContext.zig").WebGL2RenderingContext,
    @import("../webapi/net/XMLHttpRequest.zig"),
    @import("../webapi/net/XMLHttpRequestEventTarget.zig"),
    @import("../webapi/FileReader.zig"),
    @import("../webapi/broadcast_channel.zig"),
    @import("../webapi/MessageChannel.zig"),
    @import("../webapi/MessagePort.zig"),
    @import("../webapi/Worker.zig"),
    @import("../webapi/SubtleCrypto.zig"),
    @import("../webapi/CryptoKey.zig"),
});

pub const JsApis = PageJsApis ++ [_]type{
    @import("../webapi/DedicatedWorkerGlobalScope.zig").JsApi,
    @import("../webapi/SharedWorkerGlobalScope.zig").JsApi,
    @import("../webapi/WorkerGlobalScope.zig").JsApi,
    @import("../webapi/WorkerLocation.zig").JsApi,
    @import("../webapi/WorkerNavigator.zig").JsApi,
};

test "production page API list excludes the WPT WebDriver helper" {
    inline for (PageJsApis) |JsApi| {
        if (@hasDecl(JsApi.Meta, "name")) {
            try std.testing.expect(!std.mem.eql(u8, JsApi.Meta.name, "WebDriver"));
        }
    }
}
