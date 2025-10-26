/// Serialize a MultiArrayList in the following format:
/// All numbers in little endian
/// * length (u32)
/// * `MultiArrayList.capacity` (u32)
/// * `MultiArrayList(T).capacityInBytes(capacity)` bytes
///
/// WARN: elements of T are NOT byte swapped to any particular endianness
pub fn serializeMultiArrayList(
    comptime T: type,
    mal: *const MultiArrayList(T),
    w: *Writer,
) Writer.Error!void {
    const MT = MultiArrayList(T);

    const length: u32 = @intCast(mal.len);
    const capacity: u32 = @intCast(mal.capacity);

    const byte_length: u32 = @intCast(MT.capacityInBytes(capacity));
    const bytes = mal.bytes[0..byte_length];

    try w.writeInt(u32, length, .little);
    try w.writeInt(u32, capacity, .little);
    try w.writeAll(bytes);
}

/// Deserialize a MultiArrayList in the following format:
/// All numbers in little endian
/// * length (u32)
/// * `MultiArrayList.capacity` (u32)
/// * `MultiArrayList(T).capacityInBytes(capacity)` bytes
///
/// WARN: elements of T are NOT byte swapped to any particular endianness
pub fn deserializeMultiArrayList(
    comptime T: type,
    gpa: Allocator,
    r: *Reader,
) (Allocator.Error || Reader.Error)!MultiArrayList(T) {
    const MT = MultiArrayList(T);

    const length = try r.takeInt(u32, .little);
    const capacity = try r.takeInt(u32, .little);

    const byte_length: u32 = @intCast(MT.capacityInBytes(capacity));
    const bytes = try gpa.alignedAlloc(u8, .of(T), byte_length);
    var fw: Writer = .fixed(bytes);

    r.streamExact(&fw, byte_length) catch |err| switch (err) {
        error.ReadFailed => return error.ReadFailed,
        error.EndOfStream => return error.EndOfStream,
        error.WriteFailed => unreachable, // fixed writer cannot fail
    };

    return .{
        .bytes = bytes.ptr,
        .len = length,
        .capacity = capacity,
    };
}

fn eqlMultiArrayList(comptime T: type, a: *const T, b: *const T) !void {
    try std.testing.expectEqual(a.capacity, b.capacity);
    try std.testing.expectEqual(a.len, b.len);

    const byte_length: u32 = @intCast(T.capacityInBytes(a.capacity));
    try std.testing.expectEqualSlices(u8, a.bytes[0..byte_length], b.bytes[0..byte_length]);
}

test "MultiArrayList serialization" {
    const gpa = std.testing.allocator;

    const Foo = struct { a: u8, b: u64, c: u32 };

    inline for (&.{ 0, 1, 100 }) |size| {
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

        try eqlMultiArrayList(MultiArrayList(Foo), &mal, &copy);
    }
}

/// Serializes an ArrayList in the following format:
/// All values are little endian
/// * length (u32)
/// * `@as([]const u8, @ptrCast(al.items))`
///
/// NOTE: the capacity is left implicit
/// WARN: elements of T are NOT byte swapped to any particular endianness
pub fn serializeArrayList(
    comptime T: type,
    al: *const ArrayList(T),
    w: *Writer,
) Writer.Error!void {
    const length: u32 = @intCast(al.items.len);
    const bytes: []const u8 = @ptrCast(al.items);

    assert(bytes.len == @sizeOf(T) * length);

    try w.writeInt(u32, length, .little);
    try w.writeAll(bytes);
}

/// Deserializes an ArrayList in the following format:
/// All values are little endian
/// * length (u32)
/// * `@as([]const u8, @ptrCast(al.items))`
///
/// NOTE: the capacity is left implicit
/// WARN: elements of T are NOT byte swapped to any particular endianness
pub fn deserializeArrayList(
    comptime T: type,
    gpa: Allocator,
    r: *Reader,
) (Reader.Error || Allocator.Error)!ArrayList(T) {
    const length = try r.takeInt(u32, .little);
    const byte_length = length * @sizeOf(T);

    const bytes = try gpa.alignedAlloc(u8, .of(T), byte_length);
    var fw: Writer = .fixed(bytes);
    r.streamExact(&fw, byte_length) catch |err| switch (err) {
        error.ReadFailed => return error.ReadFailed,
        error.EndOfStream => return error.EndOfStream,
        error.WriteFailed => unreachable, // fixed writer cannot fail
    };

    return .{
        .items = @ptrCast(bytes),
        .capacity = length,
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
///
/// WARN: elements of T are NOT byte swapped to any particular endianness
pub fn serializeArrayHashMap(
    comptime T: type,
    ahm: *const T,
    w: *Writer,
) Writer.Error!void {
    try serializeMultiArrayList(T.Data, &ahm.entries, w);
}

/// Deserializes an AutoHashMap(Unmanaged) in the following format:
/// All values are little endian
/// * `serializeMultiArrayList(T.Data, &ahm.entries)`
///
/// WARN: elements of T are NOT byte swapped to any particular endianness
pub fn deserializeArrayHashMap(
    comptime T: type,
    gpa: Allocator,
    r: *Reader,
) (Allocator.Error || Reader.Error)!T {
    const entries = try deserializeMultiArrayList(T.Data, gpa, r);

    var map: T = .{ .entries = entries };
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

        try eqlMultiArrayList(AutoArrayHashMap(Foo, Foo).DataList, &aahm.entries, &copy.entries);
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
