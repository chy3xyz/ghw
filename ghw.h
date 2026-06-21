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

/* Last error description (static string; do NOT free). "" when no error.
 * Lets callers distinguish causes behind a -1/NULL return. */
const char* ghw_last_error(GhW* g);

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

/* ============ KPI bridge (ρ·K term into Existence Degree) ============ */
/* Configure the KPI bridge. MUST be called once before ghw_kpi_feed.
 *   refresh_interval_hours: min hours between two writes into E (anti-flicker;
 *                           0 defaults to 24). Product may feed faster; the
 *                           bridge rate-limits actual writes.
 *   north_star_is_revenue:  != 0 gives the revenue axis a 1.5x weight.
 *   w_user_sat/w_retention/w_revenue/w_safety: composite value weights.
 * Returns 0 on ok, -1 on error. */
int ghw_kpi_configure(GhW* g, uint32_t refresh_interval_hours,
                      int32_t north_star_is_revenue,
                      float w_user_sat, float w_retention,
                      float w_revenue, float w_safety);

/* Feed the latest raw CRM KPIs (may be called at high frequency).
 *   csat:          real customer-satisfaction score in [0,1]; pass NAN for "no source"
 *                  (falls back to the active-sales proxy).
 *   incident_rate: normalized incident severity in [0,1] (0 = none); pass NAN for
 *                  "no source" (the safety axis then contributes 0).
 *   now_unix:      caller-supplied current unix seconds (Zig 0.17 has no builtin clock).
 * Returns 1 if E was updated this call, 0 if rate-limited, -1 if not configured. */
int ghw_kpi_feed(GhW* g, float nrr_quarterly, float deal_win_rate,
                 float sales_cycle_days_p50, float weekly_active_sales_pct,
                 float csat, float incident_rate,
                 int64_t now_unix);

/* Current composite KPI K in [0,1] (diagnostic, does not write E).
 * Returns -1 if not configured or no valid feed yet. */
double ghw_kpi_composite(GhW* g);

/* ============ Product evolution runtime ============ */
/* Load ProductIntent JSON and initialize the product evolution runtime.
 * Returns 0 on ok, -1 on error. */
int ghw_product_intent_load(GhW* g, const char* path);

/* Feed CRM KPI through ProductEvolutionRuntime. This writes into E via KpiBridge
 * and appends a kpi_refreshed audit entry when the rate limiter allows it.
 * Returns 1 if E was updated, 0 if rate-limited, -1 on error. */
int ghw_product_kpi_feed(GhW* g, float nrr_quarterly, float deal_win_rate,
                         float sales_cycle_days_p50, float weekly_active_sales_pct,
                         float csat, float incident_rate,
                         int64_t now_unix);

/* Submit the canonical CRM proposal: follow-up cadence 7d -> 5d.
 * Returns change_id (>0) or -1 on error. */
int64_t ghw_product_propose_crm_followup(GhW* g, const char* tenant_id,
                                         uint32_t affected_users,
                                         float expected_delta_k,
                                         uint64_t now_unix);

/* Consent/apply/rollback gates for product changes. Return 0 on ok, -1 on error. */
int ghw_product_approve_change(GhW* g, uint64_t change_id,
                               const char* approver, const char* note,
                               uint64_t now_unix);
int ghw_product_apply_change(GhW* g, uint64_t change_id, uint64_t now_unix);
int ghw_product_rollback_change(GhW* g, uint64_t change_id, uint64_t now_unix);

/* Product evolution audit log JSON. Caller frees with ghw_free_string. */
char* ghw_product_audit_json(GhW* g);

#ifdef __cplusplus
}
#endif

#endif /* GHW_H */
