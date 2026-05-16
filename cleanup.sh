#!/bin/bash
# ================================================================
# 전체 초기화 스크립트 (deploy.sh 로 배포한 모든 리소스 제거)
# 실행 방법: bash cleanup.sh
# ================================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
waiting() { echo -e "${YELLOW}[WAIT]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }

BASEDIR=$(dirname "$(readlink -f "$0")")
K8S_DIR="$BASEDIR/k8s"

echo "=================================================================="
echo " 전체 클러스터 초기화 스크립트"
echo "=================================================================="
echo ""
warn "이 스크립트는 deploy.sh 로 배포한 모든 리소스를 삭제합니다."
warn "Galera DB 데이터(PV)도 함께 삭제됩니다."
echo ""
read -rp "계속 진행하시겠습니까? (yes 입력 시 진행): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
  echo "취소되었습니다."
  exit 0
fi

# ================================================================
# STEP 1. 백업 리소스 정리
# ================================================================
echo ""
echo "[STEP 1] 백업 리소스 정리 중..."

info "  테스트 Pod 삭제..."
kubectl delete pod backup-test --ignore-not-found > /dev/null 2>&1

info "  백업 Job 전체 삭제..."
kubectl get jobs --no-headers 2>/dev/null \
  | awk '/photo-backup/{print $1}' \
  | xargs -r kubectl delete job --ignore-not-found > /dev/null 2>&1 || true

info "  백업 CronJob 삭제..."
kubectl delete -f "$K8S_DIR/backup/01-backup-cronjob.yaml" --ignore-not-found > /dev/null 2>&1

info "  AWS Secret 삭제..."
kubectl delete -f "$K8S_DIR/backup/00-aws-secret.yaml" --ignore-not-found > /dev/null 2>&1

info "백업 리소스 정리 완료"

# ================================================================
# STEP 2. 마이크로서비스 및 프론트엔드 삭제
# ================================================================
echo ""
echo "[STEP 2] 마이크로서비스 및 프론트엔드 삭제 중..."
kubectl delete -f "$K8S_DIR/13-ingress.yaml"          --ignore-not-found > /dev/null 2>&1
kubectl delete -f "$K8S_DIR/12-nginx-service.yaml"    --ignore-not-found > /dev/null 2>&1
kubectl delete -f "$K8S_DIR/11-nginx-deployment.yaml" --ignore-not-found > /dev/null 2>&1
kubectl delete -f "$K8S_DIR/10-gateway.yaml"          --ignore-not-found > /dev/null 2>&1
kubectl delete -f "$K8S_DIR/09-photo-service.yaml"    --ignore-not-found > /dev/null 2>&1
kubectl delete -f "$K8S_DIR/08-employee-server.yaml"  --ignore-not-found > /dev/null 2>&1
kubectl delete -f "$K8S_DIR/07-auth-server.yaml"      --ignore-not-found > /dev/null 2>&1
info "마이크로서비스 삭제 완료"

# ================================================================
# STEP 3. Galera 클러스터 삭제
# ================================================================
echo ""
echo "[STEP 3] Galera 클러스터 삭제 중..."

info "  StatefulSet 삭제..."
kubectl delete -f "$K8S_DIR/galera/02-galera-statefulset.yaml" --ignore-not-found > /dev/null 2>&1

waiting "  Pod 종료 대기 중..."
kubectl wait --for=delete pod/galera-0 pod/galera-1 pod/galera-2 \
  --timeout=60s 2>/dev/null || true

info "  Service 삭제..."
kubectl delete -f "$K8S_DIR/galera/03-galera-services.yaml" --ignore-not-found > /dev/null 2>&1

info "  PVC 삭제..."
for pvc in data-galera-0 data-galera-1 data-galera-2; do
  kubectl patch pvc "$pvc" -p '{"metadata":{"finalizers":null}}' --ignore-not-found > /dev/null 2>&1 || true
  kubectl delete pvc "$pvc" --ignore-not-found > /dev/null 2>&1 || true
done

info "  PV 삭제..."
for pv in galera-pv-0 galera-pv-1 galera-pv-2; do
  kubectl patch pv "$pv" -p '{"metadata":{"finalizers":null}}' --ignore-not-found > /dev/null 2>&1 || true
  kubectl delete pv "$pv" --ignore-not-found > /dev/null 2>&1 || true
done

info "  ConfigMap 삭제..."
kubectl delete -f "$K8S_DIR/galera/00-galera-configmap.yaml" --ignore-not-found > /dev/null 2>&1

info "Galera 클러스터 삭제 완료"

# ================================================================
# STEP 4. Secret 삭제
# ================================================================
echo ""
echo "[STEP 4] Secret 삭제 중..."
kubectl delete -f "$K8S_DIR/01-secret.yaml" --ignore-not-found > /dev/null 2>&1
info "Secret 삭제 완료"

# ================================================================
# STEP 5. Ingress Controller 삭제
# ================================================================
echo ""
echo "[STEP 5] Ingress Controller 삭제 중..."
kubectl delete -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.0/deploy/static/provider/baremetal/deploy.yaml \
  --ignore-not-found > /dev/null 2>&1
info "Ingress Controller 삭제 완료"

# ================================================================
# STEP 6. MetalLB 삭제
# ================================================================
echo ""
echo "[STEP 6] MetalLB 삭제 중..."
kubectl delete ipaddresspool first-pool -n metallb-system --ignore-not-found > /dev/null 2>&1
kubectl delete l2advertisement example -n metallb-system --ignore-not-found > /dev/null 2>&1
kubectl delete -f https://raw.githubusercontent.com/metallb/metallb/v0.14.5/config/manifests/metallb-native.yaml \
  --ignore-not-found > /dev/null 2>&1
info "MetalLB 삭제 완료"

# ================================================================
# 최종 상태 확인
# ================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "초기화 완료"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
# node-debugger Pod 정리
kubectl delete pod -l app=node-debugger --ignore-not-found > /dev/null 2>&1 || true
kubectl get pods --no-headers 2>/dev/null | awk '/node-debugger/{print $1}' \
  | xargs -r kubectl delete pod --ignore-not-found > /dev/null 2>&1 || true

echo "[현재 Pod 상태]"
kubectl get pod 2>/dev/null || echo "  (Pod 없음)"
echo ""
echo "[현재 PV 상태]"
kubectl get pv 2>/dev/null || echo "  (PV 없음)"
echo ""
info "다시 배포하려면: bash deploy.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
