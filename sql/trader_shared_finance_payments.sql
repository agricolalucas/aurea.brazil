ALTER TABLE public.aes_finance_order_movements ADD COLUMN IF NOT EXISTS attachment_path text, ADD COLUMN IF NOT EXISTS attachment_name text;
DO $$
DECLARE d record; side text; flow jsonb; p jsonb; ord text; n integer; idx integer;
BEGIN
FOR d IN SELECT * FROM public.aes_trader_deals LOOP
FOREACH side IN ARRAY ARRAY['purchase','sale'] LOOP
flow=CASE WHEN side='purchase' THEN d.purchase_flow ELSE d.sale_flow END;
IF jsonb_array_length(coalesce(flow->'payments','[]'))=0 THEN CONTINUE; END IF;
ord='TRADER:'||d.id||':'||side;
IF EXISTS(SELECT 1 FROM public.aes_finance_order_movements WHERE order_number=ord) THEN CONTINUE; END IF;
IF EXISTS(SELECT 1 FROM jsonb_array_elements(flow->'payments') x WHERE coalesce(x->>'date','')='' OR coalesce((x->>'amount')::numeric,0)<=0) THEN CONTINUE; END IF;
idx=0;
FOR p IN SELECT value FROM jsonb_array_elements(flow->'payments') LOOP
idx=idx+1;
INSERT INTO public.aes_finance_order_movements(order_number,operation_type,movement_type,movement_date,amount,currency,bank,reference,payment_type,created_by,request_key)
VALUES(ord,'export','receipt',(p->>'date')::date,(p->>'amount')::numeric,coalesce(p->>'currency',d.currency,'USD'),p->>'bank',p->>'reference',coalesce(p->>'payment_type','Other'),d.created_by,md5('legacy-trader-payment:'||d.id||':'||side||':'||idx)::uuid);
END LOOP;
flow=jsonb_set(jsonb_set(flow,'{legacy_payments_migrated}',flow->'payments'),'{payments}','[]');
IF side='purchase' THEN UPDATE public.aes_trader_deals SET purchase_flow=flow WHERE id=d.id; ELSE UPDATE public.aes_trader_deals SET sale_flow=flow WHERE id=d.id; END IF;
END LOOP; END LOOP;
END $$;
CREATE OR REPLACE FUNCTION public.aes_finance_protect_matched_movement() RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
BEGIN
IF EXISTS(SELECT 1 FROM public.aes_cash_bank_match_items i JOIN public.aes_cash_bank_matches m ON m.id=i.match_id WHERE i.side='system' AND i.system_key='receipt-'||OLD.id) THEN
RAISE EXCEPTION 'Desconcilie o lançamento antes de alterar ou excluir.';
END IF;
IF TG_OP='DELETE' THEN RETURN OLD; END IF; RETURN NEW;
END $$;
CREATE TRIGGER aes_finance_protect_matched_movement BEFORE UPDATE OR DELETE ON public.aes_finance_order_movements FOR EACH ROW EXECUTE FUNCTION public.aes_finance_protect_matched_movement();