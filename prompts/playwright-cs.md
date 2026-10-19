Focus: Playwright UI automation tests written in C# (NUnit / MSTest / xUnit), page objects and test helpers.

Look hardest for:

**Flakiness**
- Hard waits: `Thread.Sleep`, `Task.Delay`, `WaitForTimeoutAsync`. Use web-first assertions or waits for a specific state instead.
- Missing `await` on Playwright calls (actions run unobserved, test passes or fails at random), and `.Result` / `.Wait()` on async calls.
- Manual checks like `Assert.IsTrue(await locator.IsVisibleAsync())` that don't retry. Use `await Expect(locator).ToBeVisibleAsync()` and other auto-retrying assertions.
- Reading text or counts once (`InnerTextAsync`, `CountAsync`) and asserting immediately on content that loads asynchronously.
- Waiting for `NetworkIdle` or fixed load states as a substitute for waiting for the element or response that matters.

**Selectors**
- Brittle selectors: long CSS chains, `nth-child`, XPath based on layout, generated class names, text that changes with copy or language.
- Prefer `GetByRole`, `GetByLabel`, `GetByTestId` (`data-testid`) and other user-facing locators; flag new `data-testid` needs on the app side as a question, not a demand.
- Locators that can match more than one element (strict-mode violations) or match the wrong one.

**Test design**
- Tests that depend on each other's order, share static state, or reuse data created by another test.
- Test data that is not created by the test or not cleaned up; reliance on data that exists in only one environment.
- Hard-coded URLs, environment names, credentials or user accounts instead of configuration / secure settings.
- Missing assertions (a test that only clicks through), or asserting on implementation details instead of user-visible outcomes.
- Overly long tests covering many features: hard to diagnose. Logic duplicated instead of using page objects or helpers.
- `[Retry]` or broad try/catch used to hide flakiness instead of fixing it; catch blocks that swallow assertion failures.
- Parallel-safety: tests marked parallelizable that share accounts, records or browser contexts.

**Diagnostics**
- Failures that would be hard to debug: no tracing, screenshots or meaningful assertion messages for complex flows.
- Timeouts raised globally to mask slowness rather than scoped to a specific operation.

Apply normal C# correctness checks too (null handling, disposal of browser/context objects, async misuse).
