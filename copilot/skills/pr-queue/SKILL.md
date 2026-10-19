---
name: pr-queue
description: List the Azure DevOps pull requests waiting for the user's review across all configured collections, with their local review status. Use when the user asks what PRs they need to review, their review queue, or what is waiting for them.
argument-hint: "[collection name]"
---

# Pull requests waiting for review

Run prr with PowerShell 7 (`PRR` below means `{{PRR}}`):

    PRR queue

Add `-Collection <name>` if the user named a collection.

Show the result as a table: collection, PR id, repository, title, author, the user's current vote, and the local status. Local status is one of:

- not reviewed
- new commits
- N to triage
- N to post
- done

Then suggest the next step for the most useful PR:

- **not reviewed**: review it with the pr-review skill.
- **new commits**: incremental review with the pr-review skill.
- **to triage / to post**: continue with the pr-review skill from its "Present the findings" step.

Do not start a review unless the user asks for one.
