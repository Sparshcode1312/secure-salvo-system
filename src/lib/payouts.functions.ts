// Server functions for the payout ledger.
// All state mutations go through Postgres SECURITY DEFINER functions so
// row locking + the unique-index on (sale_id) WHERE type='ADVANCE' & status='success'
// give us real, database-level idempotency and race safety — not
// application-level "if" checks that would be racy under concurrency.
import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";

const uuid = z.string().uuid();

// -------- reads --------

export const listUsers = createServerFn({ method: "GET" }).handler(async () => {
  const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
  const { data, error } = await supabaseAdmin
    .from("users" as never)
    .select("id, name, email, created_at")
    .order("created_at", { ascending: true });
  if (error) throw new Error(error.message);
  return data as Array<{ id: string; name: string; email: string; created_at: string }>;
});

export const getDashboard = createServerFn({ method: "GET" })
  .inputValidator((d: { userId: string }) => ({ userId: uuid.parse(d.userId) }))
  .handler(async ({ data }) => {
    const { supabaseAdmin } = await import("@/integrations/supabase/client.server");

    const [salesRes, payoutsRes, withdrawalsRes] = await Promise.all([
      supabaseAdmin
        .from("sales" as never)
        .select("*")
        .eq("user_id", data.userId)
        .order("created_at", { ascending: false }),
      supabaseAdmin
        .from("payouts" as never)
        .select("*")
        .eq("user_id", data.userId)
        .order("created_at", { ascending: false }),
      supabaseAdmin
        .from("withdrawals" as never)
        .select("*")
        .eq("user_id", data.userId)
        .order("created_at", { ascending: false }),
    ]);
    if (salesRes.error) throw new Error(salesRes.error.message);
    if (payoutsRes.error) throw new Error(payoutsRes.error.message);
    if (withdrawalsRes.error) throw new Error(withdrawalsRes.error.message);

    const sales = salesRes.data as any[];
    const payouts = payoutsRes.data as any[];
    const withdrawals = withdrawalsRes.data as any[];

    const num = (v: unknown) => Number(v ?? 0);

    // Balance = sum of successful ledger amounts (positive credits, negative debits).
    const balance = payouts
      .filter((p) => p.status === "success")
      .reduce((s, p) => s + num(p.amount), 0);

    const totalPendingEarning = sales
      .filter((s) => s.status === "pending")
      .reduce((s, r) => s + num(r.earning), 0);

    const advancePaid = payouts
      .filter((p) => p.type === "ADVANCE" && p.status === "success")
      .reduce((s, p) => s + num(p.amount), 0);

    const finalPayoutEarned = payouts
      .filter((p) => p.type === "FINAL_ADJUSTMENT" && p.status === "success")
      .reduce((s, p) => s + num(p.amount), 0);

    // Cooldown = 24h since last non-failed withdrawal.
    const lastNonFailed = withdrawals.find((w) => w.status !== "failed");
    let cooldownRemainingMs = 0;
    if (lastNonFailed) {
      const elapsed = Date.now() - new Date(lastNonFailed.created_at).getTime();
      cooldownRemainingMs = Math.max(0, 24 * 60 * 60 * 1000 - elapsed);
    }

    return {
      sales,
      payouts,
      withdrawals,
      summary: {
        balance,
        totalPendingEarning,
        advancePaid,
        finalPayoutEarned,
        cooldownRemainingMs,
      },
    };
  });

// -------- writes --------

export const runAdvanceJob = createServerFn({ method: "POST" }).handler(async () => {
  const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
  const { data, error } = await supabaseAdmin.rpc("run_advance_payout_job" as never);
  if (error) throw new Error(error.message);
  const row = (data as any[])?.[0] ?? { processed_count: 0, total_advance: 0 };
  return {
    processed: Number(row.processed_count ?? 0),
    totalAdvance: Number(row.total_advance ?? 0),
  };
});

// Standard result envelope for validation errors so the UI can render backend messages.
type ApiError = { ok: false; status: number; error: string; meta?: Record<string, unknown> };
type ApiOk<T> = { ok: true; data: T };
type ApiResult<T> = ApiOk<T> | ApiError;

