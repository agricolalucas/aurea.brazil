CREATE POLICY cash_delete_commercial ON public.aes_cash_gst_expenses FOR DELETE TO authenticated USING (
lower((select auth.jwt()->>'email'))='comercial@aureainternacional.com'
AND EXISTS(SELECT 1 FROM public.app_members m WHERE m.user_id=(select auth.uid()) AND m.active AND m.role IN ('admin','operator')));
CREATE OR REPLACE FUNCTION public.aes_cash_protect_expense_delete() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
BEGIN
IF EXISTS(SELECT 1 FROM public.aes_cash_bank_match_items i JOIN public.aes_cash_bank_matches m ON m.id=i.match_id WHERE i.side='system' AND (i.system_key='expense-'||OLD.id OR starts_with(i.system_key,'expense-'||OLD.id||'-'))) THEN
RAISE EXCEPTION 'Desconcilie esta despesa antes de excluir.';
END IF;
RETURN OLD;
END $$;
CREATE TRIGGER aes_cash_protect_expense_delete BEFORE DELETE ON public.aes_cash_gst_expenses FOR EACH ROW EXECUTE FUNCTION public.aes_cash_protect_expense_delete();