#!/bin/bash
# Usage: ./scripts/smoke-test.sh v2.0   -> tests Green through the :8080 test listener
set -uo pipefail
source ~/bg.env
EXPECTED=$1; URL="http://$ALB_DNS:8080"; FAIL=0
pass(){ echo "PASS  $1"; }; fail(){ echo "FAIL  $1"; FAIL=1; }

CODE=$(curl -s -o /dev/null -w '%{http_code}' $URL/health)
[ "$CODE" = 200 ] && pass "/health returns 200" || fail "/health returned $CODE"

curl -s $URL/ | grep -q "Version: $EXPECTED" && pass "Green serves $EXPECTED" || fail "Green not serving $EXPECTED"
curl -s $URL/ | grep -q "Environment: GREEN" && pass "Test listener routes only to Green" || fail "Test listener hit wrong env"

OK=$(for i in $(seq 50); do curl -s -o /dev/null -w '%{http_code}\n' $URL/; done | grep -c 200)
[ "$OK" -eq 50 ] && pass "50/50 requests returned 200" || fail "only $OK/50 requests returned 200"

T=$(for i in $(seq 20); do curl -s -o /dev/null -w '%{time_total}\n' $URL/; done | awk '{s+=$1} END {printf "%.3f", s/NR}')
awk -v t=$T 'BEGIN{exit !(t<0.5)}' && pass "avg latency ${T}s < 0.5s" || fail "avg latency ${T}s too high"

BAD=$(aws elbv2 describe-target-health --target-group-arn $TG_GREEN --query 'length(TargetHealthDescriptions[?TargetHealth.State!=`healthy`])' --output text)
[ "$BAD" = 0 ] && pass "all Green targets healthy" || fail "$BAD Green target(s) unhealthy"

curl -s http://$ALB_DNS/ | grep -q "Environment: BLUE" && pass "Production :80 still on Blue (isolation)" || fail "Production not on Blue"

[ $FAIL = 0 ] && echo "SMOKE TEST PASSED - safe to shift traffic" || echo "SMOKE TEST FAILED - do NOT shift traffic"
exit $FAIL
