ALTER TABLE public.aes_claim_notes ADD COLUMN IF NOT EXISTS order_details jsonb NOT NULL DEFAULT '{}' CHECK(jsonb_typeof(order_details)='object');
