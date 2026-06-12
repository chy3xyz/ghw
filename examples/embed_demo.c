/* GHW Embed Demo
 *
 * The smallest possible C program that links libghw and uses GHW as a digital-life kernel.
 * Demonstrates: init → step x5 → get_state → deinit
 *
 * Compile:
 *   zig build
 *   # or manually:
 *   cc -o embed_demo examples/embed_demo.c zig-out/lib/libghw.a
 *
 * Run:
 *   ./embed_demo
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>

/* C ABI declared inline (mirror of ghw.h) */
typedef struct GhW GhW;

extern GhW* ghw_init(const char* agent_id, uint64_t seed);
extern void ghw_deinit(GhW* g);
extern char* ghw_step(GhW* g, const char* world_json);
extern char* ghw_get_state(GhW* g);
extern void ghw_free_string(char* s);
extern uint64_t ghw_get_tick(GhW* g);
extern double ghw_get_E(GhW* g);
extern void ghw_increment_self_evolved(GhW* g);
extern const char* ghw_version(void);

int main(int argc, char** argv) {
    (void)argc;
    (void)argv;

    printf("=== GHW Embed Demo (Phase 3 SDK) ===\n");
    printf("version: %s\n\n", ghw_version());

    /* 1. 初始化 */
    GhW* g = ghw_init("embed-demo", 42);
    if (!g) {
        fprintf(stderr, "ghw_init failed\n");
        return 1;
    }
    printf("✓ ghw_init: agent_id=embed-demo, seed=42\n");
    printf("  initial tick=%llu, E=%.3f\n\n",
        (unsigned long long)ghw_get_tick(g),
        ghw_get_E(g));

    /* 2. 跑 5 cycle */
    printf("Running 5 cycles...\n");
    for (int i = 0; i < 5; i++) {
        char* report = ghw_step(g, "{}");
        if (report) {
            printf("  cycle %d: %s\n", i + 1, report);
            /* 模拟外部产品做 1 个 "action" — self_evolved_total++ */
            ghw_increment_self_evolved(g);
            ghw_free_string(report);
        } else {
            fprintf(stderr, "  cycle %d: ghw_step failed\n", i + 1);
        }
    }
    printf("\n");

    /* 3. 查询最终状态 */
    char* state = ghw_get_state(g);
    if (state) {
        printf("Final state: %s\n\n", state);
        ghw_free_string(state);
    }

    /* 4. 清理 */
    ghw_deinit(g);
    printf("✓ ghw_deinit done\n");
    printf("\n=== Demo complete: GHW can be a kernel ===\n");
    return 0;
}
