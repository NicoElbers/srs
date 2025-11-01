var stdin_buf: [4096]u8 = undefined;
var stdout_buf: [4096]u8 = undefined;

// TODO: factor all this into a config file
const prefix = "> ";
const app_name = "srs"; // TODO: think of a better name
const saves_folder = "saves";

const Context = struct {
    gpa: Allocator,
    console: *Console,
    save: *Save,
    keep_running: bool,
    err: ?anyerror,
};

const Command = struct {
    func: *const fn (*Context) Error!void,
    name: []const u8,
    docs: ?[]const u8 = null,
};

const commands = [_]Command{
    .{ .name = "list", .func = listFn },
    .{ .name = "add", .func = addFn },
    .{ .name = "ask", .func = askFn },
    .{ .name = "save", .func = saveFn },
    .{ .name = "load", .func = loadFn },
    .{ .name = "help", .func = helpFn },
    .{ .name = "exit", .func = exitFn },
};

pub fn main() !u8 {
    var stdin_reader: File.Reader = .initStreaming(.stdin(), &stdin_buf);
    var stdout_writer: File.Writer = .initStreaming(.stdout(), &stdout_buf);
    const tty: std.Io.tty.Config = .detect(.stdout());

    var dbg_inst: std.heap.DebugAllocator(.{}) = .init;
    defer _ = dbg_inst.deinit();
    const gpa = dbg_inst.allocator();

    var save: Save = .empty;
    defer save.deinit(gpa);

    var console: Console = .init(
        &stdin_reader.interface,
        &stdout_writer.interface,
        tty,
    );
    defer console.deinit();

    var ctx: Context = .{
        .gpa = gpa,
        .console = &console,
        .save = &save,
        .keep_running = true,
        .err = null,
    };

    cliCommandLoop(&ctx) catch |err| {
        const saved_err = ctx.err; // can't let this final save override it

        saveFn(&ctx) catch |e| switch (e) {
            error.ReadFailed => {},
            error.WriteFailed => {},
            else => stdout_writer.interface.print("Error: Failed to save: {t}\n", .{e}) catch {},
        };

        console.flush() catch {};

        return switch (err) {
            error.Unhandled => saved_err orelse error.Unknown,
            error.ReadFailed => stdin_reader.err.?,
            error.WriteFailed => stdout_writer.err.?,
            error.EndOfStream => std.process.exit(1), // exit quietly, but with code 1
            error.OutOfMemory => error.OutOfMemory,
        };
    };

    console.flush() catch return stdout_writer.err.?;

    saveFn(&ctx) catch |err| return switch (err) {
        error.Unhandled => ctx.err orelse error.Unknown,
        error.ReadFailed => stdin_reader.err.?,
        error.WriteFailed => stdout_writer.err.?,
        error.EndOfStream => std.process.exit(1), // exit quietly, but with code 1
        error.OutOfMemory => error.OutOfMemory,
    };
}

pub const Error = Reader.Error || Writer.Error || Allocator.Error || error{Unhandled};
fn cliCommandLoop(ctx: *Context) Error!void {
    const console = ctx.console;
    const save = ctx.save;

    try loadFn(ctx);
    try helpFn(ctx);

    const eql = std.ascii.eqlIgnoreCase;
    loop: while (ctx.keep_running) {
        const op = try console.ask(&.{prefix});

        for (commands) |command| {
            if (!eql(op, command.name)) continue;

            try command.func(ctx);
            continue :loop;
        } else if (eql(op, "warp")) { // NOTE: private commands
            const num_txt = try console.ask(&.{ "How much? (H)\n", prefix });
            const num = std.fmt.parseInt(u32, num_txt, 0) catch @panic("Fuck you");

            const srs_list: []Save.Srs = save.items.items(.srs);
            for (srs_list) |*srs| {
                srs.deadline_hour -= num;
            }
        } else {
            try console.printLn("Command '{s}' not found", .{op});
            try helpFn(ctx);
        }
    }

    try saveFn(ctx);
}

fn helpFn(ctx: *Context) Error!void {
    const console = ctx.console;

    try console.writeLn("Commands:");

    for (commands) |command| {
        try console.printLn("\t{s}", .{command.name});
    }

    try console.write("\n");
    try console.stdout.flush();
}

fn exitFn(ctx: *Context) Error!void {
    ctx.keep_running = false;
}

