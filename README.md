Payout Ledger — User Payout Management System
A low-level design (LLD) implementation of a payout management system for affiliate sales-handling advance payouts, reconciliation-based final payouts, withdrawal restrictions, and failed-payout recovery.
Live demo: https://secure-salvo-system.lovable.app/
Assignment: SDE Intern Assignment-System Design (Low-Level Design)
---
1. Problem Overview
Every affiliate sale enters the system as `pending`. Users receive an advance payout of 10% of a sale's earnings immediately, before the sale is verified. Later, an admin reconciles each sale to either `approved` or `rejected`, at which point the system calculates the final payout, accounting for the advance already paid out.
The two properties that make this a real system-design problem rather than simple CRUD:
Idempotency — an advance payout must never be paid twice for the same sale, even if the payout job is triggered repeatedly.
Auditability — every rupee that moves must be traceable to a specific transaction, not just reflected in a mutable balance number.
---
2. Business Rules
Advance Payout
Every `pending` sale is eligible for an advance payout of `10% × earning`.
Once a sale has a successful advance payout, it is permanently ineligible for another — enforced at both the application and database level (see §5).
Final Payout (on reconciliation)
When an admin reconciles a sale:
Outcome	Formula
Approved	`earning − advance_paid`
Rejected	`0 − advance_paid` (i.e. the advance is clawed back)
Both cases collapse into one formula, used directly in code:
```
final_adjustment = (status === 'approved' ? earning : 0) − advance_paid
```
A sale can only be reconciled once. Re-reconciling an already-reconciled sale is rejected.
Withdrawals
A user may withdraw once every 24 hours, enforced server-side against the timestamp of their last non-failed withdrawal.
Withdrawal amount cannot exceed the current withdrawable balance.
Failed Payout Recovery
If a withdrawal is later cancelled, rejected, or fails (e.g. a gateway failure), the amount is credited back to the user's withdrawable balance via a reversal ledger entry, and the user can immediately re-attempt the withdrawal.
---
3. Architecture
```
Frontend (React + Vite + Tailwind)
        │
        ▼
Backend (Supabase Edge Functions / Postgres functions)
        │
        ▼
Database (Postgres via Supabase)
```
Frontend: displays sales, ledger history, and summary balances; triggers admin actions (reconcile, run advance job) and user actions (withdraw).
Backend: business logic lives in database functions wrapped in transactions, callable via Supabase's API layer. This keeps the financial logic close to the data it protects, rather than trusting the frontend or a stateless API layer to enforce correctness.
Database: Postgres, chosen specifically for this project over a NoSQL store because the core requirement — atomic, constraint-enforced financial transactions — is exactly what relational databases with ACID guarantees are built for.
---
4. Database Schema
   ```mermaid
erDiagram
  USERS ||--o{ SALES : has
  USERS ||--o{ PAYOUTS : has
  USERS ||--o{ WITHDRAWALS : has
  SALES ||--o{ PAYOUTS : generates
  WITHDRAWALS ||--o| PAYOUTS : creates
  PAYOUTS ||--o| PAYOUTS : reverses

  USERS {
    uuid id PK
    string name
    string email
    timestamp created_at
  }
  SALES {
    uuid id PK
    uuid user_id FK
    string brand
    numeric earning
    enum status
    timestamp reconciled_at
  }
  PAYOUTS {
    uuid id PK
    uuid user_id FK
    uuid sale_id FK
    enum type
    numeric amount
    enum status
    uuid ref_payout_id FK
  }
  WITHDRAWALS {
    uuid id PK
    uuid user_id FK
    numeric amount
    enum status
  }
```
`users`
Column	Type	Notes
id	uuid, PK	
name	text	
email	text	
created_at	timestamptz	
`sales`
Column	Type	Notes
id	uuid, PK	
user_id	uuid, FK → users	
brand	text	
earning	numeric	constraint: > 0
status	enum(pending, approved, rejected)	default `pending`
created_at	timestamptz	
reconciled_at	timestamptz, nullable	
`payouts` (append-only ledger — the core of the system)
Column	Type	Notes
id	uuid, PK	
user_id	uuid, FK → users	
sale_id	uuid, FK → sales, nullable	null for withdrawals
type	enum(ADVANCE, FINAL_ADJUSTMENT, WITHDRAWAL, REVERSAL)	
amount	numeric	can be negative
status	enum(success, failed, cancelled, rejected)	
ref_payout_id	uuid, FK → payouts, nullable	links a reversal to the original payout
created_at	timestamptz	
Constraint: unique index on `(sale_id, type)` WHERE `type = 'ADVANCE' AND status = 'success'` — this is what physically prevents a duplicate advance payout at the database level, independent of application logic (see §5).
`withdrawals`
Column	Type	Notes
id	uuid, PK	
user_id	uuid, FK → users	
amount	numeric	
status	enum(pending, success, failed)	
created_at	timestamptz	
Indexes: `sales.status`, `payouts.user_id`, `withdrawals(user_id, created_at)` — the last one specifically supports the 24-hour withdrawal-cooldown lookup.
---
5. Why an Append-Only Ledger Instead of a Balance Field
The naive approach to a "balance" is a single mutable column: `UPDATE users SET balance = balance + 12`. This is fragile in a system with concurrent requests — two simultaneous updates can race and silently overwrite each other, and there's no way to reconstruct why a balance is what it is after the fact.
Instead, `payouts` is treated as an immutable, append-only transaction log. Nothing is ever updated — only inserted. A user's withdrawable balance is always computed, not stored:
```sql
SELECT COALESCE(SUM(amount), 0)
FROM payouts
WHERE user_id = :user_id AND status = 'success';
```
This means the balance is always provably correct and reconstructable from history-the same principle used in real banking and payments ledgers. It also makes failure recovery (§2, Failed Payout Recovery) trivial: a reversal is just another ledger row, not a special-cased mutation.
---
6. Idempotency
The advance payout job and reconciliation are both designed to be safe to run more than once:
Advance payout job: selects pending sales with no existing successful `ADVANCE` row, and inserts the payout inside a transaction. Even if the job is triggered twice back-to-back, the unique constraint on `payouts(sale_id, type='ADVANCE')` guarantees the second attempt cannot insert a duplicate — this is enforced by the database itself, not just an `if` check in application code, so it also holds under concurrent/racing requests.
Reconciliation: checks the sale's current status is `pending` before proceeding; a sale already reconciled is rejected with a clear error rather than silently reprocessed.
---
7. API Endpoints
Endpoint	Method	Description
`/api/payouts/advance-job`	POST	Processes all eligible pending sales, pays 10% advance. Idempotent.
`/api/sales/:id/reconcile`	POST	Body: `{ status: 'approved' | 'rejected' }`. Computes final adjustment, updates sale.
`/api/withdrawals`	POST	Body: `{ amount }`. Enforces balance and 24h cooldown checks.
`/api/withdrawals/:id/fail`	POST	Marks a withdrawal failed/cancelled, inserts a reversal entry.
`/api/users/:id/balance`	GET	Returns withdrawable balance, computed live from the ledger.
`/api/users/:id/ledger`	GET	Full transaction history for a user.
`/api/sales?userId=`	GET	All sales for a user.
All write endpoints return proper status codes: `400` for validation errors, `409` for conflicts (e.g. double reconciliation), `200`/`201` for success — with a JSON error body describing the failure.
---
8. Edge Cases Handled
Advance payout job run twice in a row → second run makes zero changes.
Reconciling an already-reconciled sale → rejected (`409`), not silently overwritten.
Reconciling a sale that never received an advance payout → correctly computes full earning (approved) or ₹0 (rejected), no negative-balance bug.
Withdrawal requested for more than the current balance → rejected.
Withdrawal requested within 24 hours of the last → rejected, with time remaining.
Withdrawal that later fails/is cancelled → balance restored via reversal; user can re-attempt.
Concurrent reconcile/advance-job requests on the same sale → prevented at the database constraint/transaction level, not just application logic.
Zero or negative earning on sale creation → rejected at the API layer.
---
9. Worked Example (matches assignment spec)
Before reconciliation: 3 sales, `brand_1`, ₹40 each, all `pending`.
Total pending earnings: ₹120
Advance payout (10%): ₹12
After reconciliation: sale 1 → rejected, sale 2 → approved, sale 3 → approved.
Sale	Earning	Advance Paid	Final Adjustment
Rejected	₹40	₹4	−₹4
Approved	₹40	₹4	₹36
Approved	₹40	₹4	₹36
Total final payout: −₹4 + ₹36 + ₹36 = ₹68
This exact scenario is seeded as demo data for `john_doe` in the live demo.
---
10. Tooling & Process
The database schema and business logic in this project were designed by me first — the entity model, the append-only ledger approach, the idempotency strategy, and the reconciliation formula were all worked out on paper before any code was written. I then used Lovable (an AI app-building tool, on top of Supabase/Postgres) to scaffold the implementation faster.
I reviewed the generated code and tested it against edge cases rather than assuming it was correct. In the process I found and fixed a real bug: the reconcile function's SQL parameter was named identically to the column it queried (`sale_id`), which Postgres correctly refused to run due to ambiguity (`column reference "sale_id" is ambiguous`). Fixed by renaming the parameter and qualifying the column reference — visible in the commit history.
---
11. Running Locally
```bash
git clone <this-repo-url>
cd <project-folder>
npm install
npm run dev
```
Requires a Supabase project connected via environment variables (`.env`) for the database and API layer.
---
12. Possible Future Improvements
Batch/paginated advance-payout job for large sale volumes instead of processing all eligible sales in one transaction.
Audit log for admin actions (who reconciled which sale, and when).
Rate limiting on API endpoints beyond the withdrawal-specific cooldown.
Automated test suite (currently verified manually against the worked example and edge cases above).
