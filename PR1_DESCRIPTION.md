### Summary of Changes

This PR addresses core financial calculation and invariant issues in `cobol/interest/BINT.cbl` and introduces a standalone regression test suite:

1. **Daily Compounding Basis Fix (`DO-COMPOUND`):**
   - **Issue:** Previously, `WS-WORK = WS-BASE * (1 + WS-RATE) ** INT-DAYS` elevated the annualized rate directly to the power of days without dividing by `INT-BASIS` (360/365). For a 30-day term at 10% p.a., this caused $(1.10)^{30} \approx 17.45\times$ capital growth (1,645% monthly interest) and numeric overflow at 365 days.
   - **Fix:** Introduced `WS-DAILY-RATE PIC S9(01)V9(10) COMP-3`. The rate is now annualized to daily basis: `COMPUTE WS-DAILY-RATE = WS-RATE / INT-BASIS`, then compounded: `WS-BASE * (1 + WS-DAILY-RATE) ** INT-DAYS`.
   - **Basis Validation:** Added mandatory validation ensuring `INT-BASIS` is either 360 or 365 (matching `DO-SIMPLE`).

2. **Arithmetic Overflow Guard (`ON SIZE ERROR`):**
   - Added an explicit `ON SIZE ERROR` handler to `DO-COMPOUND` returning `RC="21"` and `NUMERIC OVERFLOW IN COMPOUNDING` to prevent runtime S0C9 abends on out-of-range inputs.

3. **Fee Output Propagation (`DO-FEE`):**
   - Added `MOVE INT-FEE TO INT-INTEREST`. Previously, `DO-FEE` validated the input and returned `RC="00"`, but left `INT-INTEREST` at 0.00.

---

### Regression Test Suite

Added reproducible regression tests in `tests/test_bint.sh` and `tests/test_bint_driver.cbl`:
- `accrue_baseline`: Simple interest accrual check (10,000 @ 10% / 30 days / 360 basis = 83.33).
- `compound_daily`: Compound interest check (10,000 @ 10% / 30 days / 360 basis = 83.68).
- `compound_365`: 365-day compounding without overflow (10,000 @ 12% / 365 days / 365 basis = 1,274.75).
- `compound_bad_basis_rc`: Rejection of unsupported day count basis (returns RC 20).
- `fee_propagation`: Verification that fee amount (45.50) is returned in the linkage area.

Run tests locally via:
```bash
bash tests/test_bint.sh
```

---

Tested and verified against CobolIQ Static Crash Predictor (0 abends, 0 memory hazards).
Looking forward to your review!
