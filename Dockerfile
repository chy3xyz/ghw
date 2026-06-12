# GHW Docker image — multi-stage build for Zig 0.17 dev + distroless runtime
#
# 阶段 1: build (zig 0.17 dev) — 装 zig, build ghw binaries
# 阶段 2: runtime (distroless) — 只放 binary + sqlite3 lib
#
# 用法:
#   docker build -t ghw:latest .
#   docker run -d --name ghw -p 8765:8765 \
#     -v ghw_data:/data \
#     -e DEEPSEEK_API_KEY=sk-xxx \
#     ghw:latest
#   # 访问 http://localhost:8765

# === Stage 1: build ===
FROM ziglang/static-base:0.17.0-dev.704 AS build

# 系统依赖 (zig 0.17 dev 需要的 C 库)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# 先 copy build.zig + src, 利用 cache (改 examples 不重 build 源码)
COPY build.zig build.zig.zon ./
COPY src/ ./src/
COPY examples/ ./examples/

# build release 版 (ReleaseSafe 防错, 也省 size 一些)
RUN zig build -Doptimize=ReleaseSafe \
    -Dbuild-examples=ui_server,daemon

# === Stage 2: runtime ===
FROM gcr.io/distroless/cc-debian12:nonroot AS runtime

# 工作目录
WORKDIR /app

# 拷 binary (ui_server + daemon + .env template)
COPY --from=build /src/zig-out/bin/ui_server /app/ui_server
COPY --from=build /src/zig-out/bin/daemon /app/daemon
COPY --from=build /src/ui/ /app/ui/

# 暴露端口
EXPOSE 8765

# 持久化数据目录 (用户 mount volume)
VOLUME ["/data"]

# 健康检查 (每 30s curl /api/state, 失败 exit 1)
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD ["/app/ui_server", "--port", "8766", "--state", "/data/health.json", "--ui-dir", "/app/ui", "--cycles", "1", "--llm", "none"]

# 默认启动 ui_server (跟本地 launchd 行为一致)
# 用户需 -e DEEPSEEK_API_KEY=$KEY 或挂 keychain helper
# 数据存 /data/ (volume mount)
ENTRYPOINT ["/app/ui_server"]
CMD ["--port", "8765", "--state", "/data/ui_state.json", "--ui-dir", "/app/ui", "--llm", "deepseek", "--llm-model", "deepseek-chat", "--llm-key-env", "DEEPSEEK_API_KEY"]
