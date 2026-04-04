# Circuit Breaker (Rate Limit Protection)

File-based circuit breaker to avoid wasting iterations during API rate limiting or quota exhaustion. See issue #118.

## State File

Location: `logs/loop-circuit-breaker.json`

```json
{
  "consecutiveFailures": 0,
  "circuitState": "closed",
  "cooldownUntil": null,
  "lastSuccessTimestamp": null
}
```

## State Machine

```
closed ──(failure ≥ 2)──► open ──(cooldown expired)──► half-open
  ▲                                                        │
  └──────────────────(success)─────────────────────────────┘
```

### States

| State | Meaning | Action |
|-------|---------|--------|
| `closed` | Normal operation | Run pipeline as usual |
| `open` | Rate-limited, in cooldown | Skip iteration → NEXT ITERATION |
| `half-open` | Cooldown expired, probing | Run pipeline; success → closed, failure → open with longer cooldown |

### Transitions

**Any step encounters rate-limit or quota error:**
1. Increment `consecutiveFailures`
2. If `consecutiveFailures` ≥ 2:
   - Set `circuitState` to `"open"`
   - Set `cooldownUntil` = now + min(30min × 2^(failures−1), 4 hours)
3. NEXT ITERATION

**Successful iteration (reaching Verification checklist):**
1. Set `circuitState` to `"closed"`
2. Set `consecutiveFailures` to `0`
3. Update `lastSuccessTimestamp`

### Backoff Schedule

| Consecutive Failures | Cooldown Duration |
|---------------------|-------------------|
| 1 | No cooldown (normal interval) |
| 2 | 30 minutes |
| 3 | 60 minutes |
| 4 | 120 minutes |
| 5+ | 240 minutes (cap) |

## External Writer: Stop Hook

The Stop hook (`.claude/hooks/rate-limit-detector.sh`) also writes to this state file. It detects rate-limit signals in the session transcript after Claude responds, covering cases where Claude can respond but the response itself indicates rate limiting.

**Important**: The Stop hook always exits 0 (never blocks) to avoid the infinite loop documented in `docs/lessons-learned.md` § "Codex Stop Hook Infinite Loop".

## Limitations

- When API quota is fully exhausted, Claude cannot respond at all. Neither the skill-level circuit breaker nor the Stop hook can fire. The loop will continue to empty-fire at the configured interval. This is a `/loop` infrastructure limitation.
- The circuit breaker cannot distinguish between API rate limits and `gh` CLI rate limits. Both trigger the same cooldown.
