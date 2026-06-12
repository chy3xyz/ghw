//! harness_api — 薄 wrapper, 让 L3/L4/L5 落盘文件可独立编译时 @import("harness_api")
//! 提供 type-only 公共表面 (ActionOutcome / MethodKind / F), 不带任何重依赖
//! (避免 import "harness" 时被拽入 util/sqlite/link 等重模块的 0.17 跨模块相对路径问题)

/// F = f32 单精度, 与 harness/core.zig 同步
pub const F: type = f32;

/// 行动结果 (与 harness/core.zig::ActionOutcome 字段一致)
/// L3/L4/L5 模板用这个 type 而不是自包含 stub, 保证落盘代码与全栈类型兼容
pub const ActionOutcome = struct {
    success: bool,
    de_delta: F,
    representation_gain: F,
    material_cost: F,
    log: []const u8,
};

/// 方法类型 (与 harness/mod.zig::MethodKind 同步)
pub const MethodKind = enum {
    wasm_skill,
    peer_query,
    claude_code,
    self_evolve_l1,
    self_evolve_l2,
    self_evolve_l3,
    self_evolve_l4,
    self_evolve_l5,
    custom,
};

/// 行动类型 (与 harness/mod.zig::ActionKind 同步)
pub const ActionKind = enum {
    wasm,
    peer,
    claude,
    self_evolve,
    observe,
};
