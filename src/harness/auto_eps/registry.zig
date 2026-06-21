//! Auto-generated registry: @imports all adopted self-evolved files
//! (数字生命 L3 L4 L5 落盘 + adopt 到 ghw 源码, build 时自动 include)
//!
//! 不变量: src/{goal/methods, agent/auto_eps, harness/auto_eps} 下的每个
//! .zig 文件都**必须**在此 registry 被 @import。未被引用的"孤儿"文件不会
//! 参与编译,可能悄悄含有无法编译的内容 (历史上发生过)。新增落盘文件时
//! 务必同步登记;清理时务必删文件而非留孤儿。

const std = @import("std");

/// L3 习得方法 (静态 import 全部落盘文件)
pub const l3_methods = struct {
    pub const method_l3_1024 = @import("../../goal/methods/l3_1024.zig");
    pub const method_l3_1088 = @import("../../goal/methods/l3_1088.zig");
    pub const method_l3_1216 = @import("../../goal/methods/l3_1216.zig");
    pub const method_l3_128 = @import("../../goal/methods/l3_128.zig");
    pub const method_l3_1280 = @import("../../goal/methods/l3_1280.zig");
    pub const method_l3_256 = @import("../../goal/methods/l3_256.zig");
    pub const method_l3_320 = @import("../../goal/methods/l3_320.zig");
    pub const method_l3_448 = @import("../../goal/methods/l3_448.zig");
    pub const method_l3_512 = @import("../../goal/methods/l3_512.zig");
    pub const method_l3_64 = @import("../../goal/methods/l3_64.zig");
    pub const method_l3_640 = @import("../../goal/methods/l3_640.zig");
    pub const method_l3_704 = @import("../../goal/methods/l3_704.zig");
    pub const method_l3_832 = @import("../../goal/methods/l3_832.zig");
    pub const method_l3_896 = @import("../../goal/methods/l3_896.zig");
};

/// L4 算法优化 (AdaptiveEpsilon.compute, 替换静态 epsilon_base)
pub const l4_eps = struct {
    pub const method_l4_1056 = @import("../../agent/auto_eps/l4_1056.zig");
    pub const method_l4_1248 = @import("../../agent/auto_eps/l4_1248.zig");
    pub const method_l4_1297 = @import("../../agent/auto_eps/l4_1297.zig");
    pub const method_l4_209 = @import("../../agent/auto_eps/l4_209.zig");
    pub const method_l4_288 = @import("../../agent/auto_eps/l4_288.zig");
    pub const method_l4_480 = @import("../../agent/auto_eps/l4_480.zig");
    pub const method_l4_672 = @import("../../agent/auto_eps/l4_672.zig");
    pub const method_l4_721 = @import("../../agent/auto_eps/l4_721.zig");
    pub const method_l4_81 = @import("../../agent/auto_eps/l4_81.zig");
    pub const method_l4_849 = @import("../../agent/auto_eps/l4_849.zig");
    pub const method_l4_864 = @import("../../agent/auto_eps/l4_864.zig");
    pub const method_l4_96 = @import("../../agent/auto_eps/l4_96.zig");
};

/// L5 自编码 (SelfTunedWeights 规则集)
pub const l5_rules = struct {
    pub const method_l5_1152 = @import("./l5_1152.zig");
    pub const method_l5_1344 = @import("./l5_1344.zig");
    pub const method_l5_1536 = @import("./l5_1536.zig");
    pub const method_l5_192 = @import("./l5_192.zig");
    pub const method_l5_384 = @import("./l5_384.zig");
    pub const method_l5_576 = @import("./l5_576.zig");
    pub const method_l5_768 = @import("./l5_768.zig");
    pub const method_l5_960 = @import("./l5_960.zig");
};
