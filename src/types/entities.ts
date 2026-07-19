// types/entities.ts
// Class Design (equivalent) — entity definitions for the Payout Ledger system.
// Since the backend logic lives in Postgres functions rather than an OOP class
// hierarchy, these TypeScript interfaces serve as the "class design" deliverable:
// the precise shape of every entity, and the function signatures that operate on them.

export type SaleStatus = "pending" | "approved" | "rejected";
export type PayoutType = "ADVANCE" | "FINAL_ADJUSTMENT" | "WITHDRAWAL" | "REVERSAL";
export type PayoutStatus = "success" | "failed" | "cancelled" | "rejected";
export type WithdrawalStatus = "pending" | "success" | "failed";

export interface User {
  id: string;
  name: string;
  email: string;
  createdAt: string;
}

export interface Sale {
  id: string;
  userId: string;
  brand: string;
  earning: number;          // must be > 0, enforced at DB + API layer
  status: SaleStatus;
  createdAt: string;
  reconciledAt: string | null;
}

// The core entity — an immutable, append-only ledger row.
// Instances are never mutated after creation; corrections are modeled
// as new rows (e.g. a REVERSAL referencing the original via refPayoutId).
export interface Payout {
  id: string;
  userId: string;
  saleId: string | null;     // null for withdrawals (not tied to a specific sale)
  type: PayoutType;
  amount: number;             // signed: negative for clawbacks
  status: PayoutStatus;
  refPayoutId: string | null; // links a REVERSAL to the payout it reverses
  createdAt: string;
}

export interface Withdrawal {
  id: string;
  userId: string;
  amount: number;
  status: WithdrawalStatus;
  createdAt: string;
}

// ---- Service-layer method signatures ----
// These represent the "behavior" side of the class design: the operations
// that act on the entities above, each implemented as a single DB transaction.

export interface PayoutService {
  /**
   * Pays 10% advance on every pending sale without an existing successful
   * ADVANCE payout. Idempotent: running this twice in a row processes
   * zero sales on the second call.
   */
  runAdvancePayoutJob(): Promise<{ processedCount: number }>;

  /**
   * Reconciles a sale to approved/rejected and computes the final
   * adjustment: (status === 'approved' ? earning : 0) - advancePaid.
   * Rejects with a 409 if the sale is not currently 'pending'.
   */
  reconcileSale(saleId: string, status: "approved" | "rejected"): Promise<Payout>;

  /**
   * Creates a withdrawal if the requested amount does not exceed the
   * computed withdrawable balance, and the user's last non-failed
   * withdrawal was more than 24 hours ago. Throws a typed error
   * (InsufficientBalanceError | CooldownActiveError) otherwise.
   */
  requestWithdrawal(userId: string, amount: number): Promise<Withdrawal>;

  /**
   * Marks a withdrawal failed/cancelled and inserts a REVERSAL payout
   * crediting the amount back to the user's withdrawable balance.
   */
  reverseFailedWithdrawal(withdrawalId: string): Promise<Payout>;

  /**
   * Computes the current withdrawable balance live, as the sum of all
   * 'success' status payouts for the user — never read from a stored
   * balance field.
   */
  getBalance(userId: string): Promise<number>;
}

// ---- Typed error classes used by the service layer ----

export class InsufficientBalanceError extends Error {
  constructor(public readonly requested: number, public readonly available: number) {
    super(`Requested ₹${requested} exceeds withdrawable balance of ₹${available}`);
  }
}

export class CooldownActiveError extends Error {
  constructor(public readonly retryAfterMs: number) {
    super(`Withdrawal cooldown active. Try again in ${Math.ceil(retryAfterMs / 3_600_000)}h`);
  }
}

export class AlreadyReconciledError extends Error {
  constructor(public readonly saleId: string) {
    super(`Sale ${saleId} has already been reconciled`);
  }
}
