ALTER TABLE public.aes_claim_notes ADD COLUMN IF NOT EXISTS bank_details jsonb NOT NULL DEFAULT '{}' CHECK(jsonb_typeof(bank_details)='object');
