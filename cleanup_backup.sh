#!/bin/bash
# ================================================================
# Ceph → AWS S3 백업 설정 제거 스크립트
# 실행 방법: bash cleanup_backup.sh
# ================================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
waiting() { echo -e "${YELLOW}[WAIT]${NC} $1"; }

BASEDIR=$(dirname "$(readlink -f "$0")")

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "백업 리소스 정리 시작"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 1. 테스트 Pod 삭제 ───────────────────────────────────────────
info "[1/4] 테스트 Pod 삭제..."
kubectl delete pod backup-test --ignore-not-found
info "완료"

# ── 2. CronJob에서 생성된 Job 전체 삭제 ─────────────────────────
info "[2/4] 백업 Job 전체 삭제..."
kubectl delete jobs -l job-name --ignore-not-found > /dev/null 2>&1 || true
# photo-backup 이름이 포함된 Job 삭제
kubectl get jobs --no-headers 2>/dev/null \
  | awk '/photo-backup/{print $1}' \
  | xargs -r kubectl delete job --ignore-not-found
info "완료"

# ── 3. CronJob 삭제 ─────────────────────────────────────────────
info "[3/4] CronJob 삭제..."
kubectl delete -f "$BASEDIR/k8s/backup/01-backup-cronjob.yaml" --ignore-not-found
info "완료"

# ── 4. AWS Secret 삭제 ──────────────────────────────────────────
info "[4/4] AWS Secret 삭제..."
kubectl delete -f "$BASEDIR/k8s/backup/00-aws-secret.yaml" --ignore-not-found
info "완료"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "정리 완료"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
info "현재 K8s 리소스 상태:"
kubectl get pod,job,cronjob,secret | grep -E "backup|aws-secret" || echo "  (백업 관련 리소스 없음)"
echo ""
info "다시 설정하려면: bash setup_backup.sh"
