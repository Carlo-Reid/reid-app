# Notes for working on this app

## Carlo's standing rules (always follow)

- **Save buttons are green whenever there's something to save.** Any button whose label starts with "Save" (Save, Save them all, Save the statement, Save note…) is a clear green (#1f9d4a, the same in every colour theme) while it can be pressed, and goes back to normal once it's pressed or greyed out. This is done app-wide by `greenSave()` in `index.html` (class `save-go`), so new Save buttons get it automatically. Keep new save buttons labelled "Save…" and don't override their colour. The older `greenSaveButtons()` "nothing changed" grey (`btn-clean`) must never win over `save-go`: a Save in a question box (askChoice, e.g. "Save it") has nothing typed around it and must still be green.

## Waiting on Carlo (pick up next session)

- **Boone is paid by credit card.** Carlo is bringing the card payment info on Monday morning, Nov 9, 2026 so Boone's payments can be recorded like the bank payments to Lennox and Master (`sync/extra/195_bank_supplier_payments.sql`), and Boone's Our statement can match theirs. The app has three so far: Oct 2 $10,000, Oct 6 $10,000 and Oct 26 $12,662.01 ("Carlo P.C. Master Card"). Remind him at the start.

## Payroll side bar

- **No green or red in the Payroll side bar ("His calls").** Carlo is saving those colours for special side bar functions later. Maintenance shows teal-blue and Warranty grey there (`.pr-side .pr-k-*`); the call boxes keep their usual colours.

## Office staff time (Payroll)

- Office staff = app role office, admin, accounting, dispatcher or warehouse (not techs, even if ServiceTitan says technician). Their payroll page is time in / time out, not calls (`openOfficePayroll`, `sync/extra/212_office_time.sql`).
- Work day turns over at 2 am. Time in: "Let's start the day" screen, or signing in in the morning. Time out: the "Done work" button at the top of the side bar; if they forget, their last typing/click/scroll, and they must verify it next time.
- Pay counts only from 15 min before the expected start to 15 min after the expected end. Owners set expected hours per weekday on the person's payroll page.