function pgError(message: string): ApiError | null {
  // Postgres RAISE messages surface here; parse the well-known ones.
  if (message.includes("cooldown_active:")) {
    const secs = Number(message.split("cooldown_active:")[1]?.split(/\s/)[0] ?? 0);
    return {
      ok: false,
      status: 429,
      error: "24-hour cooldown active",
      meta: { remainingSeconds: secs },
    };
  }
  if (message.includes("insufficient_balance:")) {
    const bal = Number(message.split("insufficient_balance:")[1]?.split(/\s/)[0] ?? 0);
    return {
      ok: false,
      status: 400,
      error: `Insufficient balance. Withdrawable: ₹${bal}`,
      meta: { balance: bal },
    };
  }
  if (message.includes("already_reconciled")) return { ok: false, status: 409, error: "Sale is already reconciled" };
  if (message.includes("already_failed")) return { ok: false, status: 409, error: "Withdrawal already failed" };
  if (message.includes("sale_not_found")) return { ok: false, status: 404, error: "Sale not found" };
  if (message.includes("user_not_found")) return { ok: false, status: 404, error: "User not found" };
  if (message.includes("withdrawal_not_found")) return { ok: false, status: 404, error: "Withdrawal not found" };
  if (message.includes("invalid_status")) return { ok: false, status: 400, error: "Invalid status" };
  if (message.includes("invalid_amount")) return { ok: false, status: 400, error: "Amount must be greater than zero" };
  return null;
}

export const createSale = createServerFn({ method: "POST" })
  .inputValidator((d: { userId: string; brand: string; earning: number }) =>
    z
      .object({
        userId: uuid,
        brand: z.string().trim().min(1).max(60),
        earning: z.number().positive().finite(),
      })
      .parse(d),
  )
  .handler(async ({ data }): Promise<ApiResult<{ id: string }>> => {
    const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
    const { data: row, error } = await supabaseAdmin
      .from("sales" as never)
      .insert({ user_id: data.userId, brand: data.brand, earning: data.earning } as never)
      .select("id")
      .single();
    if (error) return { ok: false, status: 400, error: error.message };
    return { ok: true, data: { id: (row as any).id } };
  });

export const reconcileSale = createServerFn({ method: "POST" })
  .inputValidator((d: { saleId: string; status: "approved" | "rejected" }) =>
    z.object({ saleId: uuid, status: z.enum(["approved", "rejected"]) }).parse(d),
  )
  .handler(async ({ data }): Promise<ApiResult<{ saleId: string; finalAdjustment: number }>> => {
    const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
    const { data: rows, error } = await supabaseAdmin.rpc("reconcile_sale" as never, {
      p_sale_id: data.saleId,
      p_new_status: data.status,
    } as never);
    if (error) {
      const parsed = pgError(error.message);
      return parsed ?? { ok: false, status: 400, error: error.message };
    }
    const row = (rows as any[])?.[0];
    return {
      ok: true,
      data: { saleId: row.sale_id, finalAdjustment: Number(row.final_adjustment) },
    };
  });

export const requestWithdrawal = createServerFn({ method: "POST" })
  .inputValidator((d: { userId: string; amount: number }) =>
    z.object({ userId: uuid, amount: z.number().positive().finite() }).parse(d),
  )
  .handler(async ({ data }): Promise<ApiResult<{ withdrawalId: string }>> => {
    const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
    const { data: rows, error } = await supabaseAdmin.rpc("request_withdrawal" as never, {
      p_user_id: data.userId,
      p_amount: data.amount,
    } as never);
    if (error) {
      const parsed = pgError(error.message);
      return parsed ?? { ok: false, status: 400, error: error.message };
    }
    const row = (rows as any[])?.[0];
    return { ok: true, data: { withdrawalId: row.withdrawal_id } };
  });

export const failWithdrawal = createServerFn({ method: "POST" })
  .inputValidator((d: { withdrawalId: string }) => ({ withdrawalId: uuid.parse(d.withdrawalId) }))
  .handler(async ({ data }): Promise<ApiResult<{ reversalId: string }>> => {
    const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
    const { data: reversalId, error } = await supabaseAdmin.rpc("fail_withdrawal" as never, {
      p_withdrawal_id: data.withdrawalId,
    } as never);
    if (error) {
      const parsed = pgError(error.message);
      return parsed ?? { ok: false, status: 400, error: error.message };
    }
    return { ok: true, data: { reversalId: reversalId as string } };
  });