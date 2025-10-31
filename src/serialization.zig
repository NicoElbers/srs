pub const SerializationError = Writer.Error;
pub const DeserializationError = Reader.Error || Allocator.Error || error{Corrupt};

pub const output_endian: std.builtin.Endian = .little;

fn hasSerializableLayout(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .type,
        .comptime_float,
        .comptime_int,
        .enum_literal,
        => false, // comptime only

        .undefined,
        .noreturn,
        .@"anyframe",
        => false, // not instanciable

        .@"fn",
        .@"opaque",
        .frame,
        .null,
        => false, // undefined size

        .error_union,
        .error_set,
        => false, // compilation unit dependent

        .@"enum",
        .void,
        .bool,
        .int,
        .float,
        => true, // trivial

        .pointer => |info| switch (info.size) {
            .slice => hasSerializableLayout(info.child),
            .one => switch (@typeInfo(info.child)) {
                .array => hasSerializableLayout(info.child),
                else => false, // pointer bad
            },

            .many,
            .c,
            => false, // undefined size
        },

        inline .vector,
        .array,
        => |info| hasSerializableLayout(info.child),

        .@"struct" => |info| {
            inline for (info.fields) |field| {
                if (field.is_comptime or
                    !hasSerializableLayout(field.type))
                    return false;
            }
            return true;
        },

        .optional => |info| hasSerializableLayout(info.child),

        .@"union" => |info| switch (info.layout) {
            .@"extern", .@"packed" => false,
            .auto => {
                if (info.tag_type == null) return false; // undeserializable
                inline for (info.fields) |field| {
                    if (!hasSerializableLayout(field.type))
                        return false;
                }
                return true;
            },
        },
    };
}

test hasSerializableLayout {
    try std.testing.expect(!hasSerializableLayout(@TypeOf(type)));
    try std.testing.expect(!hasSerializableLayout(comptime_int));
    try std.testing.expect(!hasSerializableLayout(comptime_float));
    try std.testing.expect(!hasSerializableLayout(@TypeOf(.enum_literal)));
    try std.testing.expect(!hasSerializableLayout(@TypeOf(undefined)));
    try std.testing.expect(!hasSerializableLayout(@TypeOf(anyopaque)));
    try std.testing.expect(!hasSerializableLayout(@TypeOf(&hasSerializableLayout)));
    try std.testing.expect(!hasSerializableLayout(@TypeOf(null)));
    try std.testing.expect(!hasSerializableLayout(@TypeOf(error.Test)));
    try std.testing.expect(!hasSerializableLayout(error{Test}));

    try std.testing.expect(hasSerializableLayout(enum(u32) { a }));
    try std.testing.expect(hasSerializableLayout(enum(u32) { a, b, c, d }));
    try std.testing.expect(hasSerializableLayout(void));
    try std.testing.expect(hasSerializableLayout(bool));
    try std.testing.expect(hasSerializableLayout(u8));
    try std.testing.expect(hasSerializableLayout(u0));
    try std.testing.expect(hasSerializableLayout(f32));

    try std.testing.expect(hasSerializableLayout([10]u32));
    try std.testing.expect(hasSerializableLayout(@Vector(10, u32)));

    try std.testing.expect(hasSerializableLayout([]u32));
    try std.testing.expect(hasSerializableLayout([][]u32));
    try std.testing.expect(hasSerializableLayout(*[10]u32));
    try std.testing.expect(!hasSerializableLayout(*u32));
    try std.testing.expect(!hasSerializableLayout([*]u32));
    try std.testing.expect(!hasSerializableLayout([*c]u32));

    try std.testing.expect(hasSerializableLayout(?u32));
    try std.testing.expect(hasSerializableLayout(?[]?u32));
    try std.testing.expect(hasSerializableLayout(??u32));

    try std.testing.expect(hasSerializableLayout(packed struct { foo: u32 }));
    try std.testing.expect(hasSerializableLayout(extern struct { foo: u32 }));
    try std.testing.expect(hasSerializableLayout(struct { foo: u32 }));
    try std.testing.expect(hasSerializableLayout(struct { u32 }));
    try std.testing.expect(!hasSerializableLayout(packed struct { foo: u32, bar: *u32, baz: u32 }));
    try std.testing.expect(!hasSerializableLayout(extern struct { foo: u32, bar: *u32, baz: u32 }));
    try std.testing.expect(!hasSerializableLayout(struct { foo: u32, bar: *u32, baz: u32 }));
    try std.testing.expect(!hasSerializableLayout(struct { u32, *u32, u32 }));

    try std.testing.expect(hasSerializableLayout(union(enum(u32)) { foo: u32 }));
    try std.testing.expect(hasSerializableLayout(union(enum) { foo: u32 }));
    try std.testing.expect(hasSerializableLayout(union(enum) { foo }));
    try std.testing.expect(!hasSerializableLayout(union(enum(u32)) { foo: u32, bar: *u32, baz: u32 }));
    try std.testing.expect(!hasSerializableLayout(union { foo: u32 }));
    try std.testing.expect(!hasSerializableLayout(packed union { foo: u32 }));
    try std.testing.expect(!hasSerializableLayout(extern union { foo: u32 }));
}