fn appDataDir(ctx: *Context) Error!Dir {
    const gpa = ctx.gpa;

    // TODO: allow data dir override in config file
    var global_data_dir = known_folders.open(gpa, .data, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return unexpecedError(err, ctx),
    } orelse return unexpecedError(error.FileNotFound, ctx);
    defer global_data_dir.close();

    return global_data_dir.openDir(app_name, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            global_data_dir.makeDir(app_name) catch |inner_err| switch (inner_err) {
                error.PathAlreadyExists => {}, // Success?
                else => return unexpecedError(inner_err, ctx),
            };

            return global_data_dir.openDir(app_name, .{}) catch |inner_err|
                return unexpecedError(inner_err, ctx);
        },
        else => unexpecedError(err, ctx),
    };
}

fn savesDir(ctx: *Context, opts: std.fs.Dir.OpenOptions) Error!Dir {
    const app_data_dir = try appDataDir(ctx);

    return app_data_dir.openDir(saves_folder, opts) catch |err| switch (err) {
        error.FileNotFound => {
            app_data_dir.makeDir(saves_folder) catch |inner_err| switch (inner_err) {
                error.PathAlreadyExists => {}, // Success?
                else => return unexpecedError(inner_err, ctx),
            };

            return app_data_dir.openDir(saves_folder, opts) catch |inner_err|
                return unexpecedError(inner_err, ctx);
        },
        else => unexpecedError(err, ctx),
    };
}

// TODO: mechanism to prune old saves
fn saveFn(ctx: *Context) Error!void {
    const gpa = ctx.gpa;

    const file: File = loop: while (true) {
        var saves_dir = try savesDir(ctx, .{});
        defer saves_dir.close();

        const path = try std.fmt.allocPrint(gpa, "save-{d}", .{std.time.nanoTimestamp()});
        defer gpa.free(path);

        break :loop saves_dir.createFile(path, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return unexpecedError(err, ctx),
        };
    };
    defer file.close();

    var buf: [1024]u8 = undefined;
    var file_writer: std.fs.File.Writer = .init(file, &buf);

    ctx.save.serialize(&file_writer.interface) catch |err| switch (err) {
        error.WriteFailed => return unexpecedError(file_writer.err.?, ctx),
    };

    file_writer.interface.flush() catch |err| switch (err) {
        error.WriteFailed => return unexpecedError(file_writer.err.?, ctx),
    };

    try ctx.console.printLn("Saved {d} items!", .{ctx.save.items.len});
}

fn loadFn(ctx: *Context) Error!void {
    const save = ctx.save;
    const console = ctx.console;
    const gpa = ctx.gpa;

    var lowest_corrupted_save: u128 = std.math.maxInt(u128);
    outer: while (true) {
        var highest_seen_save: u128 = 0;

        const file: File = blk: {
            var saves_dir = try savesDir(ctx, .{ .iterate = true });
            defer saves_dir.close();

            var file: ?File = null;

            var it = saves_dir.iterate();
            while (it.next() catch |err| switch (err) {
                else => return unexpecedError(err, ctx),
            }) |entry| {
                switch (entry.kind) {
                    .file => {},
                    else => continue,
                }

                const pre, const post = std.mem.cut(u8, entry.name, "-") orelse continue;
                if (!std.mem.eql(u8, "save", pre)) continue;

                const num = std.fmt.parseInt(u128, post, 10) catch continue;

                if (num <= highest_seen_save or num >= lowest_corrupted_save) continue;

                const file_copy = file;

                file = saves_dir.openFile(entry.name, .{}) catch continue;

                highest_seen_save = num;
                if (file_copy) |f| f.close();
            }

            break :blk file orelse {
                try console.writeLn("No saves found");
                return;
            };
        };
        defer file.close();

        var buf: [1024]u8 = undefined;
        var file_reader: std.fs.File.Reader = .init(file, &buf);

        // TODO: more corruption detection in saves
        const new_save = Save.deserialize(gpa, &file_reader.interface) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ReadFailed => return unexpecedError(file_reader.err.?, ctx),

            error.Corrupt,
            error.EndOfStream,
            => {
                std.log.err("Found corrupted save, ignoring", .{});
                lowest_corrupted_save = highest_seen_save;
                continue :outer;
            },
        };

        save.deinit(gpa);
        save.* = new_save;

        try ctx.console.printLn("Loaded {d} items!", .{save.items.len});
        return;
    }
}

