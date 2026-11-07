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

## Dispatch areas (how places are coloured)

- Places are coloured ONE way everywhere (customer page, dispatch board, map, Calls nearby): 8 dispatch areas from the postal code's first 3 characters (`DISPATCH_AREAS` / `areaOf()` at the top of the main script in `index.html`). Rural K0A and unlisted postal areas go to the nearest area by map location; over 35 km from all of them is "Out of town". Agreed with Carlo Nov 7, 2026.
- West: Kanata & Stittsville (blue) · Nepean (green) · Barrhaven, Riverside South & Manotick (orange) · Central (purple) · South Ottawa (red) · Gloucester & Vanier (teal) · Orléans & east (yellow) · Out of town (grey).
- Neighbourhoods, communities and towns are text only now, not colours. Don't bring back a second "border" colour.

## Dispatch ✨ Optimize

- Flags calls outside the tech's area for the day, then suggests a move to a tech with room in that area, or, if nobody has room, a swap of two calls between two techs (ticked/unticked and undone together). Nothing changes until Carlo approves.
- Never swap a call whose tech already has its parts in his truck (`dispatch_parts_held`, `sync/extra/218_parts_on_truck.sql`: a received PO he ordered for the job, or stock received/transferred into his truck for the job). Carlo's rule, Nov 7, 2026.
- Clicking a call on the board shows its own Optimize suggestion in the details panel ("Move it to Scott" / "Make this swap"), which makes just that one change after a yes; Undo puts it back.

## Contact tech / Ask the office to call me

- Blue 📞 button in the left side bar. Office/owners: "Contact tech" (pick a tech) → his screen shows "Call Carlo at the office". Techs: "Ask the office to call me" (pick an office person or owner) → their screen shows "Nick wants you to call him" with his phone if we have it. Optional "What about?" note.
- The pop-up sits at the top of the screen (beeps, vibrates on phones) with a ⏱ timer of how long it's been waiting (yellow at 10 min, red at 30). Got it = accepted (logged); it stays until they press Call back done, then the sender gets a green "Nick called you back" pop-up (OK closes it). 📋 Log in the Contact dialog: sent / Got it / called back times (owners see everyone's). `220_call_requests_log.sql`. `sync/extra/219_call_requests.sql`, `startCallReq` / `openContact` in `index.html`.

## Book a call (office)

- One question at a time (`bkWizard`): Reid or a Partner (→ pick the partner) → kind of call (Service, Maintenance, Warranty, Estimate, Install…) → which job type. The department fills in from the job type (`unit_id`), then the rest of the booking shows with "Reid › Service › Service Call - Regular Hours · Department" crumbs to change any step. A partner sees its own job types first ("Vista - Maintenance"); other partners' types are hidden. Vista asks who pays for the tank only for installs / water heaters. "Another visit" (open job) is on the first step.
- Picking the tech: every office booking (new call or another visit) uses the same Best techs to send squares + Calls nearby board as the customer page (`bkNearHtml`, `nearCallsHtml(..., { pick: true, bkAll: true })`). The tech's kind comes from the job type. Pick fills the tech, day and window, so the Day and Arrival window rows are gone there (`bkNearOnly`); "Pick by hand" brings back the chips, and "Not booked yet" is in the Picked line.

## HSG Pro logo (bottom of the Customers page)

- HSG Pro badge with a "👆 Click me" tag; clicking it shows one of 200 kind messages (`HSG_MSGS`), going through all 200 before any repeats (kept in localStorage), some using how long they've been with us from the Staff page "Started working here" date (`sync/extra/221_staff_started.sql`).
