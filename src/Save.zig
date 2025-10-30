string_table: StringTable,
items: MultiArrayList(Item),
extra: ArrayList(Untyped),
map: AutoArrayHashMap(Index, u32),
index_counter: u32,

const Save = @This();

pub const empty: Save = .{
    .string_table = .empty,
    .items = .empty,
    .extra = .empty,
    .map = .empty,
    .index_counter = 0,
};

pub fn deinit(s: *Save, gpa: Allocator) void {
    s.string_table.deinit(gpa);

    s.items.deinit(gpa);
    s.extra.deinit(gpa);
    s.map.deinit(gpa);

    s.* = .empty;
}

/// Serialize in the format:
/// all values little endian
/// all composite serializations from `serialization.zig`
/// * `StringTable.deserialize`
/// * items: MultiArrayList(Item)
/// * extra: ArrayList(Untyped)
/// * map: AutoArrayHashMap(Index, u32)
/// * index_counter: u32
pub fn serialize(save: *Save, w: *Writer) SerializationError!void {
    try save.string_table.serialize(w);
    try serializeMultiArrayList(Item, &save.items, w);
    try serializeArrayList(Untyped, &save.extra, w);
    try serializeArrayHashMap(AutoArrayHashMap(Index, u32), &save.map, w);
    try w.writeInt(u32, save.index_counter, .little);
}

/// Deserialize in the format:
/// all values little endian
/// all composite serializations from `serialization.zig`
/// * `StringTable.serialize`
/// * items: MultiArrayList(Item)
/// * extra: ArrayList(Untyped)
/// * map: AutoArrayHashMap(Index, u32)
/// * index_counter: u32
pub fn deserialize(gpa: Allocator, r: *Reader) DeserializationError!Save {
    var string_table = try StringTable.deserialize(gpa, r);
    errdefer string_table.deinit(gpa);

    var items = try deserializeMultiArrayList(Item, gpa, r);
    errdefer items.deinit(gpa);

    var extra = try deserializeArrayList(Untyped, gpa, r);
    errdefer extra.deinit(gpa);

    var map = try deserializeArrayHashMap(AutoArrayHashMap(Index, u32), gpa, r);
    errdefer map.deinit(gpa);

    const index_counter = try r.takeInt(u32, .little);

    return .{
        .string_table = string_table,
        .items = items,
        .extra = extra,
        .map = map,
        .index_counter = index_counter,
    };
}

test serialize {
    const gpa = std.testing.allocator;

    var save: Save = .empty;
    defer save.deinit(gpa);

    const question = "What is the answer to life, the universe, and everything?";
    const answer = "42, obviously";

    const q = try save.string_table.put(gpa, question);
    const a = try save.string_table.put(gpa, answer);

    try save.putSimpleQuestion(gpa, q, a);

    var first: Writer.Allocating = .init(gpa);
    defer first.deinit();

    try save.serialize(&first.writer);

    var copy = blk: {
        var fr: Reader = .fixed(first.written());
        break :blk try Save.deserialize(gpa, &fr);
    };
    defer copy.deinit(gpa);

    try std.testing.expectEqual(save.index_counter, copy.index_counter);
    try std.testing.expectEqualDeep(save.extra, copy.extra);

    var second: Writer.Allocating = .init(gpa);
    defer second.deinit();

    try copy.serialize(&second.writer);

    // serialization idempotency
    try std.testing.expectEqualSlices(u8, first.written(), second.written());
}

pub const Item = struct {
    pub const Type = enum(u8) {
        /// * Left is question `String`.
        /// * Right is answer `String`.
        question_simple = 0,

        /// * Left is question `String`.
        /// * Right is `StringSliceIndex` into extra.
        question_multi = 1,
    };

    type: Type,
    stage: u8,
    srs: Srs,
    left: Untyped,
    right: Untyped,

    pub fn question(item: *const Item) String {
        return switch (item.type) {
            // * Left is question `String`.
            // * Right is answer `String`.
            .question_simple => item.left.asString(),

            // * Left is question `String`.
            // * Right is `StringSliceIndex` into extra.
            .question_multi => item.left.asString(),
        };
    }

    pub fn answers(item: *const Item, save: *const Save) []const String {
        return switch (item.type) {
            // * Left is question `String`.
            // * Right is answer `String`.
            .question_simple => @ptrCast((&item.right)[0..1]),

            // * Left is question `String`.
            // * Right is `StringSliceIndex` into extra.
            .question_multi => item.right.asStringSliceIndex().get(save),
        };
    }
};

