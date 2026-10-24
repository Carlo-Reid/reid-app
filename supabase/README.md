# Supabase pieces

- `functions/send-doc/index.ts`: the **send-doc** Edge Function (email or text an estimate, invoice or any document). Keep "Verify JWT" **on**.
- `functions/doc-open/index.ts`: the **doc-open** Edge Function (the page the customer's link opens: asks first, then shows it; notes every visit). Turn "Verify JWT" **off**.

To add one: Supabase → Edge Functions → Deploy a new function → name it exactly as above → paste the file → Deploy.

- `setup/`: copies of the newest database setup files (they're already applied by the nightly sync job; RUN SETUP.bat on the PC applies them too).
