ALTER TABLE public.aes_claim_notes ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'pending' CHECK(status IN('pending','sent','paid','cancelled'));
