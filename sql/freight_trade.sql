CREATE TABLE IF NOT EXISTS public.aes_freight_trades (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 trade_number text NOT NULL CHECK (length(trim(trade_number)) BETWEEN 1 AND 100),
 trade_date date NOT NULL DEFAULT current_date,
 status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','confirmed','completed','cancelled')),
 company_id bigint REFERENCES public.companies(id),
 supplier_id bigint REFERENCES public.companies(id),
 customer_id bigint REFERENCES public.companies(id),
 route jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(route)='object'),
 purchase_flow jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(purchase_flow)='object'),
 sale_flow jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(sale_flow)='object'),
 notes text NOT NULL DEFAULT '',
 created_by uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id),
 updated_by uuid DEFAULT auth.uid() REFERENCES auth.users(id),
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS aes_freight_trades_number_key ON public.aes_freight_trades(lower(trade_number));
CREATE INDEX IF NOT EXISTS aes_freight_trades_supplier_idx ON public.aes_freight_trades(supplier_id);
CREATE INDEX IF NOT EXISTS aes_freight_trades_customer_idx ON public.aes_freight_trades(customer_id);
CREATE INDEX IF NOT EXISTS aes_freight_trades_company_idx ON public.aes_freight_trades(company_id);
CREATE OR REPLACE FUNCTION public.aes_freight_trade_stamp() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
BEGIN
 IF NEW.created_by IS DISTINCT FROM OLD.created_by OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
  RAISE EXCEPTION 'Creation audit fields cannot be changed';
 END IF;
 NEW.updated_at=clock_timestamp();NEW.updated_by=auth.uid();RETURN NEW;
END $$;
CREATE TRIGGER aes_freight_trade_stamp BEFORE UPDATE ON public.aes_freight_trades
FOR EACH ROW EXECUTE FUNCTION public.aes_freight_trade_stamp();
ALTER TABLE public.aes_freight_trades ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.aes_freight_trades FROM anon,authenticated;
GRANT SELECT,INSERT,UPDATE ON public.aes_freight_trades TO authenticated;
CREATE POLICY aes_freight_trades_read ON public.aes_freight_trades FOR SELECT TO authenticated
USING (EXISTS(SELECT 1 FROM public.app_members m WHERE m.user_id=(SELECT auth.uid()) AND m.active));
CREATE POLICY aes_freight_trades_insert ON public.aes_freight_trades FOR INSERT TO authenticated
WITH CHECK (created_by=(SELECT auth.uid()) AND EXISTS(SELECT 1 FROM public.app_members m WHERE m.user_id=(SELECT auth.uid()) AND m.active));
CREATE POLICY aes_freight_trades_update ON public.aes_freight_trades FOR UPDATE TO authenticated
USING (EXISTS(SELECT 1 FROM public.app_members m WHERE m.user_id=(SELECT auth.uid()) AND m.active))
WITH CHECK (EXISTS(SELECT 1 FROM public.app_members m WHERE m.user_id=(SELECT auth.uid()) AND m.active));