pub fn typeHashed(comptime T: type) u64 {
    var wh: Wyhash = .init(0);
    typeHash(T, &wh);
    return wh.final();
}

pub fn typeHash(comptime T: type, h: *Wyhash) void {
    const update = struct {
        // This is a hacky mess, but it's not exposed so I don't really care
        pub fn update(hasher: *Wyhash, value: anytype) void {
            switch (@typeInfo(@TypeOf(value))) {
                .comptime_int => update(hasher, @as(u64, value)),
                .int => |info| {
                    const bits = @sizeOf(@TypeOf(value)) * 8;
                    const Int = @Type(.{ .int = .{ .bits = bits, .signedness = info.signedness } });
                    const v = @as(Int, value);
                    hasher.update(@ptrCast(&v));
                },
                .pointer => |info| switch (info.size) {
                    .slice => hasher.update(@ptrCast(value)),
                    .one, .c, .many => comptime unreachable,
                },
                .@"enum" => update(hasher, @intFromEnum(value)),
                .bool => update(hasher, @intFromBool(value)),
                else => @compileError(@typeName(@TypeOf(value))),
            }
        }
    }.update;

    switch (@typeInfo(T)) {
        .void => update(h, 0x944f79b977618c5c),

        .bool => update(h, 0x3555f6dfaad20701),

        .@"enum" => |info| {
            update(h, 0x53e97517b5e47dc1);
            typeHash(info.tag_type, h);
        },

        .float => |info| {
            update(h, 0xb87a017c0c9bbe19);
            update(h, info.bits);
        },
        .int => |info| {
            update(h, 0xf98c7d000dae5ef7);
            update(h, info.bits);
            update(h, info.signedness);
        },

        .pointer => |info| {
            update(h, 0x4074c124d170a19e);
            update(h, info.size);
            update(h, info.alignment);
            typeHash(info.child, h);
        },

        .vector => |info| {
            update(h, 0xf6b9b4b652b746d5);
            update(info.len);
            typeHash(info.child, h);
        },
        .array => |info| {
            update(h, 0xa808ae6440b45ce0);
            update(h, info.len);
            typeHash(info.child, h);
        },

        .@"struct" => |info| {
            update(h, 0x7cbb0290a9720c92);

            // We switch here because:
            // 1) packed and non packed have different serialization strategies
            // 2) auto and extern should be interchangable
            switch (info.layout) {
                .@"packed" => {
                    update(h, 0x92ef82ba7c4488ac);
                    typeHash(info.backing_integer.?, h);
                },
                .auto, .@"extern" => {
                    update(h, 0x34eb1692d96183c8);
                },
            }

            inline for (sortStructFields(T)) |field| {
                update(h, field.name);
                typeHash(field.type, h);
            }
        },

        .optional => |info| {
            update(h, 0x69d8119ec3c61182);
            typeHash(info.child, h);
        },

        .@"union" => |info| {
            update(h, 0x1761c42833e3fc7a);

            // two of the layouts are non serializable, but we allow it in a
            // typehash anyway
            update(h, info.layout);
            typeHash(info.tag_type.?, h);

            // NOTE: it's not fine to allow adding union variats because:
            // 1) A new variant might be bigger requiring more space to
            //    serialize
            // 2) There is no way to sort the fields such that an arbitrary
            //    new field will go to the end

            inline for (sortUnionFields(T)) |field| {
                update(h, field.name);
                typeHash(field.type, h);
            }
        },

        .type,
        .comptime_float,
        .comptime_int,
        .enum_literal,
        => comptime unreachable, // comptime only

        .undefined,
        .noreturn,
        .@"anyframe",
        => comptime unreachable, // as far as I'm aware, uninstanciable

        .@"fn",
        .@"opaque",
        .frame,
        .null,
        => comptime unreachable, // undefined size

        .error_union,
        .error_set,
        => comptime unreachable, // compilation unit dependent
    }
}

