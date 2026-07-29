/**
 * AsrSessionGuard — per-user Durable Object that caps CONCURRENT ASR WebSocket
 * sessions.
 *
 * WHY THIS EXISTS
 * The quota gate in asr-proxy.ts only reads ALREADY-SETTLED usage before accepting a
 * connection, and consumption is settled asynchronously (fire-and-forget) DURING the
 * session. With no reservation and no per-user lock, a user sitting at their weekly
 * limit could open many WebSockets in the same instant: all of them read the same
 * pre-consumption value, all pass the gate, all proceed. That multiplies real upstream
 * ASR spend (Alibaba / Volcengine / Soniox bill per second) with zero extra quota.
 *
 * A Durable Object is single-threaded per id, so keying it by userId serializes every
 * acquire/release for that user — N parallel connects now see each other's slots and
 * only MAX_CONCURRENT get through.
 *
 * SCOPE — deliberately minimal.
 * This ONLY bounds concurrency. It does NOT reserve credit, so a single sequential
 * session can still run slightly past the limit before the next connect is blocked.
 * The full reserve→settle ledger that would close that too is specified (but not built)
 * in docs/CREDIT-BILLING-AUDIT.md → HIGH-1 option B. Even with this guard public, an
 * attacker who knows the design gains nothing exploitable: the parallel multiplier —
 * the only cheap, high-leverage abuse — is gone, and everything else is bounded by the
 * per-second upstream cost of a small fixed number of live sessions.
 *
 * Invoked via fetch-RPC ({ method, sessionId }) rather than native RPC so it works
 * regardless of the worker's (currently old) compatibility_date.
 */

/** Max simultaneous live ASR sessions per user. */
const MAX_CONCURRENT = 3;
/** Slots older than this are assumed abandoned (session died without release) and pruned. */
const SESSION_TTL_MS = 60 * 60 * 1000; // 1 hour

interface Slot {
  startedAt: number;
}

export class AsrSessionGuard {
  private state: DurableObjectState;
  private slots = new Map<string, Slot>();
  private loaded = false;

  constructor(state: DurableObjectState, _env: unknown) {
    this.state = state;
  }

  private async ensureLoaded(): Promise<void> {
    if (this.loaded) return;
    const stored = await this.state.storage.get<Record<string, Slot>>('slots');
    if (stored) this.slots = new Map(Object.entries(stored));
    this.loaded = true;
  }

  /** Drop abandoned slots so a died-mid-session hold can't lock a user out forever. */
  private prune(now: number): boolean {
    let changed = false;
    for (const [id, slot] of this.slots) {
      if (now - slot.startedAt > SESSION_TTL_MS) {
        this.slots.delete(id);
        changed = true;
      }
    }
    return changed;
  }

  private async persist(): Promise<void> {
    await this.state.storage.put('slots', Object.fromEntries(this.slots));
  }

  async fetch(request: Request): Promise<Response> {
    let body: { method?: string; sessionId?: string };
    try {
      body = (await request.json()) as { method?: string; sessionId?: string };
    } catch {
      return Response.json({ error: 'invalid body' }, { status: 400 });
    }

    const { method, sessionId } = body;
    if (!method || !sessionId) {
      return Response.json({ error: 'missing method or sessionId' }, { status: 400 });
    }

    await this.ensureLoaded();
    const now = Date.now();

    if (method === 'acquire') {
      this.prune(now);
      // Idempotent: re-acquiring the same session (retry) never double-counts.
      if (this.slots.has(sessionId)) {
        return Response.json({ ok: true, active: this.slots.size });
      }
      if (this.slots.size >= MAX_CONCURRENT) {
        return Response.json(
          { ok: false, active: this.slots.size, limit: MAX_CONCURRENT },
          { status: 429 },
        );
      }
      this.slots.set(sessionId, { startedAt: now });
      await this.persist();
      return Response.json({ ok: true, active: this.slots.size });
    }

    if (method === 'release') {
      const had = this.slots.delete(sessionId);
      const pruned = this.prune(now);
      if (had || pruned) await this.persist();
      return Response.json({ ok: true, active: this.slots.size });
    }

    return Response.json({ error: `unknown method: ${method}` }, { status: 400 });
  }
}
