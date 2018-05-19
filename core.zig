const std = @import("std");
const builtin = @import("builtin");

const os = std.os;
const heap = std.heap;
const mem = std.mem;
const debug = std.debug;

/// Represents a parameter for the command line.
/// Parameters come in three kinds:
///   * Short ("-a"): Should be used for the most commonly used parameters in your program.
///     * They can take a value three different ways.
///       * "-a value"
///       * "-a=value"
///       * "-avalue"
///     * They chain if they don't take values: "-abc".
///       * The last given parameter can take a value in the same way that a single parameter can:
///         * "-abc value"
///         * "-abc=value"
///         * "-abcvalue"
///   * Long ("--long-arg"): Should be used for less common parameters, or when no single character
///                          can describe the paramter.
///     * They can take a value two different ways.
///       * "--long-arg value"
///       * "--long-arg=value"
///   * Value ("some-value"): Should be used as the primary parameter of the program, like a
///                           filename or an expression to parse.
pub fn Param(comptime Id: type) type {
    return struct {
        const Self = this;

        id: Id,
        short: ?u8,
        long: ?[]const u8,
        takes_value: bool,

        /// Initialize a ::Param.
        /// If ::name.len == 0, then it's a value parameter: "some-command value".
        /// If ::name.len == 1, then it's a short parameter: "some-command -s".
        /// If ::name.len > 1, then it's a long parameter: "some-command --long".
        pub fn init(id: Id, name: []const u8, takes_value: bool) Self {
            return Self{
                .id = id,
                .short = if (name.len == 1) name[0] else null,
                .long = if (name.len > 1) name else null,
                .takes_value = takes_value,
            };
        }

        pub fn both(id: Id, short: u8, long: []const u8, takes_value: bool) Self {
            return Self{
                .id = id,
                .short = short,
                .long = long,
                .takes_value = takes_value,
            };
        }

        pub fn with(param: &const Self, comptime field_name: []const u8, value: var) Self {
            var res = *param;
            @field(res, field_name) = value;
            return res;
        }
    };
}

pub fn Arg(comptime Id: type) type {
    return struct {
        const Self = this;

        id: Id,

        /// ::Iterator owns ::value. On windows, this means that when you call ::Iterator.deinit
        /// ::value is freed.
        value: ?[]const u8,

        pub fn init(id: Id, value: ?[]const u8) Self {
            return Self {
                .id = id,
                .value = value,
            };
        }
    };
}

pub const ArgIterator = struct {
    const Error = error{OutOfMemory};

    nextFn: fn(iter: &ArgIterator, allocator: &mem.Allocator) Error!?[]const u8,

    pub fn next(iter: &ArgIterator, allocator: &mem.Allocator) Error!?[]const u8 {
        return iter.nextFn(iter, allocator);
    }
};

pub const ArgSliceIterator = struct {
    args: []const []const u8,
    index: usize,
    iter: ArgIterator,

    pub fn init(args: []const []const u8) ArgSliceIterator {
        return ArgSliceIterator {
            .args = args,
            .index = 0,
            .iter = ArgIterator {
                .nextFn = nextFn,
            },
        };
    }

    fn nextFn(iter: &ArgIterator, allocator: &mem.Allocator) ArgIterator.Error!?[]const u8 {
        const self = @fieldParentPtr(ArgSliceIterator, "iter", iter);
        if (self.args.len <= self.index)
            return null;

        defer self.index += 1;
        return self.args[self.index];
    }
};

pub const OsArgIterator = struct {
    args: os.ArgIterator,
    iter: ArgIterator,

    pub fn init() OsArgIterator {
        return OsArgIterator {
            .args = os.args(),
            .iter = ArgIterator {
                .nextFn = nextFn,
            },
        };
    }

    fn nextFn(iter: &ArgIterator, allocator: &mem.Allocator) ArgIterator.Error!?[]const u8 {
        const self = @fieldParentPtr(OsArgIterator, "iter", iter);
        if (builtin.os == builtin.Os.windows) {
            return try self.args.next(allocator) ?? return null;
        } else {
            return self.args.nextPoxix();
        }
    }
};