pub const Srs = struct {
    deadline_hour: u32,

    pub fn nextDeadline(old_stage: u8, success: bool) struct { u8, Srs } {
        const stage: f64 = blk: {
            const stage: f64 = @floatFromInt(old_stage);
            break :blk @round(switch (success) {
                true => @min(7, stage + 1),
                false => @sqrt(stage),
            });
        };

        // At most 6 months, otherwise
        // https://www.desmos.com/calculator/taaceecsdu
        const next_timeout = @max(@min(
            24 * 30 * 6,
            4 * std.math.pow(f64, stage, 2.6) +
                0.001 * std.math.pow(f64, stage, 8.2),
        ), 1);
        assert(next_timeout >= 0);
        assert(next_timeout == 0 or std.math.isNormal(next_timeout));

        const now_hour: u32 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_hour));
        const hour_timeout: u32 = @intFromFloat(@ceil(next_timeout));

        return .{
            @intFromFloat(stage),
            .{ .deadline_hour = now_hour + hour_timeout },
        };
    }

    /// Returns time until deadline in nanoseconds
    pub fn timeUntil(st: Srs) u64 {
        const now = std.time.nanoTimestamp();
        const deadline = st.toNanos();
        return @intCast(@max(0, deadline -| now));
    }

    pub fn fromNow() Srs {
        const now = std.time.nanoTimestamp();
        return .{ .deadline_hour = @intCast(@divTrunc(now, std.time.ns_per_hour)) };
    }

    pub fn toNanos(st: Srs) u64 {
        return @as(u64, st.deadline_hour) * std.time.ns_per_hour;
    }
};

pub const Untyped = enum(u32) {
    _,

    pub fn cast(any: anytype) Untyped {
        return switch (@typeInfo(@TypeOf(any))) {
            .@"enum" => @enumFromInt(@intFromEnum(any)),
            .int => @enumFromInt(any),
            else => @compileError("Cast undefined for " ++ @typeName(@TypeOf(any))),
        };
    }

    pub fn asStringSliceIndex(u: Untyped) StringSliceIndex {
        return @enumFromInt(@intFromEnum(u));
    }

    pub fn asValue(u: Untyped) u32 {
        return @intFromEnum(u);
    }

    pub fn asString(u: Untyped) String {
        return @enumFromInt(@intFromEnum(u));
    }
};

pub const Index = enum(u32) { _ };

pub const StringSliceIndex = enum(u32) {
    _,

    fn index(ssi: StringSliceIndex) Index {
        return @enumFromInt(@intFromEnum(ssi));
    }

    pub fn get(ssi: StringSliceIndex, s: *const Save) []const String {
        const idx = s.map.get(ssi.index()).?;
        const len = s.extra.items[idx].asValue();

        assert(len > 0);

        return @ptrCast(s.extra.items[idx + 1 ..][0..len]);
    }

    pub fn replace(
        ssi: StringSliceIndex,
        s: *Save,
        gpa: Allocator,
        strs: []const String,
    ) Allocator.Error!void {
        const idx = s.map.get(ssi.index()).?;
        const slice_idx = idx + 1;

        const old_len = s.extra.items[idx].asValue();
        const new_len = strs.len;

        // Take into account the length entry
        const old_len_full = old_len + 1;
        const new_len_full = new_len + 1;

        const additional_len = old_len -| strs.len;

        { // move later entries
            try s.extra.ensureUnusedCapacity(gpa, additional_len);

            // This is probably the easiest way to update this.
            s.extra.items.len -= old_len_full;
            s.extra.items.len += new_len_full;

            // In case we decrease the length we may move items outside the 'used' slice
            const orig_slice = s.extra.allocatedSlice()[slice_idx..][old_len..];
            const dest_slice = s.extra.items[slice_idx..][new_len..];

            // no guarantee which one is smaller, so we calculate
            const end = @min(orig_slice.len, dest_slice.len);

            @memmove(dest_slice[0..end], orig_slice[0..end]);
        }

        { // place new entries
            const dest_slice = s.extra.items[slice_idx..][0..new_len];
            @memcpy(dest_slice, @as([]const Untyped, @ptrCast(strs)));
        }

        // update length
        s.extra.items[idx] = .cast(new_len);

        // Update other indices
        for (s.map.entries.items(.value)) |*value| {
            if (value.* > idx) {
                value.* -= @intCast(old_len_full);
                value.* += @intCast(new_len_full);
            }
        }
    }

    pub fn appendSlice(
        ssi: StringSliceIndex,
        s: *Save,
        gpa: Allocator,
        strs: []const String,
    ) Allocator.Error!void {
        const idx = s.map.get(ssi.index()).?;
        const slice_idx = idx + 1;

        const additional_len = strs.len;

        const old_len = s.extra.items[idx].asValue();
        const new_len = old_len + additional_len;

        { // move later entries
            try s.extra.ensureUnusedCapacity(gpa, strs.len);

            s.extra.items.len += new_len;

            // Since we're increasing the slice length, we cannot move items
            // outside the 'used' slice
            const orig_slice = s.extra.items[slice_idx..][old_len..];
            const dest_slice = s.extra.items[slice_idx..][new_len..];

            // Since we're appending, orig_slice will be bigger
            @memmove(dest_slice, orig_slice[0..dest_slice.len]);
        }

        { // place new entries
            const dest_slice = s.extra.items[slice_idx..][old_len..][0..strs.len];
            @memcpy(dest_slice, @as([]const Untyped, @ptrCast(strs)));
        }

        // update length
        s.extra.items[idx] = .cast(new_len);

        // Update other indices
        for (s.map.entries.items(.value)) |*value| {
            if (value.* > idx) {
                value.* += @intCast(additional_len);
            }
        }
    }

    pub fn remove(ssi: StringSliceIndex, s: *Save) void {
        const idx = s.map.fetchSwapRemove(ssi.index()).?.value;

        const old_len = s.extra.items[idx].asValue();

        // Take into account the length entry
        const old_len_full = old_len + 1;

        { // remove the entries
            // Since we have not yet changed the 'used' slice length and we are
            // removing items, we cannot move items outside the 'used' slice
            const dest_slice = s.extra.items[idx..];
            const orig_slice = s.extra.items[idx..][old_len_full..];

            // Since we're removing, dest_slice will be bigger
            @memmove(dest_slice[0..orig_slice.len], orig_slice);

            s.extra.items.len -= old_len_full;
        }

        // Update other indices
        for (s.map.entries.items(.value)) |*value| {
            if (value.* > idx) {
                value.* -= old_len_full;
            }
        }
    }
};

