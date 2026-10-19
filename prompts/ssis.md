Focus: SSIS packages and project files.

`.dtsx` files are not shown as raw XML. They have been converted into a readable summary so you see only functional changes. Layout, GUIDs and version noise are removed. The summary uses these line types:
- `CONNECTION`, `PARAMETER`, `VARIABLE`: package-level settings (passwords are masked).
- `TASK <path> [type]` followed by its `EXPR` (property expressions), `SQL:` (Execute SQL statements), `PARAM`/`RESULT` bindings, `SCRIPT FILE` (script task source) and `DATA` (other task settings).
- `COMPONENT` lines describe data flow components, with their properties, connections, `OUTPUT` columns and `DERIVED` column expressions. `PATH` lines show data flow paths.
- `FLOW a -> b on Success|Failure|Completion` lines are precedence constraints.

For `.dtsx` files set `line` and `end_line` to null. In your comment, name the task or component so the author can find it.

Look hardest for:

**Configuration and environments**
- Server names, database names, file paths or credentials hard-coded in connection strings, variables or expressions instead of coming from project/package parameters or environment configuration.
- `ProtectionLevel` changes, especially `EncryptSensitiveWithUserKey` (breaks on the build/deploy server) or sensitive values stored in plain text.
- Connection managers added or changed in one package but not in the project-level `.conmgr` (or the other way round).

**Control flow**
- Precedence constraints changed so that steps can run on failure, run in parallel when they shouldn't, or are skipped (check `Success`/`Failure`/`Completion` and `(OR)` logic).
- Tasks accidentally left `DISABLED`.
- `TransactionOption` / `IsolationLevel` changes; `FailPackageOnFailure` / `MaxErrorCount` changes that hide failures.
- Missing error handling or logging for new tasks (`OnError` event handlers).

**SQL inside packages**
- Apply the same checks as for T-SQL: NULL handling, non-SARGable predicates, missing transactions, non-idempotent statements, injection via expressions that build SQL from variables.
- `SQL from Variable` statements whose expression can produce invalid SQL.

**Data flow**
- Data type or length changes that truncate (`DT_STR`/`DT_WSTR` lengths, numeric precision), code page issues between `DT_STR` and `DT_WSTR`.
- Error outputs: rows redirected to an error output that goes nowhere, or `errorRowDisposition` changed to ignore failures.
- Lookups: no-match behaviour (`NoMatchBehavior`) that silently drops rows; full cache on very large reference tables; case-sensitive lookup mismatches.
- `OLE DB Command` used row by row on large volumes; blocking components (`Sort`, `Aggregate`) on large data where SQL could do it.
- Destination fast-load options: `TABLOCK`, `CHECK_CONSTRAINTS`, batch / commit sizes, `KEEPIDENTITY`, `KEEPNULLS`. Check they are intentional.
- Column mappings that changed or were dropped between source and destination.

**Script tasks / components**
- Review `SCRIPT FILE` code like any C#: null handling, exceptions swallowed without failing the task (`Dts.TaskResult`), resources not disposed, hard-coded paths.

**Project files (.dtproj, .params)**
- Parameters added without values for every environment, or `Required`/`Sensitive` flags that change deployment behaviour.
