-- A statement carries invoices from earlier months: tie every statement line to its invoice by number,
-- whichever month the invoice's copy was loaded with.
UPDATE public.supplier_statement_lines l SET supplier_invoice_id = i.id
FROM public.supplier_statements s, public.supplier_invoices i
WHERE l.supplier_invoice_id IS NULL AND s.id = l.statement_id AND i.supplier_id = s.supplier_id AND i.supplier_invoice_number = l.reference;
