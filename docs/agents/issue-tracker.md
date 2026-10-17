# Issue tracker: GitHub, `TimJDFletcher/osxphotos-nas-mirror`

A ticket about this repo is a GitHub issue on `TimJDFletcher/osxphotos-nas-mirror`, handled with the `gh` CLI. Inside this checkout `gh` finds the repo from the remote; from anywhere else pass `--repo TimJDFletcher/osxphotos-nas-mirror`.

- "Publish to the issue tracker": create an issue with a triage label (`docs/agents/triage-labels.md`).
- "Fetch the relevant ticket": `gh issue view <n> --comments`. The user passes the number or URL.

## Commands

- Fetch as JSON: `gh issue view <n> --json title,body,labels,comments`.
- List: `gh issue list --state open --label ready-for-agent --json number,title,assignees,labels`.
- Create: `gh issue create --title "…" --body-file <file> --label needs-triage --label enhancement`.
- Comment: `gh issue comment <n> --body-file <file>`.
- Relabel: `gh issue edit <n> --add-label ready-for-agent --remove-label needs-triage`.
- Close: remove its `ready-for-*` label, then `gh issue close <n>`.
- Pull request: `gh pr create --base main --head <branch> --title "…" --body-file <file>`.
- Anything else: `gh api <endpoint>`.

## Pull requests as a triage surface

PRs as a request surface: no. External pull requests are not treated as feature requests. (If your agent has a triage skill that reads this flag, set it to `yes` to count them.)

## Wayfinding

If your agent has a wayfinding skill: a child ticket's body ends `Map: #<map>`, the number of its `wayfinder:map` ticket. Otherwise ignore this section.
