/* GHW Embed Demo v0.3
 *
 * Full SDK pipeline: LLM setup → world input → propose → action → reflect.
 * This is the minimum "GHW as a kernel" use case.
 *
 * Compile:
 *   cc -O2 -I zig-out/include -L zig-out/lib examples/embed_demo_v3.c -lghw -o embed_demo_v3
 *
 * Run:
 *   DEEPSEEK_API_KEY=sk-xxx ./embed_demo_v3
 *   # or with no LLM (mock mode):
 *   ./embed_demo_v3
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>

/* Inline ABI declarations (mirror of ghw.h) */
typedef struct GhW GhW;
extern const char* ghw_version(void);
extern GhW* ghw_init(const char* agent_id, uint64_t seed);
extern void ghw_deinit(GhW* g);
extern char* ghw_step(GhW* g, const char* world_json);
extern char* ghw_get_state(GhW* g);
extern void ghw_free_string(char* s);
extern uint64_t ghw_get_tick(GhW* g);
extern double ghw_get_E(GhW* g);
extern void ghw_increment_self_evolved(GhW* g);

extern int ghw_setup_llm(GhW* g, const char* provider, const char* api_key_env, const char* model);
extern int ghw_open_memory(GhW* g, const char* path);
extern char* ghw_action_run(GhW* g);
extern int ghw_link_listen(GhW* g, const char* path);
extern char* ghw_link_query(GhW* g, const char* peer_path, const char* method);
extern void ghw_link_stop(GhW* g);

extern void ghw_world_set(GhW* g, const char* world_text);
extern int ghw_propose(GhW* g);
extern int ghw_reflect(GhW* g);

int main(int argc, char** argv) {
    (void)argc;
    (void)argv;

    printf("=== GHW Embed Demo v0.3 (full SDK pipeline) ===\n");
    printf("version: %s\n\n", ghw_version());

    /* 1. 初始化 */
    GhW* g = ghw_init("embed-demo-v3", 42);
    if (!g) {
        fprintf(stderr, "ghw_init failed\n");
        return 1;
    }
    printf("[1] ghw_init: agent_id=embed-demo-v3\n");

    /* 2. 设置 LLM (从 env 拿 key) */
    const char* api_key = getenv("DEEPSEEK_API_KEY");
    if (api_key && api_key[0] != '\0') {
        int rc = ghw_setup_llm(g, "deepseek", "DEEPSEEK_API_KEY", "deepseek-chat");
        printf("[2] ghw_setup_llm(deepseek): rc=%d\n", rc);
    } else {
        printf("[2] ghw_setup_llm: SKIPPED (no DEEPSEEK_API_KEY, using no-LLM mode)\n");
    }

    /* 3. 打开 sqlite + ActionRunner */
    int rc_mem = ghw_open_memory(g, "/tmp/ghw_embed_v3.db");
    printf("[3] ghw_open_memory: rc=%d\n", rc_mem);

    /* 4. 设置世界描述 (C 客户端自己格式化) */
    const char* world =
        "=== Top processes (by CPU) ===\n"
        "PID 12345  CPU 12.5%  CMD: claude\n"
        "PID 67890  CPU  8.3%  CMD: node\n"
        "PID 11111  CPU  2.1%  CMD: zig\n"
        "\n"
        "=== Network peers ===\n"
        "(no peers — empty for demo)\n"
        "\n"
        "=== Recent activity ===\n"
        "/Users/me/projects/ghw-sdk\n";
    ghw_world_set(g, world);
    printf("[4] ghw_world_set: ok\n");

    /* 5. 跑 5 cycle (让 GHW 真演化) */
    printf("\n[5] Running 5 cycles...\n");
    for (int i = 0; i < 5; i++) {
        char* report = ghw_step(g, "{}");
        if (report) {
            printf("  cycle %d: %s\n", i + 1, report);
            ghw_increment_self_evolved(g);
            ghw_free_string(report);
        }
    }

    /* 6. 调 LLM 提议 (如果有 LLM) */
    if (api_key && api_key[0] != '\0') {
        printf("\n[6] ghw_propose (LLM)...\n");
        int n = ghw_propose(g);
        printf("  proposed %d goals\n", n);

        /* 7. 跑 1 个 action */
        if (n > 0) {
            printf("\n[7] ghw_action_run...\n");
            char* ar = ghw_action_run(g);
            if (ar) {
                printf("  %s\n", ar);
                ghw_free_string(ar);
            }
        }

        /* 8. 反思 */
        printf("\n[8] ghw_reflect (LLM)...\n");
        int rrc = ghw_reflect(g);
        printf("  rc=%d\n", rrc);
    } else {
        printf("\n[6-8] LLM 步骤 SKIPPED (没设 API key)\n");
    }

    /* 9. 最终 state */
    printf("\n[9] Final state:\n");
    char* state = ghw_get_state(g);
    if (state) {
        printf("  %s\n", state);
        ghw_free_string(state);
    }

    ghw_deinit(g);
    printf("\n=== Demo complete ===\n");
    return 0;
}
