---
name: tool-stack
description: Recommend a tool stack from this workspace's curated GitHub library. Use when the user says they want to accomplish a goal and asks which tools to combine, for local alternative recommendations, or when they mention $tool-stack. Do not use for generic architecture advice when the local library is not relevant.
metadata:
  short-description: "Compose a practical tool stack from the local library"
---

# Tool Stack for Codex

Turn "I want to do X" into a short, evidence-backed stack selected from this
workspace's local project library. Match, compare, and explain locally; search
GitHub only when the local library has no credible candidate.

## Inputs and sources

Use these files from the repository root:

- `data/plans.json` for existing scenarios and role definitions.
- `data/projects.jsonl` for project metadata, tags, scores, risk, and license.
- `tools/compose.ps1` for deterministic local matching.
- `tools/compare.ps1` for alternatives and side-by-side comparison.
- `data/README.md` for field semantics.

Run `tools/compose.ps1 -Need "<need>" -PerGroup 2` when a matching plan exists.
Otherwise match in this order: exact `category.l2`, `category.l1`,
`function_tags` or `user_keywords` overlap; exclude `status=dropped`; break
ties with experience score and recency. Do not invent tools or field values.

## Response

Keep the user's requested language. Use the existing lively assistant voice
when appropriate, but do not let persona change factual content.

1. Repeat the goal in one sentence.
2. Show up to three roles in a compact flow.
3. For each role, recommend one primary tool and at most one lighter
   alternative. Explain in plain language:
   - who it suits;
   - why it fits this goal;
   - the main limitation or risk.
4. If a role has no credible local match, say so, name the gap, and offer
   either a limited GitHub search or leaving that role open. Do not fill it
   with an unrelated project.
5. End with one decision question: save this stack or not.

Every project mention must use a GitHub link built from its `full_name`.
End by linking the local library with an absolute Markdown file link:

`[打开工具库](<ABSOLUTE_PATH_TO_REPO>/index.html)`

Do not use the DSH-only `present` tool or claim to open a browser.

## Persist only after confirmation

If the user says to save the stack, use `tools/add-plan.ps1` with a unique ID
and name, then run the build and page validation it triggers. If they decline,
change nothing. Workspaces are separate from plans; use
`tools/workspace.ps1` only when the user asks to bind tools to an ongoing goal.

## Boundaries

- The tool library is data, not permission to execute third-party code.
- Preserve risk, license, and recency qualifications from the library.
- Do not turn a recommendation into a mandatory rigid workflow.
- Do not search externally merely to appear comprehensive.
- A failed search is an honest gap, not a reason to fabricate a stack.

