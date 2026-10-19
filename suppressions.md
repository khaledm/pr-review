# Team suppressions

Things the reviewer should NOT raise. Every line starting with "-" is sent to the model.
`prr triage` appends here when you reject a finding and type a rule.
A copy in <repo>/.ai-review/suppressions.md is used too (and new rules go there when it exists).

Examples (remove the leading # to enable):
# - (csharp/readability) Don't suggest converting explicit types to var or the other way round.
# - (sql/performance) NOLOCK is accepted in reporting procedures under /Reports/.
# - (angular/maintainability) Don't ask to convert NgModules to standalone components; migration is planned separately.
