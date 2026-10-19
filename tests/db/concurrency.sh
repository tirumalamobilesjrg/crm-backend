#!/usr/bin/env bash
# Real concurrent transactions (separate connections). Verifies row locking, idempotency under a
# race, and invoice-number serialisation. Called by scripts/test-db.sh after the SQL tests.
set -euo pipefail

PSQL=(psql -X -q -At -v ON_ERROR_STOP=1)
[[ -n "${DATABASE_URL:-}" ]] && PSQL+=("$DATABASE_URL")
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SALES='a0000000-0000-0000-0000-000000000003'
MGR='a0000000-0000-0000-0000-000000000002'

record() { "${PSQL[@]}" -c "select set_config('t.file', 'concurrency', false); select t._record('concurrency: $1', $2, \$d\$$3\$d\$)" >/dev/null; }

# Setup: six fresh devices, received through the real RPC.
"${PSQL[@]}" -o /dev/null <<SQL
do \$\$
declare pur uuid; pi uuid; i int;
begin
  perform set_config('t.file', 'concurrency', false);
  perform t.as_user('a0000000-0000-0000-0000-000000000002');
  insert into public.purchases (supplier_id, supplier_invoice_no) values (t.fx('supplier'), 'INV-CONC-1') returning id into pur;
  insert into public.purchase_items (purchase_id, variant_id, quantity, unit_cost) values (pur, t.fx('v_published'), 6, 50000) returning id into pi;
  perform public.receive_purchase('conc-setup-recv', pur, (select jsonb_agg(jsonb_build_object('purchase_item_id', pi, 'imei1', t.imei(7000 + g))) from generate_series(1, 6) g));
  perform t.reset();
end \$\$;
SQL
item() { "${PSQL[@]}" -c "select id from public.inventory_items where imei1 = t.imei($1)"; }
I1=$(item 7001); I2=$(item 7002); I3=$(item 7003); I4=$(item 7004); I5=$(item 7005); I6=$(item 7006)

# One sale in one transaction; optional hold (seconds) before COMMIT keeps its locks held.
session() { # outfile user key item hold
  cat <<SQL | "${PSQL[@]}" > "$1" 2> "$1.err" || true
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"$2","role":"authenticated"}', true);
select public.finalize_sale('$3', null,
  '[{"inventory_item_id":"$4","unit_price":70000}]'::jsonb,
  '{"method":"cash","amount":70000}'::jsonb)::text;
select pg_sleep($5);
commit;
SQL
}

# A: two different submissions for the SAME device race; exactly one may win.
session "$WORK/a1" $SALES conc-a-key-0001 "$I1" 2 &
sleep 0.7
START=$(date +%s.%N)
session "$WORK/a2" $MGR conc-a-key-0002 "$I1" 0
END=$(date +%s.%N)
wait
WAITED=$(awk -v s="$START" -v e="$END" 'BEGIN{printf "%.2f", e - s}')
WIN=$(grep -c '"sale_id"' "$WORK/a1" "$WORK/a2" | awk -F: '{s+=$2} END{print s}')
record "two sales of one device: exactly one succeeds" "$([[ "$WIN" == 1 ]] && echo true || echo false)" "winners=$WIN"
record "loser is rejected as not available" "$(grep -q 'is not available' "$WORK/a2.err" && echo true || echo false)" "$(head -c 300 "$WORK/a2.err")"
record "loser waited for the winning transaction lock instead of racing" "$(awk -v w="$WAITED" 'BEGIN{print (w > 0.8) ? "true" : "false"}')" "waited=${WAITED}s"
SOLD=$("${PSQL[@]}" -c "select count(*) from public.sale_items where inventory_item_id = '$I1'")
record "the contested device appears in exactly one sale" "$([[ "$SOLD" == 1 ]] && echo true || echo false)" "sale_items=$SOLD"

