const std = @import("std");
const build_options = @import("build_options");
const yaml = @import("yaml");

const io = std.io;
const mem = std.mem;

pub const std_options = std.Options{ .log_level = std.log.Level.info };

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

const TestSuiteWalkerError = error{
    FileAccessError,
};

const TestSuiteWalker = struct {
    allocator: std.mem.Allocator,
    walker: std.fs.Dir.Walker,
    prev_entry: ?TestSuite = null,

    pub fn init(allocator: std.mem.Allocator, walker: std.fs.Dir.Walker) TestSuiteWalker {
        return .{
            .allocator = allocator,
            .walker = walker,
        };
    }

    fn deinitPrev(self: *TestSuiteWalker) void {
        if (self.prev_entry) |prev| {
            self.allocator.free(prev.test_name);
            self.allocator.free(prev.in_yaml);
            if (prev.in_json) |in_json| self.allocator.free(in_json);
            if (prev.out_yaml) |out_yaml| self.allocator.free(out_yaml);
        }
    }

    pub const TestSuite = struct {
        path: []const u8,
        test_name: []const u8,
        in_yaml: []const u8,
        in_json: ?[]const u8,
        out_yaml: ?[]const u8,
        expect_error: bool,
    };

    pub fn next(self: *TestSuiteWalker) !?TestSuite {
        self.deinitPrev();

        while (try self.walker.next()) |entry| {
            if (entry.kind != .directory) {
                continue;
            }

            const test_name_file_name = try std.fs.path.join(self.allocator, &[_][]const u8{ entry.basename, "===" });
            defer self.allocator.free(test_name_file_name);

            const test_name = entry.dir.readFileAlloc(self.allocator, test_name_file_name, std.math.maxInt(u32)) catch |err| {
                switch (err) {
                    std.fs.Dir.OpenError.FileNotFound => {
                        continue;
                    },
                    else => {
                        return error.TestSuiteWalkerError;
                    },
                }
            };

            const test_name_trimmed = mem.trim(u8, test_name, " \n");

            const error_file_name = try std.fs.path.join(self.allocator, &[_][]const u8{ entry.basename, "error" });
            defer self.allocator.free(error_file_name);

            const in_yaml_file_name = try std.fs.path.join(self.allocator, &[_][]const u8{ entry.basename, "in.yaml" });
            defer self.allocator.free(in_yaml_file_name);
            const in_yaml = try entry.dir.readFileAlloc(self.allocator, in_yaml_file_name, std.math.maxInt(u32));

            const in_json_file_name = try std.fs.path.join(self.allocator, &[_][]const u8{ entry.basename, "in.json" });
            defer self.allocator.free(in_json_file_name);
            const in_json = entry.dir.readFileAlloc(self.allocator, in_json_file_name, std.math.maxInt(u32)) catch null;

            const out_yaml_file_name = try std.fs.path.join(self.allocator, &[_][]const u8{ entry.basename, "out.yaml" });
            defer self.allocator.free(out_yaml_file_name);
            const out_yaml = entry.dir.readFileAlloc(self.allocator, out_yaml_file_name, std.math.maxInt(u32)) catch null;

            self.prev_entry = .{
                .path = entry.path,
                .test_name = test_name_trimmed,
                .in_yaml = in_yaml,
                .in_json = in_json,
                .out_yaml = out_yaml,
                .expect_error = if (entry.dir.statFile(error_file_name)) |_| true else |_| false,
            };

            return self.prev_entry;
        }

        return null;
    }

    pub fn deinit(self: *TestSuiteWalker) void {
        self.deinitPrev();
        self.walker.deinit();
    }
};

const compat_test_suite_dir = "compat/data";

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const stdout = io.getStdOut().writer();
    const stderr = io.getStdErr().writer();

    const test_suite_dir = std.fs.cwd().openDir(compat_test_suite_dir, .{ .access_sub_paths = true, .iterate = true }) catch |err| {
        switch (err) {
            std.fs.Dir.OpenError.FileNotFound => {
                try stderr.print("Directory '{s}' not found.\nFollow the instructions in 'compat/README.md' to initialize the test suite.\n", .{compat_test_suite_dir});

                return;
            },
            else => {},
        }

        try stderr.print("Unexpected error occured when trying to open '{s}'.\n", .{compat_test_suite_dir});

        return;
    };

    var walker = TestSuiteWalker.init(allocator, try test_suite_dir.walk(allocator));
    defer walker.deinit();

    var failed: usize = 0;
    var total: usize = 0;
    while (try walker.next()) |entry| {
        var test_failed = false;
        total += 1;
        try stdout.print("Running {s} [{s}] ({d})...\n", .{ entry.test_name, entry.path, total });

        if (yaml.Yaml.load(allocator, entry.in_yaml)) |_| {} else |_| {
            if (!entry.expect_error) {
                test_failed = true;
                try stderr.print("FAIL {s} [{s}]\n", .{ entry.test_name, entry.path });
                try stdout.print("in.yaml:\n{s}\n\n", .{entry.in_yaml});
            }
        }

        if (entry.in_json) |in_json| {
            if (yaml.Yaml.load(allocator, in_json)) |_| {} else |_| {
                if (!entry.expect_error) {
                    test_failed = true;
                    try stderr.print("FAIL {s} [{s}]\n", .{ entry.test_name, entry.path });
                    try stdout.print("in.json:\n{s}\n\n", .{in_json});
                }
            }
        }

        if (test_failed) {
            failed += 1;
        }
    }

    try stdout.print("{d} out of {d} tests failed.\n", .{ failed, total });

    if (failed > 0) std.process.exit(1);
}
