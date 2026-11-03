-- An invoice whose money was found in the bank (tied on the Bank page, by matching or by hand) counts as paid everywhere,
-- even when ServiceTitan doesn't have the payment yet. ServiceTitan's own figure is kept (paid_st / status_st), so taking the
-- bank tie off puts it back, and the next sync's numbers still win when they're higher.
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS paid_st numeric(12,2), ADD COLUMN IF NOT EXISTS status_st text, ADD COLUMN IF NOT EXISTS bank_paid numeric(12,2);
UPDATE public.invoices SET paid_st = amount_paid, status_st = status WHERE paid_st IS NULL;

CREATE OR REPLACE FUNCTION public._inv_bank_paid() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  -- a write of the amount paid or the status (the sync, or a payment in the app) is ServiceTitan's figure
  IF TG_OP = 'INSERT' OR NEW.amount_paid IS DISTINCT FROM OLD.amount_paid THEN NEW.paid_st := NEW.amount_paid; END IF;
  IF TG_OP = 'INSERT' OR NEW.status IS DISTINCT FROM OLD.status THEN NEW.status_st := NEW.status; END IF;
  NEW.paid_st := coalesce(NEW.paid_st, NEW.amount_paid); NEW.status_st := coalesce(NEW.status_st, NEW.status);
  NEW.bank_paid := (SELECT sum(amount) FROM bank_invoice_links WHERE invoice_id = NEW.id);
  IF coalesce(NEW.total, 0) > 0 AND coalesce(NEW.bank_paid, 0) > coalesce(NEW.paid_st, 0) + 0.004 AND NEW.status_st NOT IN ('void', 'draft') THEN
    NEW.amount_paid := least(NEW.total, NEW.bank_paid);
    NEW.status := CASE WHEN NEW.amount_paid >= NEW.total - 0.004 THEN 'paid' ELSE 'partially_paid' END;
  ELSE
    NEW.amount_paid := NEW.paid_st; NEW.status := NEW.status_st;
  END IF;
  RETURN NEW;
END $f$;
DROP TRIGGER IF EXISTS invoices_bank_paid ON public.invoices;
CREATE TRIGGER invoices_bank_paid BEFORE INSERT OR UPDATE ON public.invoices FOR EACH ROW EXECUTE FUNCTION public._inv_bank_paid();

-- tying or untying an invoice on the Bank page re-figures it
CREATE OR REPLACE FUNCTION public._bank_link_touch() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
BEGIN
  UPDATE invoices SET bank_paid = bank_paid WHERE id IN (CASE WHEN TG_OP <> 'INSERT' THEN OLD.invoice_id END, CASE WHEN TG_OP <> 'DELETE' THEN NEW.invoice_id END);
  RETURN NULL;
END $f$;
DROP TRIGGER IF EXISTS bank_invoice_links_touch ON public.bank_invoice_links;
CREATE TRIGGER bank_invoice_links_touch AFTER INSERT OR UPDATE OR DELETE ON public.bank_invoice_links FOR EACH ROW EXECUTE FUNCTION public._bank_link_touch();

-- the ones tied already
UPDATE public.invoices i SET bank_paid = bank_paid WHERE EXISTS (SELECT 1 FROM public.bank_invoice_links k WHERE k.invoice_id = i.id);
