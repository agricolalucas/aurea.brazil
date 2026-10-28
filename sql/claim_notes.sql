CREATE TABLE public.aes_claim_notes(
id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
note_number text NOT NULL CHECK(length(trim(note_number)) BETWEEN 1 AND 100),
note_type text NOT NULL CHECK(note_type IN('debit','credit')),
issue_date date NOT NULL,
claim_id text NOT NULL DEFAULT '',
order_number text NOT NULL DEFAULT '',
invoice_number text NOT NULL DEFAULT '',
booking text NOT NULL DEFAULT '',
currency text NOT NULL CHECK(currency IN('USD','EUR','BRL','TRY','INR','EGP','AED','GBP','CNY','VND')),
amount numeric(18,2) NOT NULL CHECK(amount>0),
issuer jsonb NOT NULL CHECK(jsonb_typeof(issuer)='object'),
recipient jsonb NOT NULL CHECK(jsonb_typeof(recipient)='object'),
reason text NOT NULL CHECK(length(trim(reason))>0),
notes text NOT NULL DEFAULT '',
created_by uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id),
updated_by uuid DEFAULT auth.uid() REFERENCES auth.users(id),
created_at timestamptz NOT NULL DEFAULT now(),
updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX aes_claim_notes_number ON public.aes_claim_notes(lower(note_number));
ALTER TABLE public.aes_claim_notes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.aes_claim_notes FROM anon,authenticated;
GRANT SELECT,INSERT,UPDATE ON public.aes_claim_notes TO authenticated;
CREATE POLICY claim_notes_read ON public.aes_claim_notes FOR SELECT TO authenticated USING(EXISTS(SELECT 1 FROM public.app_members m WHERE m.user_id=(select auth.uid()) AND m.active));
CREATE POLICY claim_notes_insert ON public.aes_claim_notes FOR INSERT TO authenticated WITH CHECK(created_by=(select auth.uid()) AND EXISTS(SELECT 1 FROM public.app_members m WHERE m.user_id=(select auth.uid()) AND m.active AND m.role IN('admin','operator')));
CREATE POLICY claim_notes_update ON public.aes_claim_notes FOR UPDATE TO authenticated USING(EXISTS(SELECT 1 FROM public.app_members m WHERE m.user_id=(select auth.uid()) AND m.active AND m.role IN('admin','operator'))) WITH CHECK(EXISTS(SELECT 1 FROM public.app_members m WHERE m.user_id=(select auth.uid()) AND m.active AND m.role IN('admin','operator')));
CREATE OR REPLACE FUNCTION public.aes_claim_note_stamp() RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
BEGIN
IF NEW.created_by IS DISTINCT FROM OLD.created_by OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN RAISE EXCEPTION 'Creation audit cannot change'; END IF;
NEW.updated_at=clock_timestamp();NEW.updated_by=auth.uid();RETURN NEW;
END $$;
CREATE TRIGGER aes_claim_note_stamp BEFORE UPDATE ON public.aes_claim_notes FOR EACH ROW EXECUTE FUNCTION public.aes_claim_note_stamp();