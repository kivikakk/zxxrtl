# zxxrtl

[CXXRTL] bindings for Zig.

[CXXRTL]: https://yosyshq.readthedocs.io/projects/yosys/en/latest/cmd/write_cxxrtl.html

## Example

[ili9341spi] uses this in combination with [Niar] to build a CXXRTL simulation
with [Amaranth] and Zig.

[ili9341spi]: https://github.com/kivikakk/ili9341spi
[Niar]: https://github.com/kivikakk/niar
[Amaranth]: https://amaranth-lang.org

## Setup

> [!NOTE]
> This guide assumes you're driving the build from outside, and use Zig's build
> system just to build the Zig parts and link the final object. This gives you a
> lot of flexibility, but if you don't need it, you can simplify a lot by
> bringing the CXXRTL object file building into your `build.zig` too. Refer to
> [zxxrtl's `build.zig`] for guidance.

[zxxrtl's `build.zig`]: https://github.com/kivikakk/zxxrtl/blob/main/build.zig

Add zxxrtl to your `build.zig.zon`:

```console
zig fetch --save https://github.com/kivikakk/zxxrtl/archive/<commit>.tar.gz
```

Add the import to your `build.zig`. You'll need to find Yosys's data dir to get the header includes;
you'll also need to know the CXXRTL compiled object files to link against. A serving suggestion
follows.

First, add options to specify the Yosys data dir and object files in your `build()` function:

```zig
const yosys_data_dir = b.option([]const u8, "yosys_data_dir", "yosys data dir (per yosys-config --datdir)")
    orelse @import("zxxrtl").guessYosysDataDir(b);
const cxxrtl_o_paths = b.option([]const u8, "cxxrtl_o_paths", "comma-separated paths to .o files to link against, including CXXRTL simulation")
    orelse "../build/cxxrtl/ili9341spi.o";
```

We'll attempt to call `yosys-config` if a data dir isn't specified explicitly.
We also supply a default value for the object file paths --- this should match
your development environment. These defaults ensure ZLS still works.

Then add the dependency, and add the module as an import to your executable:

```zig
const zxxrtl_mod = b.dependency("zxxrtl", .{
    .target = target,
    .optimize = optimize,
    .yosys_data_dir = yosys_data_dir,
}).module("zxxrtl");
exe.root_module.addImport("zxxrtl", zxxrtl_mod);
```

If you always want to rely on the Yosys data dir guessing, you can just omit all
the `yosys_dat_dir`-related parts and zxxrtl will take care of it.

The last step is to link against the CXXRTL object files:

```zig
var it = std.mem.split(u8, cxxrtl_o_paths, ",");
while (it.next()) |cxxrtl_o_path| {
    exe.addObjectFile(b.path(cxxrtl_o_path));
}
```

## Usage

```zig
const Cxxrtl = @import("zxxrtl");

// Initialise the design.
const cxxrtl = Cxxrtl.init();

// Optionally start recording VCD. Assume `vcd_out` is `?[]const u8` representing an
// optional output filename.
var vcd: ?Cxxrtl.Vcd = null;
if (vcd_out != null) vcd = Cxxrtl.Vcd.init(cxxrtl);

defer {
    if (vcd) |*vcdh| vcdh.deinit();
    cxxrtl.deinit();
}

// Get handles to the clock and reset lines.
const clk = cxxrtl.get(bool, "clk");
const rst = cxxrtl.get(bool, "rst");  // These are of type `Cxxrtl.Object(bool)`.

// Reset for a tick.
rst.next(true);

clk.next(false);
cxxrtl.step();
if (vcd) |*vcdh| vcdh.sample();

clk.next(true);
cxxrtl.step();
if (vcd) |*vcdh| vcdh.sample();

rst.next(false);

// Play out 10 cycles.
for (0..10) |_| {
    clk.next(false);
    cxxrtl.step();
    if (vcd) |*vcdh| vcdh.sample();

    clk.next(true);
    cxxrtl.step();
    if (vcd) |*vcdh| vcdh.sample();
}

if (vcd) |*vcdh| {
    // Assume `alloc` exists.
    const buffer = try vcdh.read(alloc);
    defer alloc.free(buffer);

    var file = try std.fs.cwd().createFile(vcd_out.?, .{});
    defer file.close();

    try file.writeAll(buffer);
}
```

`Cxxrtl.Object(T)` is the basic interface to CXXRTL objects. It exposes two
methods: `curr(Self) T`, and `next(Self, T) void`, which get the current value,
and set the next value respectively.

There's also a helper, `Cxxrtl.Sample(T)`, which is used for change detection in
driver loops: you call its `tick(Self)` on every trigger edge, and then can
query its `prev` and `curr` values, and if it's `stable(Self)`. If `T == bool`,
you can also ask whether it's `falling(Self)`, `rising(Self)`,
`stable_low(Self)` or `stable_high(Self)`.

The following example is adapted from an SPI peripheral blackbox. Each byte of
payload from the design is specified as data or command depending on the `dc`
line during the last bit. The module returns events to the caller on each tick.

```zig
const std = @import("std");
const Cxxrtl = @import("zxxrtl");

const SpiConnector = @This();

clk: Cxxrtl.Sample(bool),
res: Cxxrtl.Sample(bool),
dc: Cxxrtl.Sample(bool),
copi: Cxxrtl.Sample(bool),

sr: u8 = 0,
index: u8 = 0,

const Tick = union(enum) {
    Nop,
    Command: u8,
    Data: u8,
};

pub fn init(cxxrtl: Cxxrtl) SpiConnector {
    const clk = Cxxrtl.Sample(bool).init(cxxrtl, "spi_clk", false);
    const res = Cxxrtl.Sample(bool).init(cxxrtl, "spi_res", false);
    const dc = Cxxrtl.Sample(bool).init(cxxrtl, "spi_dc", false);
    const copi = Cxxrtl.Sample(bool).init(cxxrtl, "spi_copi", false);

    return .{
        .clk = clk,
        .res = res,
        .dc = dc,
        .copi = copi,
    };
}

pub fn tick(self: *SpiConnector) Tick {
    const clk = self.clk.tick();
    const res = self.res.tick();
    const dc = self.dc.tick();
    const copi = self.copi.tick();

    var result: Tick = .Nop;

    if (res.curr) {
        self.sr = 0;
        self.index = 0;
    }

    if (clk.rising()) {
        self.sr = (self.sr << 1) | @as(u8, (if (copi.curr) 1 else 0));
        if (self.index < 7)
            self.index += 1
        else if (dc.curr) {
            result = .{ .Command = self.sr };
            self.index = 0;
        } else {
            result = .{ .Data = self.sr };
            self.index = 0;
        }
    }

    return result;
}
```

This is a very simple use case. For a relatively overcomplicated one, see
[sh1107]'s [`I2CConnector`].

[sh1107]: https://github.com/kivikakk/sh1107
[`I2CConnector`]: https://github.com/kivikakk/sh1107/blob/266adfb0bac55f462393e2ee12610cda321de39a/vsh/src/I2CConnector.zig#L125
