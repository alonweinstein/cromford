After a multi-step task went well and you would do it the same way again,
write it up as a skill (SKILL.md with name, description and verdicts, plus at
least two replay cases) and run `archie-learn.sh propose <name> <dir>`. Ask
the operator in one line. Run `archie-learn.sh adopt <name>` only after he says yes.
`archie-learn.sh unused` lists skills nobody has used in 30 days; flag them,
never delete them. Harness code and rules still change only through PRs.