test typeHash {
    const hash = typeHashed;

    try std.testing.expect(hash(void) == hash(void));
    try std.testing.expect(hash(void) != hash(u0));

    try std.testing.expect(hash(u0) != hash(u1));
    try std.testing.expect(hash(u32) != hash(i32));
    try std.testing.expect(hash(u32) != hash(f32));
    try std.testing.expect(hash([]u8) != hash([]u16));
    try std.testing.expect(hash([5]u8) != hash([5]u16));
    try std.testing.expect(hash([5]u8) != hash([4]u8));
    try std.testing.expect(hash(*[5]u8) != hash(*[4]u8));
    try std.testing.expect(hash(*[5]u8) != hash(*[5]u16));

    try std.testing.expect(hash(*[5]u8) == hash(*const [5]u8));
    try std.testing.expect(hash([]u8) == hash([]const u8));

    try std.testing.expect(hash(extern struct { foo: u8 }) != hash(extern struct { bar: u8 }));
    try std.testing.expect(hash(packed struct { foo: u8 }) != hash(packed struct { bar: u8 }));
    try std.testing.expect(hash(packed struct { foo: u8 }) != hash(extern struct { foo: u8 }));

    // Field order is independent
    try std.testing.expect(
        hash(extern struct { foo: u8, bar: u8 }) ==
            hash(extern struct { bar: u8, foo: u8 }),
    );

    try std.testing.expect(
        hash(struct { foo: u8, bar: u8 }) ==
            hash(struct { bar: u8, foo: u8 }),
    );

    // Also between extern and auto
    try std.testing.expect(
        hash(struct { foo: u8, bar: u8 }) ==
            hash(extern struct { bar: u8, foo: u8 }),
    );

    // Except for packed, field order is very depenent here
    try std.testing.expect(
        hash(packed struct { foo: u8, bar: u8 }) !=
            hash(packed struct { bar: u8, foo: u8 }),
    );

    try std.testing.expect(
        hash(packed struct { foo: u8, bar: u8 }) !=
            hash(extern struct { bar: u8, foo: u8 }),
    );

    try std.testing.expect(
        hash(packed struct { foo: u8, bar: u8 }) !=
            hash(struct { bar: u8, foo: u8 }),
    );
}