# B: the SAME idempotency key submitted twice at once; one sale, second call replays.
session "$WORK/b1" $SALES conc-b-key-0001 "$I2" 2 &
sleep 0.7
session "$WORK/b2" $SALES conc-b-key-0001 "$I2" 0
wait
B1=$(grep -o '"sale_id": "[^"]*"' "$WORK/b1" | head -1 || true)
B2=$(grep -o '"sale_id": "[^"]*"' "$WORK/b2" | head -1 || true)
record "same key twice at once: both callers receive the same sale" "$([[ -n "$B1" && "$B1" == "$B2" ]] && echo true || echo false)" "b1=$B1 b2=$B2"
record "second concurrent caller is marked as a replay" "$(grep -q '"replayed": true' "$WORK/b2" && echo true || echo false)" "$(cat "$WORK/b2")"
NS=$("${PSQL[@]}" -c "select count(*) from public.sale_items where inventory_item_id = '$I2'")
record "same key twice at once: exactly one sale exists" "$([[ "$NS" == 1 ]] && echo true || echo false)" "sale_items=$NS"

# C: different devices at once; invoice numbers must be distinct and consecutive.
session "$WORK/c1" $SALES conc-c-key-0001 "$I3" 1.5 &
sleep 0.5
session "$WORK/c2" $MGR conc-c-key-0002 "$I4" 0
wait
N1=$(grep -o '"invoice_number": "[^"]*"' "$WORK/c1" | grep -o '[0-9]\{6\}"' | tr -d '"' || true)
N2=$(grep -o '"invoice_number": "[^"]*"' "$WORK/c2" | grep -o '[0-9]\{6\}"' | tr -d '"' || true)
record "concurrent sales get distinct, consecutive invoice numbers" \
  "$([[ -n "$N1" && -n "$N2" && $((10#$N2)) -eq $((10#$N1 + 1)) ]] && echo true || echo false)" "n1=$N1 n2=$N2"

# D: a session that dies mid-sale (rolled back) must not leave locks, rows or burned numbers.
SEQ_BEFORE=$("${PSQL[@]}" -c "select last_number from public.invoice_sequences order by fiscal_year desc limit 1")
cat <<SQL | "${PSQL[@]}" > /dev/null 2>&1 || true
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"$SALES","role":"authenticated"}', true);
select public.finalize_sale('conc-d-key-0001', null, '[{"inventory_item_id":"$I5","unit_price":70000}]'::jsonb, '{"method":"cash","amount":70000}'::jsonb);
rollback;
SQL
SEQ_AFTER=$("${PSQL[@]}" -c "select last_number from public.invoice_sequences order by fiscal_year desc limit 1")
ST=$("${PSQL[@]}" -c "select status from public.inventory_items where id = '$I5'")
KEYS=$("${PSQL[@]}" -c "select count(*) from public.idempotency_keys where idem_key = 'conc-d-key-0001'")
record "an aborted sale transaction leaves stock, invoice sequence and idempotency key untouched" \
  "$([[ "$ST" == in_stock && "$SEQ_BEFORE" == "$SEQ_AFTER" && "$KEYS" == 0 ]] && echo true || echo false)" "status=$ST seq=$SEQ_BEFORE/$SEQ_AFTER keys=$KEYS"

# generic helper: run arbitrary SQL as a signed-in user inside one transaction, optionally holding it open.
as_user_sql() { # outfile user hold sql
  cat <<SQL | "${PSQL[@]}" > "$1" 2> "$1.err" || true
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"$2","role":"authenticated"}', true);
$4
select pg_sleep($3);
commit;
SQL
}
OWNER='a0000000-0000-0000-0000-000000000001'
VC=$("${PSQL[@]}" -c "select t.fx('v_case')")

# E: two sellers each ask for most of an accessory SKU's stock at once; only one may get it.
ONHAND=$("${PSQL[@]}" -c "select on_hand from public.stock_levels where variant_id = '$VC'")
QTY=$((ONHAND - 1))
SALE_QTY="select public.finalize_sale('KEY', null, '[{\"variant_id\":\"$VC\",\"quantity\":$QTY,\"unit_price\":799}]'::jsonb, '{\"method\":\"cash\",\"amount\":$((QTY * 799))}'::jsonb)::text;"
as_user_sql "$WORK/e1" $SALES 2 "${SALE_QTY/KEY/conc-e-key-0001}" &
sleep 0.7
as_user_sql "$WORK/e2" $MGR 0 "${SALE_QTY/KEY/conc-e-key-0002}"
wait
EWIN=$(cat "$WORK/e1" "$WORK/e2" | grep -c '"sale_id"' || true)
AFTER=$("${PSQL[@]}" -c "select on_hand from public.stock_levels where variant_id = '$VC'")
record "concurrent accessory sales: exactly one gets the stock" "$([[ "$EWIN" == 1 ]] && echo true || echo false)" "winners=$EWIN"
record "the losing accessory sale is told stock is insufficient" "$(cat "$WORK/e1.err" "$WORK/e2.err" | grep -q 'insufficient stock' && echo true || echo false)" "$(cat "$WORK/e1.err" "$WORK/e2.err" | head -c 300)"
record "accessory stock is never oversold or negative after the race" "$([[ "$AFTER" == 1 ]] && echo true || echo false)" "before=$ONHAND after=$AFTER"