/// A ::CustomIterator with a default Windows buffer size.
pub fn Iterator(comptime Id: type) type {
    return struct {
        const Self = this;

        const State = union(enum) {
            Normal,
            Chaining: Chaining,

            const Chaining = struct {
                arg: []const u8,
                index: usize,
                param: &const Param(Id),
            };
        };

        arena: heap.ArenaAllocator,
        params: []const Param(Id),
        inner: &ArgIterator,
        state: State,

        pub fn init(params: []const Param(Id), inner: &ArgIterator, allocator: &mem.Allocator) Self {
            var res = Self {
                .arena = heap.ArenaAllocator.init(allocator),
                .params = params,
                .inner = inner,
                .state = State.Normal,
            };

            return res;
        }

        pub fn deinit(iter: &Self) void {
            iter.arena.deinit();
        }

        /// Get the next ::Arg that matches a ::Param.
        pub fn next(iter: &Self) !?Arg(Id) {
            const ArgInfo = struct {
                const Kind = enum { Long, Short, Value };

                arg: []const u8,
                kind: Kind,
            };

            switch (iter.state) {
                State.Normal => {
                    const full_arg = (try iter.innerNext()) ?? return null;
                    const arg_info = blk: {
                        var arg = full_arg;
                        var kind = ArgInfo.Kind.Value;

                        if (mem.startsWith(u8, arg, "--")) {
                            arg = arg[2..];
                            kind = ArgInfo.Kind.Long;
                        } else if (mem.startsWith(u8, arg, "-")) {
                            arg = arg[1..];
                            kind = ArgInfo.Kind.Short;
                        }

                        if (arg.len == 0)
                            return error.ArgWithNoName;

                        break :blk ArgInfo { .arg = arg, .kind = kind };
                    };

                    const arg = arg_info.arg;
                    const kind = arg_info.kind;
                    const eql_index = mem.indexOfScalar(u8, arg, '=');

                    for (iter.params) |*param| {
                        switch (kind) {
                            ArgInfo.Kind.Long => {
                                const long = param.long ?? continue;
                                const name = if (eql_index) |i| arg[0..i] else arg;
                                const maybe_value = if (eql_index) |i| arg[i + 1..] else null;

                                if (!mem.eql(u8, name, long))
                                    continue;
                                if (!param.takes_value) {
                                    if (maybe_value != null)
                                        return error.DoesntTakeValue;

                                    return Arg(Id).init(param.id, null);
                                }

                                const value = blk: {
                                    if (maybe_value) |v|
                                        break :blk v;

                                    break :blk (try iter.innerNext()) ?? return error.MissingValue;
                                };

                                return Arg(Id).init(param.id, value);
                            },
                            ArgInfo.Kind.Short => {
                                const short = param.short ?? continue;
                                if (short != arg[0])
                                    continue;

                                return try iter.chainging(State.Chaining {
                                    .arg = full_arg,
                                    .index = (full_arg.len - arg.len) + 1,
                                    .param = param,
                                });
                            },
                            ArgInfo.Kind.Value => {
                                if (param.long) |_| continue;
                                if (param.short) |_| continue;

                                return Arg(Id).init(param.id, arg);
                            }
                        }
                    }

                    return error.InvalidArgument;
                },
                @TagType(State).Chaining => |state| return try iter.chainging(state),
            }
        }

        fn chainging(iter: &Self, state: &const State.Chaining) !?Arg(Id) {
            const arg = state.arg;
            const index = state.index;
            const curr_param = state.param;

            if (curr_param.takes_value) {
                iter.state = State.Normal;

                if (arg.len <= index) {
                    const value = (try iter.innerNext()) ?? return error.MissingValue;
                    return Arg(Id).init(curr_param.id, value);
                }

                if (arg[index] == '=') {
                    return Arg(Id).init(curr_param.id, arg[index + 1..]);
                }

                return Arg(Id).init(curr_param.id, arg[index..]);
            }

            if (arg.len <= index) {
                iter.state = State.Normal;
                return Arg(Id).init(curr_param.id, null);
            }

            for (iter.params) |*param| {
                const short = param.short ?? continue;
                if (short != arg[index])
                    continue;

                iter.state = State { .Chaining = State.Chaining {
                    .arg = arg,
                    .index = index + 1,
                    .param = param,
                }};
                return Arg(Id).init(curr_param.id, null);
            }

            // This actually returns an error for the next argument.
            return error.InvalidArgument;
        }

        fn innerNext(iter: &Self) !?[]const u8 {
            return try iter.inner.next(&iter.arena.allocator);
        }
    };
}

