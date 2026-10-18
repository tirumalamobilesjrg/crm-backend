-- 0010 new enum values. Kept in its own file: a value added by ALTER TYPE cannot be used in the same transaction.

alter type public.adjustment_reason add value if not exists 'correction';   -- stock-count correction for quantity SKUs

create type public.tracking_mode as enum ('serialized', 'quantity');
