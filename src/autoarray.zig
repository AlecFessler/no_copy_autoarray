const std = @import("std");
const page_size = std.mem.page_size;

pub fn AutoArray(comptime T: type) type {
    return struct {
        const Self = @This();

        base_ptr: [*]align(page_size) T,
        capacity: u64,
        size: u64,

        pub fn init(initial_capacity: u64, base_addr: ?[*]align(page_size) u8) !Self {
            const items_per_page = page_size / @sizeOf(T);
            const num_pages = (initial_capacity + items_per_page - 1) / items_per_page;
            const mapped_size = num_pages * page_size;
            const capacity = mapped_size / @sizeOf(T);

            const mem = try std.posix.mmap(base_addr, mapped_size, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED_NOREPLACE = base_addr != null }, -1, 0);

            return .{
                .base_ptr = @as([*]align(page_size) T, @alignCast(@ptrCast(mem.ptr))),
                .capacity = capacity,
                .size = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            const items_per_page = page_size / @sizeOf(T);
            const num_pages = (self.capacity + items_per_page - 1) / items_per_page;
            const mapped_size = num_pages * page_size;
            const page_aligned_u8_ptr = @as([*]align(page_size) u8, @alignCast(@ptrCast(self.base_ptr)));
            std.posix.munmap(page_aligned_u8_ptr[0..mapped_size]);
        }

        /// Attempts to expand the array's capacity with new page(s)
        /// First tries to map additional contiguous virtual memory
        /// If that fails (due to address conflicts), it will fall back
        /// to allocating a new buffer and copying the elements over
        fn expand(self: *Self, new_capacity: u64) !void {
            std.debug.assert(new_capacity > self.capacity);

            const items_per_page = page_size / @sizeOf(T);

            const current_num_pages = (self.capacity + items_per_page - 1) / items_per_page;
            const current_mapped_size = current_num_pages * page_size;

            const expanded_num_pages = (new_capacity + items_per_page - 1) / items_per_page;
            const expanded_mapped_size = expanded_num_pages * page_size;

            const size_difference = expanded_mapped_size - current_mapped_size;

            const base_u8_ptr = @as([*]u8, @ptrCast(self.base_ptr));
            const desired_addr = @as([*]align(page_size) u8, @alignCast(base_u8_ptr + current_mapped_size));

            _ = std.posix.mmap(desired_addr, size_difference, std.posix.PROT.READ | std.posix.PROT.WRITE, .{
                .TYPE = .PRIVATE,
                .ANONYMOUS = true,
                .FIXED_NOREPLACE = true,
            }, -1, 0) catch |err| {
                if (err == error.MappingAlreadyExists) {
                    const full_new_mem = try std.posix.mmap(null, expanded_mapped_size, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);

                    const old_slice = self.base_ptr[0..self.size];
                    const new_ptr = @as([*]align(page_size) T, @alignCast(@ptrCast(full_new_mem.ptr)));
                    @memcpy(new_ptr[0..self.size], old_slice);

                    const old_ptr = @as([*]align(page_size) u8, @alignCast(@ptrCast(self.base_ptr)));
                    std.posix.munmap(old_ptr[0..current_mapped_size]);

                    self.base_ptr = new_ptr;
                } else return err;
            };

            self.capacity = expanded_mapped_size / @sizeOf(T);
        }
    };
}

test "AutoArray initialization allocates full page capacity" {
    const TestStruct = struct {
        x: u64,
        y: u64,
    };

    // initialize with less than one page worth of items
    const base_addr = @as([*]align(page_size) u8, @ptrFromInt(0x40000000));
    var array = try AutoArray(TestStruct).init(1, base_addr);
    defer array.deinit();

    // expect the capacity to be one full page worth of items
    const items_per_page = page_size / @sizeOf(TestStruct);
    try std.testing.expectEqual(items_per_page, array.capacity);
}

test "AutoArray initilization rounds up to full pages" {
    const TestStruct = struct {
        x: u64,
        y: u64,
    };

    // calculate a capacity of 1.5 pages worth of items
    const items_per_page = page_size / @sizeOf(TestStruct);
    const one_and_half_pages = items_per_page + items_per_page / 2;

    const base_addr = @as([*]align(page_size) u8, @ptrFromInt(0x80000000));
    var array = try AutoArray(TestStruct).init(one_and_half_pages, base_addr);
    defer array.deinit();

    // expect the capacity to round up to two full pages
    try std.testing.expectEqual(items_per_page * 2, array.capacity);
}

test "AutoArray zero-copy expansion" {
    const TestStruct = struct {
        x: u64,
        y: u64,
    };

    // initialize with exactly one page
    const base_addr = @as([*]align(page_size) u8, @ptrFromInt(0xC0000000));
    const items_per_page = page_size / @sizeOf(TestStruct);
    var array = try AutoArray(TestStruct).init(items_per_page, base_addr);
    defer array.deinit();

    // save the original address to verify contiguous expansion
    const original_addr = array.base_ptr;

    // expand to two pages
    try array.expand(items_per_page * 2);

    // verify we can write to and read from the second page
    array.base_ptr[items_per_page] = .{ .x = 1998, .y = 1998 };
    try std.testing.expectEqual(@as(u64, 1998), array.base_ptr[items_per_page].x);

    // verify the base ptr didn't change (zero-copy successful)
    try std.testing.expectEqual(original_addr, array.base_ptr);
}

test "AutoArray fallback expansion when address space is occupied" {
    const TestStruct = struct {
        x: u64,
        y: u64,
    };

    // initialize with exactly one page
    const base_addr = @as([*]align(page_size) u8, @ptrFromInt(0x100000000));
    const items_per_page = page_size / @sizeOf(TestStruct);
    var array = try AutoArray(TestStruct).init(items_per_page, base_addr);
    defer array.deinit();

    // map the next page to force a fallback
    const next_page_u8_ptr = @as([*]u8, @ptrCast(array.base_ptr));
    const next_page_addr = @as([*]align(page_size) u8, @alignCast(next_page_u8_ptr + page_size));
    const blocker_mem = try std.posix.mmap(next_page_addr, page_size, std.posix.PROT.READ | std.posix.PROT.WRITE, .{
        .TYPE = .PRIVATE,
        .ANONYMOUS = true,
        .FIXED_NOREPLACE = true,
    }, -1, 0);
    defer std.posix.munmap(blocker_mem);

    // verify the returned address equals the next page address
    try std.testing.expectEqual(next_page_addr, blocker_mem.ptr);

    // save the original address to verify fallback
    const original_addr = array.base_ptr;

    // expand to two pages
    try array.expand(items_per_page * 2);

    // verify the address changes (indicating fallback to copy)
    try std.testing.expect(original_addr != array.base_ptr);
}
