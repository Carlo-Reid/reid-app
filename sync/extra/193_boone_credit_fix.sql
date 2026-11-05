-- One-time fix: Boone invoices saved as credits because of the line printed at the bottom of every Boone invoice
-- ("INVOICE NUMBER MUST BE QUOTED BEFORE ISSUANCE OF CREDIT NOTE"). The reader no longer takes that line for a credit note.
--  1. The November 2026 invoices checked against their scans (no statement for them yet): invoices, with these totals.
--  2. Any other Boone "credit" that a Boone statement lists as an invoice (I) for the same amount: an invoice.
-- Each change is recorded in the audit log. Safe to run more than once.
DO $$ DECLARE n1 int := 0; n2 int := 0; r record;
BEGIN
  FOR r IN SELECT s.id, s.supplier_invoice_number, s.doc_type, s.total, v.t FROM supplier_invoices s
           JOIN (VALUES ('C451062', 1654.32), ('C449517', 227.36), ('C448260', 525.33), ('C448030', 61.43), ('C447918', 1478.36), ('C447316', 785.32),
                        ('C447297', 554.13), ('C446557', 120.91), ('C445838', 701.73), ('C444498', 1162.59)) v(num, t) ON v.num = s.supplier_invoice_number
           JOIN suppliers sp ON sp.id = s.supplier_id AND sp.name ILIKE 'Boone%'
           WHERE s.invoice_date >= '2026-11-01' AND (coalesce(s.doc_type, 'invoice') <> 'invoice' OR s.total IS DISTINCT FROM v.t) LOOP
    UPDATE supplier_invoices SET doc_type = 'invoice', total = r.t, updated_at = now() WHERE id = r.id;
    INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('supplier_invoices', r.id, 'update', NULL,
      jsonb_build_object('fix', 'a Boone invoice saved as a credit or with no total', 'was_type', r.doc_type, 'was_total', r.total, 'total', r.t));
    n1 := n1 + 1;
  END LOOP;
  FOR r IN SELECT DISTINCT ON (s.id) s.id, s.total FROM supplier_invoices s JOIN suppliers sp ON sp.id = s.supplier_id AND sp.name ILIKE 'Boone%'
           JOIN supplier_statement_lines l ON upper(regexp_replace(l.reference, '\W', '', 'g')) = upper(regexp_replace(s.supplier_invoice_number, '\W', '', 'g'))
           JOIN supplier_statements st ON st.id = l.statement_id AND st.supplier_id = s.supplier_id
           WHERE s.doc_type = 'credit' AND s.total < 0 AND l.code = 'I' AND l.amount > 0 AND abs(l.amount - abs(s.total)) < 0.01 LOOP
    UPDATE supplier_invoices SET doc_type = 'invoice', total = abs(r.total), updated_at = now() WHERE id = r.id;
    INSERT INTO audit_log (table_name, row_id, action, changed_by_user_id, new_values) VALUES ('supplier_invoices', r.id, 'update', NULL,
      jsonb_build_object('fix', 'a Boone invoice saved as a credit (the statement says invoice)', 'was_total', r.total, 'total', abs(r.total)));
    n2 := n2 + 1;
  END LOOP;
  RAISE NOTICE 'Boone credit fix: % November invoices, % others the statements call invoices', n1, n2;
END $$;
