# Design and policies

[Schema and ERD](schema.md)

## Operations and transactions

Applications call the `circulation_api` package for circulation writes. The package is defined with `AUTHID DEFINER`. A successful operation keeps its locks until the caller commits or rolls back. A failed operation rolls back to the package’s internal savepoint. Reserve the savepoint name `circulation_call` for the package.

| Procedure | Validation and changes |
| --- | --- |
| `checkout` | Locks the title and member before checking the copy, active loan count, and oldest active hold. Creates a loan with the member category’s loan period. Fulfills the oldest hold when its member checks out. |
| `return_loan` | Rejects a closed loan and a return earlier than checkout or the last renewal. Sets `returned_on` and leaves earlier events intact. |
| `renew_loan` | Requires an eligible member and an open loan within its due date and renewal limit. A different member’s active hold blocks renewal. Advances the due date by the current loan period and inserts the old and new due dates in `RENEWAL`. |
| `reserve_title` | Requires an active, unexpired member and no lendable copy of the requested title. Inserts one active hold per member/title. |
| `cancel_reservation` | Closes an active reservation belonging to the specified member, recording the closure time. |

The package takes locks in the order title, member, copy, loan where those rows are involved. The title lock serializes copy checkout and reservation decisions for a title. The member lock protects the quota across titles. Use one circulation call per transaction unless the caller controls a consistent lock order across its entire batch. If a transaction deadlocks, roll it back before retrying.

## Database rules

- A function-based unique index permits at most one open loan per copy. Another permits at most one active reservation per member/title. Closed rows remain in the history.
- `v_copy_availability` calculates lendability from a copy’s condition and the absence of an open loan. The checkout API also applies membership eligibility and reservation priority.
- `v_active_loans` uses the Oracle server date for overdue days. The demo fixes its comparison date for reproducibility and still selects currently open loans.
- An integrating service needs package execution and any view access it uses. It authenticates the requester and authorizes the submitted member and staff identifiers. Keep direct circulation table writes with the schema owner. Direct writes by a privileged account can bypass package rules such as quota and queue priority.
- The catalog stores publishers and authors separately from titles. `TITLE_AUTHOR` records many-to-many authorship, and each `BOOK_COPY` belongs to one title. `RENEWAL` stores the history of due dates. [Field dictionary and ERD](schema.md)

## Seed policies and project scope

| Member category | Loan limit | Loan period | Maximum renewals |
| --- | ---: | ---: | ---: |
| Undergraduate | 20 | 30 days | 3 |
| Final-year undergraduate | 25 | 30 days | 3 |
| Postgraduate | 30 | 30 days | 3 |

The seed limits and periods are informed by Universiti Malaya Central Library’s publicly documented open-shelf student borrowing rules. The policy also describes a three-renewal cap and a restriction when another borrower has reserved the item. The records and implementation in this repository are synthetic and independently modeled. [Library borrowing and returning policy](https://umlib.um.edu.my/borrowing-amp-returning)

FIFO ordering by reservation timestamp and ID, holding a title only when no copy can be lent, excluding overdue renewals, and adding renewal days to the current due date are project design choices. This implementation covers one open-shelf collection. Fines, notifications, transfer between branches, electronic resources, and integration with identity systems are outside its scope.