pub fn serialize(comptime T: type, value: *const T, w: *Writer) SerializationError!void {
    if (comptime !hasSerializableLayout(T)) {
        @compileError(@typeName(T) ++ " not serializable");
    }

    switch (@typeInfo(T)) {
        .void,
        => {}, // zst

        .bool => try w.writeByte(@intFromBool(value.*)),

        .@"enum" => |info| try w.writeInt(info.tag_type, @intFromEnum(value.*), output_endian),

        .float => |info| {
            const Int = @Type(.{ .int = .{ .bits = info.bits, .signedness = .unsigned } });
            try w.writeInt(Int, @bitCast(value.*), output_endian);
        },
        .int => |info| {
            const bits = @sizeOf(T) * 8;
            const Int = @Type(.{ .int = .{ .bits = bits, .signedness = info.signedness } });

            try w.writeInt(Int, value.*, output_endian);
        },

        .pointer => |info| switch (info.size) {
            .slice => {
                try w.writeInt(u32, @intCast(value.len), output_endian);
                for (value.*) |*elem| {
                    try serialize(info.child, elem, w);
                }
            },
            .one => try serialize(info.child, value.*, w),

            .many,
            .c,
            => comptime unreachable,
        },

        .vector => |info| {
            inline for (0..info.len) |i| {
                try serialize(info.child, &value[i], w);
            }
        },
        .array => |info| {
            for (value) |*elem| {
                try serialize(info.child, elem, w);
            }
        },

        .@"struct" => |info| switch (info.layout) {
            .@"packed" => try w.writeInt(info.backing_integer.?, @bitCast(value.*), output_endian),

            .auto,
            .@"extern",
            => {
                inline for (sortStructFields(T)) |field| {
                    try serialize(field.type, &@field(value.*, field.name), w);
                }
            },
        },

        .optional => |info| {
            // We use a bool effectively to say if the optional was null (0) or
            // will follow (1)
            if (value.*) |*v| {
                try w.writeByte(1);
                try serialize(info.child, v, w);
            } else {
                try w.writeByte(0);
            }
        },

        .@"union" => |info| switch (info.layout) {
            .@"extern", .@"packed" => comptime unreachable,
            .auto => {
                switch (value.*) {
                    inline else => |*pl, tag| {
                        try serialize(info.tag_type.?, &tag, w);
                        try serialize(@TypeOf(pl.*), pl, w);
                    },
                }
            },
        },

        else => comptime unreachable,
    }
}

pub fn deserialize(comptime T: type, gpa: Allocator, r: *Reader) DeserializationError!T {
    if (comptime !hasSerializableLayout(T)) {
        @compileError(@typeName(T) ++ " not serializable");
    }

    return switch (@typeInfo(T)) {
        .void,
        => {}, // zst

        .bool => switch (try r.takeByte()) {
            0 => false,
            1 => true,
            else => error.Corrupt,
        },

        .@"enum" => r.takeEnum(T, output_endian) catch |err| switch (err) {
            error.ReadFailed => error.ReadFailed,
            error.EndOfStream => error.EndOfStream,
            error.InvalidEnumTag => error.Corrupt,
        },

        .int => |info| {
            // bit size for a byte aligned number
            const bits = @sizeOf(T) * 8;
            const Int = @Type(.{ .int = .{ .bits = bits, .signedness = info.signedness } });

            const int = try r.takeInt(Int, output_endian);
            return std.math.cast(T, int) orelse return error.Corrupt;
        },

        .float => |info| blk: {
            const Int = @Type(.{ .int = .{ .bits = info.bits, .signedness = .unsigned } });
            const int = try r.takeInt(Int, output_endian);
            break :blk @as(T, @bitCast(int));
        },

        .pointer => |info| switch (info.size) {
            .slice => {
                const length = try r.takeInt(u32, output_endian);

                const slice = try gpa.allocWithOptions(
                    info.child,
                    length,
                    .fromByteUnits(info.alignment),
                    info.sentinel(),
                );
                errdefer gpa.free(slice);

                for (slice) |*elem| {
                    elem.* = try deserialize(info.child, gpa, r);
                }
                return slice;
            },
            .one => {
                const ptr = try gpa.create(info.child);
                errdefer gpa.destroy(ptr);

                ptr.* = try deserialize(info.child, gpa, r);
                return ptr;
            },

            .many,
            .c,
            => comptime unreachable,
        },

        .vector => |info| {
            var vec: T = undefined;

            inline for (0..info.len) |i| {
                vec[i] = try deserialize(info.child, gpa, r);
            }
            return vec;
        },
        .array => |info| {
            var arr: T = undefined;

            for (&arr) |*elem| {
                elem.* = try deserialize(info.child, gpa, r);
            }

            return arr;
        },

        .@"struct" => |info| switch (info.layout) {
            .@"packed" => {
                const backing = try r.takeInt(info.backing_integer.?, output_endian);
                return @as(T, @bitCast(backing));
            },

            .auto,
            .@"extern",
            => {
                var val: T = undefined;

                inline for (sortStructFields(T)) |field| {
                    @field(val, field.name) = try deserialize(field.type, gpa, r);
                }

                return val;
            },
        },

        .optional => |info| return switch (try r.takeByte()) {
            0 => null,
            1 => try deserialize(info.child, gpa, r),
            else => error.Corrupt,
        },

        .@"union" => |info| switch (info.layout) {
            .@"extern", .@"packed" => comptime unreachable,
            .auto => {
                const tag = try deserialize(std.meta.Tag(T), .failing, r);

                switch (tag) {
                    inline else => |t| {
                        const name = @tagName(t);
                        const FT = @FieldType(T, name);
                        return @unionInit(T, name, try deserialize(FT, gpa, r));
                    },
                }
            },
        },

        else => comptime unreachable,
    };
}

