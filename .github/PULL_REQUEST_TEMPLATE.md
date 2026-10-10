<!--
Thanks for contributing! One logical change per PR — see CONTRIBUTING.md.
-->
## Summary

<!-- What does this PR change and why? Link the issue (fixes #123). -->

## Type of change

- [ ] Bug fix
- [ ] New feature / capability
- [ ] Docs only
- [ ] Refactor (no behavior change)

## Checklist

- [ ] `zig build test` — all green (exit 0)
- [ ] End-to-end smoke test run (one of: `zig build run-daemon -- --cycles 100`,
      `zig build run-cross_host_test`, `zig build run-multi_agent_demo`)
- [ ] New modules exported in the relevant `mod.zig` **and** referenced in the
      `src/ghw.zig` comptime block, otherwise their tests silently don't run
      (see AGENTS.md "测试接线约定" / test-wiring convention)
- [ ] Docs updated (`readme.md` + `readme.zh-CN.md` for CLI flags; `SDK.md`
      for public API changes)
- [ ] No new external dependencies (zero-dep policy)
- [ ] E formula / SelfEvolutionGuard 17-blacklist untouched (invariant)

## Notes for reviewers

<!-- Alternatives considered, before/after KPIs if perf-related, etc. -->