fn testNoErr(params: []const Param(u8), args: []const []const u8, ids: []const u8, values: []const ?[]const u8) void {
    var arg_iter = ArgSliceIterator.init(args);
    var iter = Iterator(u8).init(params, &arg_iter.iter, debug.global_allocator);

    var i: usize = 0;
    while (iter.next() catch unreachable) |arg| : (i += 1) {
        debug.assert(ids[i] == arg.id);
        const expected_value = values[i] ?? {
            debug.assert(arg.value == null);
            continue;
        };
        const actual_value = arg.value ?? unreachable;

        debug.assert(mem.eql(u8, expected_value, actual_value));
    }
}

test "clap.parse: short" {
    const params = []Param(u8) {
        Param(u8).init(0, "a", false),
        Param(u8).init(1, "b", false),
        Param(u8).init(2, "c", true),
    };

    testNoErr(params, [][]const u8 { "-a" },          []u8{0},   []?[]const u8{null});
    testNoErr(params, [][]const u8 { "-a", "-b" },    []u8{0,1}, []?[]const u8{null,null});
    testNoErr(params, [][]const u8 { "-ab" },         []u8{0,1}, []?[]const u8{null,null});
    testNoErr(params, [][]const u8 { "-c=100" },      []u8{2},   []?[]const u8{"100"});
    testNoErr(params, [][]const u8 { "-c100" },       []u8{2},   []?[]const u8{"100"});
    testNoErr(params, [][]const u8 { "-c", "100" },   []u8{2},   []?[]const u8{"100"});
    testNoErr(params, [][]const u8 { "-abc", "100" }, []u8{0,1,2}, []?[]const u8{null,null,"100"});
    testNoErr(params, [][]const u8 { "-abc=100" },    []u8{0,1,2}, []?[]const u8{null,null,"100"});
    testNoErr(params, [][]const u8 { "-abc100" },     []u8{0,1,2}, []?[]const u8{null,null,"100"});
}

test "clap.parse: long" {
    const params = []Param(u8) {
        Param(u8).init(0, "aa", false),
        Param(u8).init(1, "bb", false),
        Param(u8).init(2, "cc", true),
    };

    testNoErr(params, [][]const u8 { "--aa" },         []u8{0},   []?[]const u8{null});
    testNoErr(params, [][]const u8 { "--aa", "--bb" }, []u8{0,1}, []?[]const u8{null,null});
    testNoErr(params, [][]const u8 { "--cc=100" },     []u8{2},   []?[]const u8{"100"});
    testNoErr(params, [][]const u8 { "--cc", "100" },  []u8{2},   []?[]const u8{"100"});
}

test "clap.parse: both" {
    const params = []Param(u8) {
        Param(u8).both(0, 'a', "aa", false),
        Param(u8).both(1, 'b', "bb", false),
        Param(u8).both(2, 'c', "cc", true),
    };

    testNoErr(params, [][]const u8 { "-a" },           []u8{0},     []?[]const u8{null});
    testNoErr(params, [][]const u8 { "-a", "-b" },     []u8{0,1},   []?[]const u8{null,null});
    testNoErr(params, [][]const u8 { "-ab" },          []u8{0,1},   []?[]const u8{null,null});
    testNoErr(params, [][]const u8 { "-c=100" },       []u8{2},     []?[]const u8{"100"});
    testNoErr(params, [][]const u8 { "-c100" },        []u8{2},     []?[]const u8{"100"});
    testNoErr(params, [][]const u8 { "-c", "100" },    []u8{2},     []?[]const u8{"100"});
    testNoErr(params, [][]const u8 { "-abc", "100" },  []u8{0,1,2}, []?[]const u8{null,null,"100"});
    testNoErr(params, [][]const u8 { "-abc=100" },     []u8{0,1,2}, []?[]const u8{null,null,"100"});
    testNoErr(params, [][]const u8 { "-abc100" },      []u8{0,1,2}, []?[]const u8{null,null,"100"});
    testNoErr(params, [][]const u8 { "--aa" },         []u8{0},     []?[]const u8{null});
    testNoErr(params, [][]const u8 { "--aa", "--bb" }, []u8{0,1},   []?[]const u8{null,null});
    testNoErr(params, [][]const u8 { "--cc=100" },     []u8{2},     []?[]const u8{"100"});
    testNoErr(params, [][]const u8 { "--cc", "100" },  []u8{2},     []?[]const u8{"100"});
}