# F: one Admin-granted discount approval used by two sales at once; it can be consumed only once.
# the approval is for the accessory product, so the two sales below contest the approval (not a device); give the SKU enough stock first
"${PSQL[@]}" >/dev/null <<SQL
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"$OWNER","role":"authenticated"}', true);
select public.adjust_quantity_stock('conc-f-restock-1', '$VC', 10, 'found', 'restock for the approval race');
commit;
SQL
APPR=$("${PSQL[@]}" <<SQL
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"$OWNER","role":"authenticated"}', true);
select (public.grant_discount_approval('conc-f-grant-01', '$SALES', 3000, 'Concurrency test approval', 30, null, '$VC') ->> 'approval_id');
commit;
SQL
)
APPR=$(echo "$APPR" | grep -E '^[0-9a-f-]{36}$' | head -1)
sale_with_approval() { echo "select public.finalize_sale('$1', null, '[{\"variant_id\":\"$VC\",\"quantity\":2,\"unit_price\":799,\"discount_amount\":500}]'::jsonb, '{\"method\":\"cash\",\"amount\":1098}'::jsonb, null, 'Approval race', '$APPR')::text;"; }
as_user_sql "$WORK/f1" $SALES 2 "$(sale_with_approval conc-f-key-0001 "$I6")" &
sleep 0.7
as_user_sql "$WORK/f2" $SALES 0 "$(sale_with_approval conc-f-key-0002 "$I5")"   # different device: only the approval is contested
wait
FWIN=$(cat "$WORK/f1" "$WORK/f2" | grep -c '"sale_id"' || true)
USED=$("${PSQL[@]}" -c "select count(*) from public.discount_approvals where id = '$APPR' and used_in_sale_id is not null")
record "one approval cannot back two concurrent sales" "$([[ "$FWIN" == 1 && "$USED" == 1 ]] && echo true || echo false)" "winners=$FWIN used=$USED"
record "the second sale is refused because the approval was already used" "$(cat "$WORK/f1.err" "$WORK/f2.err" | grep -q 'already used' && echo true || echo false)" "$(cat "$WORK/f1.err" "$WORK/f2.err" | head -c 200)"

# G: two corrections racing to give different devices the same IMEI; exactly one succeeds.
NEWIMEI=$("${PSQL[@]}" -c "select t.imei(8888)")
D1=$("${PSQL[@]}" -c "select id from public.inventory_items where imei1 = t.imei(7004)")
D2=$("${PSQL[@]}" -c "select id from public.inventory_items where imei1 = t.imei(7005)")
CORR="select public.correct_item_identifiers('KEY', 'DEV', '{\"imei1\":\"$NEWIMEI\"}'::jsonb, 'Concurrency test: same IMEI to two devices')::text;"
c1="${CORR/KEY/conc-g-key-0001}"; c1="${c1/DEV/$D1}"
c2="${CORR/KEY/conc-g-key-0002}"; c2="${c2/DEV/$D2}"
as_user_sql "$WORK/g1" $OWNER 2 "$c1" &
sleep 0.7
as_user_sql "$WORK/g2" $OWNER 0 "$c2"
wait
GWIN=$(cat "$WORK/g1" "$WORK/g2" | grep -c 'correction_id' || true)
HOLD=$("${PSQL[@]}" -c "select count(*) from public.inventory_identifiers where value = '$NEWIMEI' and retired_at is null")
record "racing IMEI corrections: exactly one device ends up holding the IMEI" "$([[ "$GWIN" == 1 && "$HOLD" == 1 ]] && echo true || echo false)" "winners=$GWIN active_holders=$HOLD"
