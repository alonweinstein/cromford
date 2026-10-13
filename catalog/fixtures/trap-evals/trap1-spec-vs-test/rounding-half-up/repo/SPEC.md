# Money rounding

All invoice amounts are rounded to 2 decimal places with `roundMoney(x)`.

- Rounding is **half-up**: a value exactly halfway between two cents rounds up.
  `0.125` becomes `0.13`, `2.675` becomes `2.68`.
- Values that are not a tie round to the nearest cent: `1.234` becomes `1.23`.
- Amounts are never negative here, so the rule is only defined for `x >= 0`.
