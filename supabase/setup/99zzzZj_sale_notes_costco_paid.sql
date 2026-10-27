-- copy of sync/extra/050_sale_notes_costco_paid.sql (run by the nightly sync)
-- One-time copy (Oct 27, 2026), part 2: pinned location notes that say Costco paid for the install
-- ("Costco paid install Sep 8 11,152.21"), counted the same as the "Costco payment received" notes (046).
-- Only the payment line of each note. Safe to run again: copied once only.
INSERT INTO public.sale_notes (est_id, job_id, source_note_id, noted_at, body) VALUES
  (107777372, 107709064, 788105, '2026-10-07T15:36:25+00:00', 'Costco paid for install sep 1 2,202.48'),
  (109687170, 109597928, 788221, '2026-10-07T15:39:35+00:00', 'Costco paid install sep 10 5,621.86'),
  (104796206, 104690971, 788116, '2026-07-16T15:57:47+00:00', '***Costco lead# 1688778*** Install Paid Aug 24th'),
  (105236880, 105087732, 787851, '2026-08-11T19:30:04+00:00', 'Costco paymetn received on aug 4th.'),
  (105986158, 105950877, 788197, '2026-10-07T15:38:24+00:00', 'Costco paid install Sep 8 11,152.21'),
  (107801361, 107771612, 788241, '2026-10-07T15:42:37+00:00', 'Costco paid for install sep 21 9,046.27'),
  (108800733, 108541192, 788150, '2026-10-07T15:37:54+00:00', 'Costco paid for install sep 4 2,023.83'),
  (108750937, 108545019, 768839, '2026-07-28T13:53:38+00:00', 'Costco paid oct 5 2,898.45'),
  (109057108, 108538014, 788138, '2026-10-07T15:38:57+00:00', 'Costco Paid install sep 9 6,435.47'),
  (109580410, 109395444, 788231, '2026-10-07T15:44:07+00:00', 'Costco paid for install sep 21 6,225.28'),
  (110242858, 110221652, 769637, '2026-08-14T13:59:23+00:00', 'Costco paid for install sep 10 2,023.83 for HWT & Sep 21 7,331.55 for furnace'),
  (110947041, 110678903, 788260, '2026-10-07T15:46:10+00:00', 'Costco paid for install oct 5 7,934.97')
ON CONFLICT (est_id, source_note_id) DO NOTHING;
