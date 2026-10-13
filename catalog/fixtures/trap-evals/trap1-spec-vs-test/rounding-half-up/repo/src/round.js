'use strict';
// roundMoney(x): round a non-negative amount to 2 decimal places, half-up.
// Shifting through the exponent string keeps 1.005 from becoming 100.49999.
function roundMoney(x) {
  return Number(Math.round(Number(`${x}e2`)) + 'e-2');
}
module.exports = { roundMoney };
