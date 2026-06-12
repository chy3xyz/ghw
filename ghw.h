/* ghw.h — C ABI for embedding GHW as a digital-life kernel (v0.3)
 *
 * Usage:
 *   #include "ghw.h"
 *   GhW* g = ghw_init("my-agent", 42);
 *   ghw_setup_llm(g, "deepseek", "DEEPSEEK_API_KEY", "deepseek-chat");
 *   ghw_open_memory(g, "/tmp/ghw.db");
 *   ghw_world_set(g, "top_procs: claude 12%, node 8% ...");
 *   int n = ghw_propose(g);  // LLM proposes goals
 *   char* result = ghw_action_run(g);  // run 1 action
 *   ghw_reflect(g);  // LLM writes self_narrative + beliefs
 *   ghw_free_string(result);
 *   ghw_deinit(g);
 *
 * Linking (after `zig build install-sdk`):
 *   cc my_app.c -I. -L./zig-out/lib -lghw -o my_app
 */
#ifndef GHW_H
#define GHW_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handle */
typedef struct GhW GhW;

/* Version */
const char* ghw_version(void);

/* ============ Lifecycle ============ */
GhW* ghw_init(const char* agent_id, uint64_t seed);
void ghw_deinit(GhW* g);

/* ============ Core (v0.1) ============ */
/* Run 1 cycle (no-op if LLM not set up).
 * Returns: cycle report JSON (caller frees with ghw_free_string), or NULL on error. */
char* ghw_step(GhW* g, const char* world_json);

/* Get cached state JSON. */
char* ghw_get_state(GhW* g);

/* Free any string returned by ghw_*. Safe to call with NULL. */
void ghw_free_string(char* s);

/* Cheap accessors */
uint64_t ghw_get_tick(GhW* g);
double ghw_get_E(GhW* g);

/* External action hook */
void ghw_increment_self_evolved(GhW* g);

/* ============ LLM / Memory / Action (v0.2) ============ */
/* Setup LLM. provider: "deepseek" | "openai" | "anthropic" | "none".
 * api_key_env: name of env var holding the API key.
 * Returns 0 on ok, -1 on error. */
int ghw_setup_llm(GhW* g, const char* provider, const char* api_key_env, const char* model);

/* Open sqlite memory + ActionRunner. path: sqlite file path, "" for in-memory.
 * Returns 0 on ok, -1 on error. */
int ghw_open_memory(GhW* g, const char* path);

/* Run 1 action (top unadopted goal). Returns JSON (caller frees), or NULL if no goal. */
char* ghw_action_run(GhW* g);

/* ============ Link server (v0.2) ============ */
int ghw_link_listen(GhW* g, const char* path);
char* ghw_link_query(GhW* g, const char* peer_path, const char* method);
void ghw_link_stop(GhW* g);

/* ============ World / Propose / Reflect (v0.3) ============ */
/* Set world context (free-form multi-line text, C client formats its own world).
 * Used by ghw_propose / ghw_reflect. */
void ghw_world_set(GhW* g, const char* world_text);

/* LLM propose new goals. Writes to sqlite (if open) + in-memory proposed_goals.
 * Returns: # goals proposed (>0), 0 = none, -1 = error. */
int ghw_propose(GhW* g);

/* LLM reflect: writes self_narrative based on recent state.
 * Returns: 0 on ok, -1 on error. */
int ghw_reflect(GhW* g);

#ifdef __cplusplus
}
#endif

#endif /* GHW_H */