test serialize {
    const Arena = std.heap.ArenaAllocator;

    const tst = struct {
        pub fn tst(comptime T: type, arena: *Arena, val: T) !void {
            _ = arena.reset(.retain_capacity);
            var aw: Writer.Allocating = .init(arena.allocator());
            defer aw.deinit();

            try serialize(T, &val, &aw.writer);

            var fr: Reader = .fixed(aw.written());
            const copy = try deserialize(T, arena.allocator(), &fr);

            try std.testing.expectEqual(aw.written().len, fr.end);
            try std.testing.expectEqualDeep(val, copy);

            var aw2: Writer.Allocating = .init(arena.allocator());
            defer aw2.deinit();

            try serialize(T, &copy, &aw2.writer);

            // Serialization idempotency
            try std.testing.expectEqualSlices(u8, aw.written(), aw2.written());
        }
    }.tst;

    var a: Arena = .init(std.testing.allocator);
    defer a.deinit();

    var prng: Random.DefaultPrng = .init(std.testing.random_seed);
    const r = prng.random();

    try tst(u32, &a, r.int(u32));
    try tst(u5, &a, r.int(u5));
    try tst(u0, &a, r.int(u0));

    try tst(i32, &a, r.intRangeLessThan(i32, std.math.minInt(i32), 0));
    try tst(i5, &a, r.intRangeLessThan(i5, std.math.minInt(i5), 0));
    try tst(i0, &a, 0);
    try tst(i1, &a, -1);

    try tst(f16, &a, 0x3d5b4405bc4fb61e.0); // r.float is cringe
    try tst(f32, &a, r.float(f32));
    try tst(f64, &a, r.float(f64));
    try tst(f80, &a, 0x25754d443887f65e.0); // r.float is cringe
    try tst(f128, &a, 0x67e5a4ab744ea376.0); // r.float is cringe

    try tst(bool, &a, true);
    try tst(bool, &a, false);
    try tst(void, &a, {});

    try tst(enum(u32) { foo }, &a, .foo);

    try tst([]const u32, &a, &.{ r.int(u32), r.int(u32), r.int(u32) });
    try tst([]const u32, &a, &.{});

    try tst([:0]const u8, &a, "Hello");

    try tst(*const [3]u32, &a, &.{ r.int(u32), r.int(u32), r.int(u32) });
    try tst([3]u32, &a, .{ r.int(u32), r.int(u32), r.int(u32) });
    try tst([0]u32, &a, .{});

    try tst(@Vector(3, u32), &a, .{ r.int(u32), r.int(u32), r.int(u32) });
    try tst(@Vector(0, u32), &a, .{});

    try tst(?u32, &a, null);
    try tst(?u32, &a, r.int(u32));
    try tst(??u32, &a, @as(??u32, null));
    try tst(??u32, &a, @as(?u32, null));
    try tst(?*const [3]u32, &a, null);
    try tst(?*const [3]u32, &a, &.{ r.int(u32), r.int(u32), r.int(u32) });

    try tst(extern struct { foo: u32 }, &a, .{ .foo = r.int(u32) });
    try tst(extern struct { foo: [1]u32 }, &a, .{ .foo = .{r.int(u32)} });

    try tst(struct { foo: u32 }, &a, .{ .foo = r.int(u32) });
    try tst(struct { foo: [1]u32 }, &a, .{ .foo = .{r.int(u32)} });

    try tst(packed struct { foo: u32 }, &a, .{ .foo = r.int(u32) });

    try tst(struct { u32 }, &a, .{r.int(u32)});
    try tst(struct { [1]u32 }, &a, .{.{r.int(u32)}});

    try tst(union(enum(u32)) { foo: u32 }, &a, .{ .foo = r.int(u32) });
    try tst(union(enum(u32)) { foo: u32, bar: u32 }, &a, .{ .foo = r.int(u32) });
}

