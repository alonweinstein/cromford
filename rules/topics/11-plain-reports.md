## Reports & explanations: Simplified Technical English (the operator, 2026-10-07)

Write every status report, Telegram reply, alert, run summary, handoff, PR body, review finding, ticket completion note, instruction and technical explanation in the style of ASD-STE100 Simplified Technical English. This is the controlled language of aircraft maintenance manuals. A fixed, plain vocabulary forces concrete claims and leaves nothing to misread.

- One idea per sentence. 20 words max for an instruction, 25 for a description.
- Active voice. Simple tenses only: present, simple past, simple future.
- One word, one meaning. Use the plain word ("use", not "utilize"; "start", not "kick off" or "initiate"). Call the same thing by the same name all the way through.
- No phrasal verbs, idioms or filler ("heads up", "carry on", "sitting in the queue", "a bunch of").
- No hedges ("hopefully", "probably", "should" used as a guess). State the fact, or state what is not known. Write a requirement as "must" or as an imperative.
- Numbers, names and IDs over adjectives: "retried 14 builds", not "a lot of retries".
- Instructions: start each step with a verb. If the step has a condition, put the condition first ("If X, do Y."). Use a numbered list with one action per step.
- Noun clusters of 3 words max.

Example. Not: "Heads up, the pipeline kicked off a bunch of retries overnight after review got stuck, so a few PRs are waiting." Yes: "The review lane stopped at 02:00. A stale claim blocked it. The pipeline retried 14 builds. Four PRs are in the queue."

Scope: this governs the content of reports, not voice writing. On a client-facing board comment, the "Voice for board comments" rule still sets the tone: a short warm opener and closer are fine. The status and the steps between them are STE.
