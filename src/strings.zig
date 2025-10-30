pub const StringTable = struct {
    bytes: ArrayList(u8),
    map: AutoArrayHashMap(String, StringItem),
    string_counter: u32,

    pub const empty: StringTable = .{
        .bytes = .empty,
        .map = .empty,
        .string_counter = 0,
    };

    pub fn deinit(st: *StringTable, gpa: Allocator) void {
        st.bytes.deinit(gpa);
        st.map.deinit(gpa);

        st.* = undefined;
    }

    /// Serialize in the format:
    /// all values little endian
    /// all composite serializations from `serialization.zig`
    /// * bytes: ArrayList(u8)
    /// * map: AutoArrayHashMap(String, StringItem)
    /// * string_counter: u32
    pub fn serialize(st: *const StringTable, w: *Writer) SerializationError!void {
        try serialization.serializeArrayList(u8, &st.bytes, w);
        try serialization.serializeArrayHashMap(AutoArrayHashMap(String, StringItem), &st.map, w);
        try w.writeInt(u32, st.string_counter, .little);
    }

    /// Deserialize in the format:
    /// all values little endian
    /// all composite serializations from `serialization.zig`
    /// * bytes: ArrayList(u8)
    /// * map: AutoArrayHashMap(String, StringItem)
    /// * string_counter: u32
    pub fn deserialize(gpa: Allocator, r: *Reader) DeserializationError!StringTable {
        var bytes = try deserializeArrayList(u8, gpa, r);
        errdefer bytes.deinit(gpa);

        var map = try deserializeArrayHashMap(AutoArrayHashMap(String, StringItem), gpa, r);
        errdefer map.deinit(gpa);

        const string_counter = try r.takeInt(u32, .little);

        return .{
            .bytes = bytes,
            .map = map,
            .string_counter = string_counter,
        };
    }

    pub fn get(st: *const StringTable, s: String) []const u8 {
        return st.getStringItem(st.map.getPtr(s).?);
    }

    fn getStringItem(st: *const StringTable, si: *const StringItem) []const u8 {
        return st.bytes.items[si.offset..][0..si.length];
    }

    pub fn put(st: *StringTable, gpa: Allocator, bytes: []const u8) Allocator.Error!String {
        const si = try st.appendBytes(gpa, bytes);
        try st.map.ensureUnusedCapacity(gpa, 1);

        errdefer comptime unreachable;

        const s: String = blk: {
            defer st.string_counter += 1;
            break :blk @enumFromInt(st.string_counter);
        };

        st.map.putAssumeCapacity(s, si);

        return s;
    }

    fn appendBytes(st: *StringTable, gpa: Allocator, bytes: []const u8) Allocator.Error!StringItem {
        const offset: u32 = @intCast(st.bytes.items.len);
        const length: u32 = @intCast(bytes.len);

        try st.bytes.appendSlice(gpa, bytes);

        return .{
            .offset = offset,
            .length = length,
        };
    }

    pub fn remove(st: *StringTable, s: String) void {
        const si = st.map.fetchSwapRemove(s).?.value;

        st.removeBytes(&si);

        for (st.map.entries.items(.value)) |*e| {
            if (e.offset > si.offset) {
                e.offset -= si.length;
            }
        }
    }

    /// `O(N)` removal
    fn removeBytes(st: *StringTable, si: *const StringItem) void {
        const dest_slice = st.bytes.items[si.offset..];
        const move_slice = dest_slice[si.length..];

        @memmove(dest_slice[0..move_slice.len], move_slice);

        st.bytes.items.len -= si.length;
    }
};

pub const StringItem = struct {
    offset: u32,
    length: u32,

    pub fn get(si: *const StringItem, st: *const StringTable) []const u8 {
        return st.get(si);
    }
};

test StringTable {
    const gpa = std.testing.allocator;

    var st: StringTable = .empty;
    defer st.deinit(gpa);

    const str1 = "foo";
    const str2 = "bazbaz";
    const str3 = "ba";
    const str4 = "bananza";

    const s1 = try st.put(gpa, str1);
    const s2 = try st.put(gpa, str2);
    const s3 = try st.put(gpa, str3);

    try std.testing.expectEqualStrings(str1, st.get(s1));
    try std.testing.expectEqualStrings(str2, st.get(s2));
    try std.testing.expectEqualStrings(str3, st.get(s3));

    st.remove(s2);

    try std.testing.expectEqualStrings(str1, st.get(s1));
    try std.testing.expectEqualStrings(str3, st.get(s3));

    st.remove(s1);

    try std.testing.expectEqualStrings(str3, st.get(s3));

    const s4 = try st.put(gpa, str4);

    try std.testing.expectEqualStrings(str3, st.get(s3));
    try std.testing.expectEqualStrings(str4, st.get(s4));

    st.remove(s4);

    try std.testing.expectEqualStrings(str3, st.get(s3));

    st.remove(s3);
}

test "StringTable.serialize" {
    const gpa = std.testing.allocator;

    var st: StringTable = .empty;
    defer st.deinit(gpa);

    const str1 = "foo";
    const str2 = "bazbaz";
    const str3 = "ba";
    const str4 = "bananza";

    _ = try st.put(gpa, str1);
    _ = try st.put(gpa, str2);
    _ = try st.put(gpa, str3);
    _ = try st.put(gpa, str4);

    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try st.serialize(&aw.writer);

    var fr: Reader = .fixed(aw.written());
    var st2: StringTable = try .deserialize(gpa, &fr);
    defer st2.deinit(gpa);

    { // map

        var st1_it = st.map.iterator();
        while (st1_it.next()) |entry| {
            const si = st2.map.get(entry.key_ptr.*).?;
            try std.testing.expectEqualDeep(entry.value_ptr.*, si);
        }
    }

    { // bytes
        try std.testing.expectEqualStrings(st.bytes.items, st2.bytes.items);
    }

    { // string counter
        try std.testing.expectEqual(st.string_counter, st2.string_counter);
    }
}

pub const String = enum(u32) {
    _,

    pub fn bytes(s: String, st: *const StringTable) []const u8 {
        return st.get(s);
    }

    const FmtData = struct { string: String, st: *const StringTable };
    pub fn fmt(s: String, st: *const StringTable) std.fmt.Alt(FmtData, format) {
        return .{ .data = .{ .string = s, .st = st } };
    }

    fn format(data: FmtData, w: *Writer) Writer.Error!void {
        try w.writeAll(data.string.bytes(data.st));
    }
};

const std = @import("std");
const serialization = @import("serialization.zig");

const assert = std.debug.assert;

const serializeArrayList = serialization.serializeArrayList;
const deserializeArrayList = serialization.deserializeArrayList;

const serializeMultiArrayList = serialization.serializeMultiArrayList;
const deserializeMultiArrayList = serialization.deserializeMultiArrayList;

const serializeArrayHashMap = serialization.serializeArrayHashMap;
const deserializeArrayHashMap = serialization.deserializeArrayHashMap;

const SerializationError = serialization.SerializationError;
const DeserializationError = serialization.DeserializationError;

const ArrayList = std.ArrayList;
const AutoArrayHashMap = std.AutoArrayHashMapUnmanaged;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Reader = std.Io.Reader;