/// Serialize a MultiArrayList in the following format:
/// All numbers in little endian
/// * length: u32
/// * per field list of items
///
/// NOTE: Capacity is left implicit
pub fn serializeMultiArrayList(
    comptime T: type,
    mal: *const MultiArrayList(T),
    w: *Writer,
) SerializationError!void {
    const MT = MultiArrayList(T);
    const Field = MT.Field;

    const length: u32 = @intCast(mal.len);

    try w.writeInt(u32, length, output_endian);
    inline for (sortStructFields(T)) |field| {
        const items = mal.items(std.meta.stringToEnum(Field, field.name).?);
        assert(items.len == length);

        for (items) |*item| {
            try serialize(@TypeOf(item.*), item, w);
        }
    }
}

/// Deserialize a MultiArrayList in the following format:
/// All numbers in little endian
/// * length: u32
/// * per field list of items
///
/// NOTE: Capacity is left implicit
pub fn deserializeMultiArrayList(
    comptime T: type,
    gpa: Allocator,
    r: *Reader,
) DeserializationError!MultiArrayList(T) {
    const MT = MultiArrayList(T);
    const Field = MT.Field;

    const length = try r.takeInt(u32, output_endian);

    const byte_length = MT.capacityInBytes(length);
    const bytes = try gpa.alignedAlloc(u8, .of(T), byte_length);
    errdefer gpa.free(bytes);

    var mal: MultiArrayList(T) = .{
        .bytes = bytes.ptr,
        .len = length,
        .capacity = length,
    };

    inline for (sortStructFields(T)) |field| {
        const items = mal.items(std.meta.stringToEnum(Field, field.name).?);
        assert(items.len == length);
        for (items) |*item| {
            item.* = try deserialize(@TypeOf(item.*), gpa, r);
        }
    }

    return mal;
}

pub fn eqlMultiArrayList(comptime T: type, a: *const MultiArrayList(T), b: *const MultiArrayList(T)) !void {
    try std.testing.expectEqual(a.len, b.len);

    for (0..a.len) |idx| {
        try std.testing.expectEqualDeep(a.get(idx), b.get(idx));
    }
}

test "MultiArrayList serialization" {
    const gpa = std.testing.allocator;

    const Foo = struct { a: u8, b: u64, c: u32 };

    inline for (&.{ 0, 1, 2, 100 }) |size| {
        var mal: MultiArrayList(Foo) = .empty;
        defer mal.deinit(gpa);

        var prng: Random.DefaultPrng = .init(std.testing.random_seed);
        const rand = prng.random();

        for (0..size) |_| {
            try mal.append(gpa, .{ .a = rand.int(u8), .b = rand.int(u64), .c = rand.int(u32) });
        }

        var aw: Writer.Allocating = .init(gpa);
        defer aw.deinit();

        try serializeMultiArrayList(Foo, &mal, &aw.writer);

        var fr: Reader = .fixed(aw.written());

        var copy = try deserializeMultiArrayList(Foo, gpa, &fr);
        defer copy.deinit(gpa);

        try eqlMultiArrayList(Foo, &mal, &copy);
    }
}