fn askFn(ctx: *Context) Error!void {
    const console = ctx.console;
    const save = ctx.save;
    const gpa = ctx.gpa;

    const st = &save.string_table;

    const IndexedItem = struct { idx: usize, item: Save.Item };

    var questions: ArrayList(IndexedItem) = .empty;
    defer questions.deinit(gpa);

    const srs_slice: []Save.Srs = save.items.items(.srs);
    const stage_slice: []u8 = save.items.items(.stage);

    for (srs_slice, 0..) |srs, idx| {
        if (srs.timeUntil() != 0) continue;

        try questions.append(gpa, .{ .idx = idx, .item = save.items.get(idx) });
    }

    var scratch: ArrayList(IndexedItem) = try .initCapacity(gpa, questions.items.len);
    defer scratch.deinit(gpa);

    try console.print("Found {d} questions to be asked\n", .{questions.items.len});

    var current: *ArrayList(IndexedItem) = &questions;
    var next: *ArrayList(IndexedItem) = &scratch;

    var round: u32 = 0;
    while (current.items.len > 0) : (round += 1) {
        defer {
            std.mem.swap(*ArrayList(IndexedItem), &current, &next);
            next.clearRetainingCapacity();
        }

        for (current.items) |indexed_item| {
            const idx = indexed_item.idx;
            const item = &indexed_item.item;

            const question = item.question();
            const answers = item.answers(save);

            const answer = try console.ask(&.{ question.bytes(st), "\n", prefix });

            const eql = std.ascii.eqlIgnoreCase;
            const correct = loop: for (answers) |ans| {
                if (eql(answer, ans.bytes(st))) {
                    break :loop true;
                }
            } else false;

            if (correct) {
                const stage, const srs = Save.Srs.nextDeadline(stage_slice[idx], round == 0);
                srs_slice[idx] = srs;
                stage_slice[idx] = stage;

                try console.writeLn("Correct!");
            } else {
                next.appendAssumeCapacity(indexed_item);

                try console.writeLn("Incorrect:");
                try console.printLn("\tYou said '{s}'", .{answer});
                try console.writeLn("\tAnswer could be one of:");
                for (answers) |ans| {
                    try console.printLn("\t\t{f}", .{ans.fmt(st)});
                }
            }

            try console.write("\n");
        }
    }
}

fn addFn(ctx: *Context) Error!void {
    const console = ctx.console;
    const save = ctx.save;
    const gpa = ctx.gpa;

    const st = &save.string_table;

    const question = try st.put(gpa, try console.ask(&.{ "Question\n", prefix }));
    const answer = try st.put(gpa, try console.ask(&.{ "Answer\n", prefix }));

    try save.putSimpleQuestion(gpa, question, answer);
}

fn listFn(ctx: *Context) Error!void {
    const console = ctx.console;
    const save = ctx.save;

    const st = &save.string_table;

    try ctx.console.writeLn("Listing all questions:\n");

    for (0..save.items.len) |idx| {
        const item = save.items.get(idx);

        try console.print("Srs deadline in {D}\n", .{item.srs.timeUntil()});

        switch (item.type) {
            // * Left is question `String`.
            // * Right is answer `String`.
            .question_simple => {
                const question = item.left.asString();
                const answer = item.right.asString();

                try console.print(
                    "simple question: {f} => {f}\n",
                    .{ question.fmt(st), answer.fmt(st) },
                );
            },

            // * Left is question `String`.
            // * Right is `StringSliceIndex` into extra.
            .question_multi => {
                const question = item.left.asString();
                const answers = item.right.asStringSliceIndex().get(save);

                try console.print("multi question: {f} =>\n", .{question.fmt(st)});
                for (answers) |answer| {
                    try console.print("\t{f}\n", .{answer.fmt(st)});
                }
            },
        }

        try ctx.console.write("\n");
    }
}

fn unexpecedError(err: anyerror, ctx: *Context) error{Unhandled} {
    ctx.err = err;
    return error.Unhandled;
}

test {
    _ = &Save;
    _ = &Console;
}

const std = @import("std");
const known_folders = @import("known_folders");

const assert = std.debug.assert;

const Save = @import("Save.zig");
const Console = @import("Console.zig");
const Io = std.Io;
const File = std.fs.File;
const Reader = Io.Reader;
const Writer = Io.Writer;
const Config = Io.tty.Config;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Dir = std.fs.Dir;
