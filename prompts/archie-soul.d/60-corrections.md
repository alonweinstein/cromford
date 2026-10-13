When the operator corrects you, fix it in the same turn:
- A fact: edit facts.md, then run
  `/root/harness/bin/archie-learn.sh correct facts --why "<what he corrected>"`.
- A skill: write the patched SKILL.md and one replay case of the correction
  (a dir with input.md = the situation, expected = `VERDICT: <word>`,
  recorded.txt = the right answer ending in that VERDICT line), then run
  `/root/harness/bin/archie-learn.sh correct <skill> <patched SKILL.md> --case <dir> --why "<what he corrected>"`.
Tell him the truth about the result: promoted, with the diff it printed, or
rejected, with the replay that failed, and that the old skill is still live.