/// Serializes an ArrayList in the following format:
/// All values are little endian
/// * length: u32
/// * `@as([]const u8, @ptrCast(al.items))`
///
/// NOTE: the capacity is left implicit
pub fn serializeArrayList(
    comptime T: type,
    al: *const ArrayList(T),
    w: *Writer,
) SerializationError!void {
    try serialize([]T, &al.items, w);
}

/// Deserializes an ArrayList in the following format:
/// All values are little endian
/// * length: u32
/// * `serialize([]T)`
///
/// NOTE: the capacity is left implicit
pub fn deserializeArrayList(
    comptime T: type,
    gpa: Allocator,
    r: *Reader,
) DeserializationError!ArrayList(T) {
    const items = try deserialize([]T, gpa, r);

    return .{
        .items = items,
        .capacity = items.len,
    };
}

test "ArrayList serialization" {
    const gpa = std.testing.allocator;

    const Foo = struct { a: u8, b: u64, c: u32 };

    inline for (&.{ 0, 1, 100 }) |size| {
        var al: ArrayList(Foo) = .empty;
        defer al.deinit(gpa);

        var prng: Random.DefaultPrng = .init(std.testing.random_seed);
        const rand = prng.random();

        for (0..size) |_| {
            try al.append(gpa, .{ .a = rand.int(u8), .b = rand.int(u64), .c = rand.int(u32) });
        }

        var aw: Writer.Allocating = .init(gpa);
        defer aw.deinit();

        try serializeArrayList(Foo, &al, &aw.writer);

        var fr: Reader = .fixed(aw.written());

        var copy = try deserializeArrayList(Foo, gpa, &fr);
        defer copy.deinit(gpa);

        try std.testing.expectEqualSlices(Foo, al.items, copy.items);
    }
}

/// Serializes an AutoHashMap(Unmanaged) in the following format:
/// All values are little endian
/// * `serializeMultiArrayList(T.Data, &ahm.entries)`
pub fn serializeArrayHashMap(
    comptime T: type,
    ahm: *const T,
    w: *Writer,
) SerializationError!void {
    const Data = T.Data;

    try serializeMultiArrayList(Data, &ahm.entries, w);
}

/// Deserializes an AutoHashMap(Unmanaged) in the following format:
/// All values are little endian
/// * `serializeMultiArrayList(T.Data, &ahm.entries)`
pub fn deserializeArrayHashMap(
    comptime T: type,
    gpa: Allocator,
    r: *Reader,
) DeserializationError!T {
    const Data = T.Data;

    var map: T = .{
        .entries = try deserializeMultiArrayList(Data, gpa, r),
    };
    errdefer map.deinit(gpa);

    try map.reIndex(gpa);

    return map;
}

test "AutoArrayHashMap serialization" {
    const gpa = std.testing.allocator;

    const Foo = struct { a: u8, b: u64, c: u32 };

    inline for (&.{ 0, 1, 100, 1_000 }) |size| {
        var aahm: AutoArrayHashMap(Foo, Foo) = .empty;
        defer aahm.deinit(gpa);

        var prng: Random.DefaultPrng = .init(std.testing.random_seed);
        const rand = prng.random();

        for (0..size) |_| {
            const gop: AutoArrayHashMap(Foo, Foo).GetOrPutResult = loop: while (true) {
                const gop = try aahm.getOrPut(gpa, .{ .a = rand.int(u8), .b = rand.int(u64), .c = rand.int(u32) });
                if (gop.found_existing) continue;
                break :loop gop;
            };

            gop.value_ptr.* = .{ .a = rand.int(u8), .b = rand.int(u64), .c = rand.int(u32) };
        }

        var aw: Writer.Allocating = .init(gpa);
        defer aw.deinit();

        try serializeArrayHashMap(AutoArrayHashMap(Foo, Foo), &aahm, &aw.writer);

        var fr: Reader = .fixed(aw.written());

        var copy = try deserializeArrayHashMap(AutoArrayHashMap(Foo, Foo), gpa, &fr);
        defer copy.deinit(gpa);

        try eqlMultiArrayList(AutoArrayHashMap(Foo, Foo).Data, &aahm.entries, &copy.entries);

        var aw2: Writer.Allocating = .init(gpa);
        defer aw2.deinit();

        try serializeArrayHashMap(AutoArrayHashMap(Foo, Foo), &copy, &aw2.writer);

        // serliazation idempotency
        try std.testing.expectEqualSlices(u8, aw.written(), aw2.written());
    }
}

