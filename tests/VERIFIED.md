# Validation

The portable Python launcher was exercised on macOS against Oracle AI Database 26ai Free `23.26.3.0.0` through Lima and nerdctl. The run built a fresh dedicated schema and used executable Oracle tests and synthetic data.

| Check | Observed result |
| --- | --- |
| Offline fixture validator | 44 checks passed |
| Launcher tests | 12 checks passed on macOS, including UTF-8 with BOM and paths containing spaces |
| Setup and verification | 11 tables, 12 enabled foreign keys, 30 assertions, no invalid objects or compilation errors |
| Demo | All four statements ran. Loan 1 was returned and then restored to outstanding. |
| Two-session concurrency | Same-copy contention returned `-20004`. Final-slot contention returned `-20005`. Cleanup restored eight loans. |
| UTF-8 SQL file | A UTF-8 BOM file ran through `sql --file` and confirmed the dedicated schema and eight-loan baseline. |

A separate fresh Oracle container initialized successfully on macOS using the same image with nerdctl. Docker Desktop and native Windows Oracle execution were outside these live checks.
