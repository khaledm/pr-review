Focus: C# on .NET Framework 4.8 (ASP.NET MVC / Web API / WebForms, class libraries, services, config files).

Look hardest for:

**Async and threading**
- Sync-over-async (`.Result`, `.Wait()`, `.GetAwaiter().GetResult()`) on code that runs under ASP.NET's synchronization context: deadlock risk.
- `async void` outside event handlers; fire-and-forget tasks whose exceptions are lost; `Task.Run` used inside request handling.
- Missing `ConfigureAwait(false)` in library code that may be called synchronously.
- Shared mutable state (static fields, singletons, caches) touched without locking or concurrent collections.

**Resources and lifetime**
- `IDisposable` not disposed (`SqlConnection`, `SqlCommand`, readers, streams, `HttpResponseMessage`): use `using`.
- `new HttpClient()` per call: socket exhaustion. Prefer a shared instance.
- DbContext (EF6) lifetime: shared across threads or requests; long-lived contexts accumulating tracked entities.

**Data access**
- SQL built by string concatenation or interpolation: injection risk. Use parameters.
- EF6: N+1 queries from lazy loading inside loops; `ToList()` before filtering; missing `AsNoTracking()` for read-only queries; `Include` that pulls far more than needed.
- Transactions: partial updates with no transaction; `TransactionScope` without `TransactionScopeAsyncFlowOption.Enabled` around `await`.

**Correctness**
- Null dereferences on values that can legitimately be null (lookups, `FirstOrDefault`, deserialised input, config values).
- `DateTime.Now` where UTC is required; `DateTime` vs `DateTimeOffset` mix-ups; time-zone assumptions.
- Culture-sensitive parsing/formatting (`ToString()`, `Parse`, `ToUpper`) where `InvariantCulture` or ordinal comparison is needed.
- Multiple enumeration of `IEnumerable` from a query; `Single`/`First` that can throw on real data.
- Integer overflow, decimal vs double for money, rounding.
- Off-by-one and boundary conditions in loops, paging and date ranges.

**Error handling and logging**
- `catch (Exception)` that swallows, logs without context, or rethrows with `throw ex;` (loses the stack trace).
- Errors returned to the client with internal details (stack traces, connection strings).
- Missing logging around new failure paths; sensitive data written to logs.

**Security**
- Missing `[Authorize]` / authorization checks on new endpoints or actions; trusting client-supplied IDs without ownership checks (IDOR).
- Missing `[ValidateAntiForgeryToken]` on state-changing MVC POST actions.
- `Html.Raw` or unencoded output of user data (XSS); open redirects; path traversal with user-supplied file names.
- Secrets, connection strings or keys added to code or `web.config` / `app.config` (should come from transforms, Key Vault or the release pipeline).
- Weak crypto, `ServicePointManager` certificate validation overrides, disabled TLS checks.

**Design and maintainability**
- Business logic in controllers or code-behind that belongs in a service; copy-pasted logic that already exists elsewhere in the PR.
- Public API or contract changes (DTOs, interfaces, WCF/Web API signatures) that may break other callers.
- Magic numbers or strings that should be constants or configuration.
- Config changes that differ between environments without matching transforms.

Do not comment on naming, brace style or `var` usage unless it hides a real bug.