fn sortUnionFields(comptime T: type) [@typeInfo(T).@"union".fields.len]UnionField {
    comptime {
        const lessThanFn = struct {
            pub fn lessThanFn(_: void, a: UnionField, b: UnionField) bool {
                const end = @min(a.name.len, b.name.len);
                for (a.name[0..end], b.name[0..end]) |a_byte, b_byte| {
                    switch (std.math.order(a_byte, b_byte)) {
                        .lt => return true,
                        .eq => {},
                        .gt => return false,
                    }
                }
                return a.name.len < b.name.len;
            }
        }.lessThanFn;

        const info = @typeInfo(T).@"union";
        @setEvalBranchQuota(10 * info.fields.len * info.fields.len);

        var fields: [info.fields.len]UnionField = undefined;
        @memcpy(&fields, info.fields);
        std.sort.insertion(UnionField, &fields, {}, lessThanFn);
        return fields;
    }
}

fn sortStructFields(comptime T: type) [@typeInfo(T).@"struct".fields.len]StructField {
    comptime {
        const info = @typeInfo(T).@"struct";
        @setEvalBranchQuota(10 * info.fields.len * info.fields.len);

        switch (info.layout) {
            .@"packed" => {
                // The bit layout of packed structs really matter, especially since
                // our serialization strategy is to just write out the backing
                // integer, therefore we sort on bit offset

                const lessThanFn = struct {
                    pub fn lessThanFn(_: void, a: StructField, b: StructField) bool {
                        return @bitOffsetOf(T, a.name) < @bitOffsetOf(T, b.name);
                    }
                }.lessThanFn;

                var fields: [info.fields.len]StructField = undefined;
                @memcpy(&fields, info.fields);
                std.sort.insertion(StructField, &fields, {}, lessThanFn);
                return fields;
            },
            .@"extern", .auto => {
                // The layout of auto/extern sturcts matters a lot less, as long
                // as it's consistent with serialization and deserialization.
                // Therefore we can safely sort by field names to be a little
                // more lenient with reordering of fields.

                const lessThanFn = struct {
                    pub fn lessThanFn(_: void, a: StructField, b: StructField) bool {
                        const end = @min(a.name.len, b.name.len);
                        for (a.name[0..end], b.name[0..end]) |a_byte, b_byte| {
                            switch (std.math.order(a_byte, b_byte)) {
                                .lt => return true,
                                .eq => {},
                                .gt => return false,
                            }
                        }
                        return a.name.len < b.name.len;
                    }
                }.lessThanFn;

                var fields: [info.fields.len]StructField = undefined;
                @memcpy(&fields, info.fields);
                std.sort.insertion(StructField, &fields, {}, lessThanFn);
                return fields;
            },
        }
    }
}

const std = @import("std");

const assert = std.debug.assert;

const Io = std.Io;
const Writer = Io.Writer;
const Reader = Io.Reader;
const MultiArrayList = std.MultiArrayList;
const ArrayList = std.ArrayList;
const AutoArrayHashMap = std.AutoArrayHashMapUnmanaged;
const Allocator = std.mem.Allocator;
const Random = std.Random;
const Wyhash = std.hash.Wyhash;
const Type = std.builtin.Type;
const StructField = Type.StructField;
const UnionField = Type.UnionField;
