Focus: T-SQL for SQL Server (stored procedures, functions, views, tables, indexes, deployment and data-fix scripts).

Look hardest for:

**Correctness**
- `NOT IN` against a subquery whose column can be NULL (returns no rows). Prefer `NOT EXISTS`.
- `TOP` without a deterministic `ORDER BY`; `ORDER BY` in views or subqueries that is not guaranteed.
- Joins that can multiply rows (missing join predicate, one-to-many where one-to-one is assumed) and silently change totals.
- Wrong NULL handling in comparisons, `ISNULL`/`COALESCE` changing data types, `COUNT(column)` vs `COUNT(*)`.
- Date logic: `BETWEEN` with datetime end boundaries, `GETDATE()` vs `SYSUTCDATETIME()`, implicit string-to-date conversion.
- Data type changes or variable declarations that truncate (`VARCHAR` without length defaults to 1 or 30), lose precision, or overflow.

**Transactions and errors**
- Multi-statement changes without a transaction, or with a transaction but no `TRY...CATCH` and `XACT_ABORT ON`.
- `@@ERROR` style handling that misses errors; `CATCH` blocks that swallow errors without `THROW`.
- Long transactions or blocking patterns on hot tables; `NOLOCK` / `READ UNCOMMITTED` used where dirty reads would give wrong results.

**Performance**
- Non-SARGable predicates: functions or arithmetic on indexed columns (`WHERE YEAR(OrderDate) = ...`, `CONVERT` on columns, leading `%` in `LIKE`).
- Implicit conversions between parameter and column types (e.g. `NVARCHAR` parameter against a `VARCHAR` column) that prevent index seeks.
- Cursors or `WHILE` loops doing row-by-row work that a set-based statement could do.
- Scalar UDFs or multi-statement table-valued functions in large queries; `SELECT *`; missing or redundant indexes for new query patterns.
- Parameter sniffing risk for procedures with very skewed parameters; table variables used for large row counts.

**Deployment safety**
- Scripts that are not re-runnable: missing `IF EXISTS` / `IF NOT EXISTS` guards or `CREATE OR ALTER`.
- Schema changes that break dependents: dropped or renamed columns, changed types, changed procedure parameters or result shapes used by the application or SSIS packages.
- Adding `NOT NULL` columns without defaults to populated tables; index builds on large tables during business hours without `ONLINE = ON` (if the edition allows).
- Data-fix scripts without a `WHERE` clause, without a row-count check, or without a backup/rollback plan.
- Permission changes (`GRANT`, `EXECUTE AS`, ownership chaining) and new linked-server usage.

**Security**
- Dynamic SQL built by concatenating parameters. Use `sp_executesql` with parameters and `QUOTENAME` for identifiers.

Do not comment on keyword casing, aliasing style or formatting.
