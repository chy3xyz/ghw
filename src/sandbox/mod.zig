//! Sandbox v1: WASM 沙箱 (wasmtime) + SQLite 记忆库
//!
//! 提供:
//!   - WasmSandbox: 加载 + 跑 wasm32-freestanding 模块
//!   - WasmResult: 跑结果 (返回值 + log)
//!   - SqliteDb: SQLite 持久化
//!
//! 详细见各模块.

pub const wasm_runtime = @import("wasm_runtime.zig");
pub const WasmSandbox = wasm_runtime.WasmSandbox;
pub const WasmResult = wasm_runtime.WasmResult;
pub const WasmError = wasm_runtime.WasmError;

pub const sqlite_db = @import("sqlite_db.zig");
pub const SqliteDb = sqlite_db.SqliteDb;
pub const SqliteError = sqlite_db.SqliteError;

pub const action_runner = @import("action_runner.zig");
pub const ActionRunner = action_runner.ActionRunner;