test StringSliceIndex {
    const gpa = std.testing.allocator;

    var save: Save = .empty;
    defer save.deinit(gpa);

    const str1 = "foo";
    const str2 = "barbar";
    const str3 = "ba";
    const str4 = "bananaza";

    const s1 = try save.string_table.put(gpa, str1);
    const s2 = try save.string_table.put(gpa, str2);
    const s3 = try save.string_table.put(gpa, str3);

    const ssi_pre = try save.putStringSlice(gpa, &.{ s1, s2, s3 });
    const ssi = try save.putStringSlice(gpa, &.{ s1, s2, s3 });
    const ssi_post = try save.putStringSlice(gpa, &.{ s3, s2, s1 });

    try std.testing.expectEqualSlices(String, &.{ s1, s2, s3 }, ssi_pre.get(&save));
    try std.testing.expectEqualSlices(String, &.{ s1, s2, s3 }, ssi.get(&save));
    try std.testing.expectEqualSlices(String, &.{ s3, s2, s1 }, ssi_post.get(&save));

    const s4 = try save.string_table.put(gpa, str4);

    try ssi.appendSlice(&save, gpa, &.{ s4, s3, s2, s1 });
    try std.testing.expectEqualSlices(String, &.{ s1, s2, s3, s4, s3, s2, s1 }, ssi.get(&save));

    try ssi.replace(&save, gpa, &.{ s3, s1, s2 });
    try std.testing.expectEqualSlices(String, &.{ s3, s1, s2 }, ssi.get(&save));

    try ssi.replace(&save, gpa, &.{ s4, s3, s1, s4, s2 });
    try std.testing.expectEqualSlices(String, &.{ s4, s3, s1, s4, s2 }, ssi.get(&save));

    ssi.remove(&save);

    try std.testing.expectEqualSlices(String, &.{ s1, s2, s3 }, ssi_pre.get(&save));
    try std.testing.expectEqualSlices(String, &.{ s3, s2, s1 }, ssi_post.get(&save));
}

pub fn putStringSlice(s: *Save, gpa: Allocator, string_slice: []const String) Allocator.Error!StringSliceIndex {
    assert(string_slice.len > 0);

    try s.map.ensureUnusedCapacity(gpa, 1);
    try s.extra.ensureUnusedCapacity(gpa, string_slice.len + 1);

    errdefer comptime unreachable;

    const idx: StringSliceIndex = blk: {
        defer s.index_counter += 1;
        break :blk @enumFromInt(s.index_counter);
    };

    const gop = s.map.getOrPutAssumeCapacity(idx.index());
    assert(!gop.found_existing);
    gop.value_ptr.* = @intCast(s.extra.items.len);

    // * len
    // * entries
    s.extra.appendAssumeCapacity(.cast(string_slice.len));
    s.extra.appendSliceAssumeCapacity(@ptrCast(string_slice));

    return idx;
}

pub fn putSimpleQuestion(s: *Save, gpa: Allocator, question: String, answer: String) Allocator.Error!void {
    try s.items.append(gpa, .{
        .type = .question_simple,
        .stage = 0,
        .srs = .fromNow(),
        .left = .cast(question),
        .right = .cast(answer),
    });
}

test {
    _ = &strings;
}

const std = @import("std");
const strings = @import("strings.zig");
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

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const MultiArrayList = std.MultiArrayList;
const AutoArrayHashMap = std.AutoArrayHashMapUnmanaged;
const StringTable = strings.StringTable;
const String = strings.String;
const Writer = std.Io.Writer;
const Reader = std.Io.Reader;
