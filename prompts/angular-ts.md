Focus: Angular front end in TypeScript (components, services, templates, styles, build config).

Look hardest for:

**RxJS and subscriptions**
- `subscribe()` in components without unsubscribing (`takeUntil`/`takeUntilDestroyed`, `async` pipe, or `ngOnDestroy` cleanup): memory leaks and duplicate handlers.
- Nested `subscribe` calls that should be `switchMap` / `mergeMap` / `concatMap`; the wrong flattening operator for the use case (e.g. `mergeMap` for search-as-you-type should be `switchMap`).
- HTTP calls made repeatedly because an observable is subscribed several times (`async` pipe used more than once without `shareReplay`).
- `setInterval`, event listeners or `fromEvent` streams that are never cleaned up.

**HTTP and error handling**
- HTTP calls with no error handling, leaving the UI stuck in a loading state or failing silently.
- Errors swallowed with an empty `catchError` or a `console.log`.
- Hard-coded API URLs or environment values instead of `environment.ts` / configuration.

**Templates and change detection**
- `*ngFor` over large or frequently-refreshed lists without `trackBy`.
- Method calls or heavy expressions in templates that run on every change detection cycle.
- `OnPush` components whose inputs are mutated in place instead of replaced.
- Null/undefined access in templates without `?.` or guards, for data that loads asynchronously.

**Security**
- `[innerHTML]` with user or server content, and any `bypassSecurityTrust*` call: XSS risk, needs justification.
- Tokens or sensitive data stored in `localStorage` or logged to the console.
- Route guards missing on new routes that need authentication or roles.

**Types and correctness**
- `any`, non-null assertions (`!`) and type casts that hide real nullability or shape problems.
- Form validation missing or only client-side for rules the server must also enforce; reactive form controls not reset or updated correctly.
- Date and time handling (time zones, `new Date(string)` parsing differences between browsers).
- Floating-point arithmetic for money or quantities.

**Structure and maintainability**
- Business logic in components that belongs in a service; duplicated logic across components.
- Services provided at the wrong level (accidental multiple instances, or shared state where isolation was intended).
- Large modules or components that should be lazy-loaded; new dependencies added to `package.json` without a clear need.
- Accessibility regressions in new UI: missing labels, buttons without accessible names, keyboard traps.

Do not comment on formatting or import ordering. Assume a linter covers those.
