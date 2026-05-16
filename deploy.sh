#!/bin/bash
# ================================================================
# 통합 배포 스크립트 (서비스 전체 + 백업 설정)
# 실행 방법: bash deploy.sh
#
# 이 스크립트 하나로:
#   1. Worker 노드 자동 감지 및 PV 설정
#   2. MetalLB 설치 및 설정
#   3. Ingress Controller 설치
#   4. Secret 배포 (MariaDB / Ceph / AWS)
#   5. Galera 클러스터 배포
#   6. DB 테이블 초기화
#   7. 마이크로서비스 및 프론트엔드 배포
#   8. 백업 Docker 이미지 빌드 & 푸시
#   9. 백업 CronJob 배포 (매일 새벽 2시 자동 실행)
#  10. 백업 즉시 테스트 실행 & 결과 확인
# ================================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
waiting() { echo -e "${YELLOW}[WAIT]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

BASEDIR=$(dirname "$(readlink -f "$0")")
K8S_DIR="$BASEDIR/k8s"
IMAGE="kwsumin01/photo-backup:v1"

echo "=================================================================="
echo " 통합 클러스터 배포 스크립트 (Galera + 마이크로서비스 + 백업)"
echo "[INFO] 배포 시작 위치: $BASEDIR"
echo "=================================================================="

# ================================================================
# STEP 1. Worker 노드 자동 감지 및 PV 설정
# ================================================================
echo ""
echo "[STEP 1] Worker 노드 감지 및 PV YAML 수정 중..."
WORKER_NODE=$(kubectl get nodes --no-headers | grep -v control-plane | awk '{print $1}' | head -1)

if [ -z "$WORKER_NODE" ]; then
  error "Worker 노드를 찾을 수 없습니다. 클러스터 상태를 확인하세요."
fi

info "감지된 Worker 노드: $WORKER_NODE"
sed -i "s/\"test-worker[0-9]*\"/\"$WORKER_NODE\"/g" "$K8S_DIR/galera/01-galera-pv.yaml"
info "$K8S_DIR/galera/01-galera-pv.yaml 수정 완료"

# ================================================================
# STEP 2. MetalLB 설치 및 설정
# ================================================================
echo ""
echo "[STEP 2] MetalLB 설치 중..."
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.5/config/manifests/metallb-native.yaml

waiting "MetalLB Pod Ready 대기 중..."
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=120s

cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: first-pool
  namespace: metallb-system
spec:
  addresses:
  - 172.17.128.240-172.17.128.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: example
  namespace: metallb-system
spec:
  ipAddressPools:
  - first-pool
EOF

if [ -f "$K8S_DIR/metallb-config.yaml" ]; then
  kubectl apply -f "$K8S_DIR/metallb-config.yaml"
fi
info "MetalLB 설치 및 설정 완료"

# ================================================================
# STEP 3. Ingress Controller 설치
# ================================================================
echo ""
echo "[STEP 3] Ingress Controller 설치 중..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.0/deploy/static/provider/baremetal/deploy.yaml

waiting "Ingress Controller Ready 대기 중..."
sleep 10
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s

kubectl patch svc ingress-nginx-controller -n ingress-nginx \
  -p '{"spec": {"type": "LoadBalancer"}}'
info "Ingress Controller 설치 완료"

# ================================================================
# STEP 4. Secret 배포 (MariaDB / Ceph / AWS)
# ================================================================
echo ""
echo "[STEP 4] Secret 배포 중..."
kubectl apply -f "$K8S_DIR/01-secret.yaml"
kubectl apply -f "$K8S_DIR/backup/00-aws-secret.yaml"
info "Secret 배포 완료 (mariadb-secret, ceph-secret, aws-secret)"

# ================================================================
# STEP 5. Galera 클러스터 배포
# ================================================================
echo ""
echo "[STEP 5] Galera 클러스터 리소스 배포 중..."

# Released 상태의 PV 자동 정리 (재배포 시 PVC 바인딩 실패 방지)
for pv in galera-pv-0 galera-pv-1 galera-pv-2; do
  PHASE=$(kubectl get pv "$pv" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
  if [[ "$PHASE" == "Released" ]]; then
    info "PV $pv Released 상태 감지 → 재생성 중..."
    kubectl delete pv "$pv" --ignore-not-found
  fi
done

kubectl apply -f "$K8S_DIR/galera/00-galera-configmap.yaml"
kubectl apply -f "$K8S_DIR/galera/01-galera-pv.yaml"
kubectl apply -f "$K8S_DIR/galera/03-galera-services.yaml"
kubectl apply -f "$K8S_DIR/galera/02-galera-statefulset.yaml"

waiting "Galera 클러스터 파드가 모두 준비될 때까지 대기합니다 (최대 5분)..."
kubectl rollout status statefulset/galera --timeout=300s
info "Galera 클러스터 배포 완료"

# ================================================================
# STEP 6. DB 테이블 초기화
# ================================================================
echo ""
echo "[STEP 6] DB 테이블 생성 중..."
waiting "galera-0 Pod Ready 재확인..."
kubectl wait --for=condition=ready pod/galera-0 --timeout=180s

kubectl cp "$BASEDIR/employee_server/database_create_tables.sql" galera-0:/tmp/init.sql
kubectl exec -it galera-0 -- mysql -u root -pkosa1004 employees -e "source /tmp/init.sql"
info "DB 테이블 생성 완료"

# ================================================================
# STEP 7. 마이크로서비스 및 프론트엔드 배포
# ================================================================
echo ""
echo "[STEP 7] 마이크로서비스 및 프론트엔드 배포 중..."
kubectl apply -f "$K8S_DIR/07-auth-server.yaml"
kubectl apply -f "$K8S_DIR/08-employee-server.yaml"
kubectl apply -f "$K8S_DIR/09-photo-service.yaml"
kubectl apply -f "$K8S_DIR/10-gateway.yaml"
kubectl apply -f "$K8S_DIR/11-nginx-deployment.yaml"
kubectl apply -f "$K8S_DIR/12-nginx-service.yaml"
kubectl apply -f "$K8S_DIR/13-ingress.yaml"
info "어플리케이션 배포 완료"

# ================================================================
# STEP 8. 백업 Docker 이미지 빌드 & 푸시
# ================================================================
echo ""
echo "[STEP 8] 백업 Docker 이미지 빌드 중..."
docker build -t "$IMAGE" "$BASEDIR/backup/" \
  || error "이미지 빌드 실패. Docker가 설치되어 있는지 확인하세요."

info "Docker Hub에 푸시 중..."
docker push "$IMAGE" \
  || error "이미지 푸시 실패. 'docker login' 으로 로그인 후 재시도하세요."

info "이미지 빌드 & 푸시 완료: $IMAGE"

# ================================================================
# STEP 9. 백업 CronJob 배포
# ================================================================
echo ""
echo "[STEP 9] 백업 CronJob 배포 중... (매일 새벽 2시 자동 실행)"
kubectl apply -f "$K8S_DIR/backup/01-backup-cronjob.yaml"
info "CronJob 배포 완료"
kubectl get cronjob photo-backup

# ================================================================
# STEP 10. 백업 즉시 테스트 실행
# ================================================================
echo ""
echo "[STEP 10] 백업 테스트 Job 실행 중..."

kubectl delete pod backup-test --ignore-not-found > /dev/null 2>&1
sleep 2

kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: backup-test
spec:
  restartPolicy: Never
  containers:
  - name: backup
    image: $IMAGE
    env:
    - name: DATABASE_HOST
      value: mysql
    - name: DATABASE_USER
      value: root
    - name: DATABASE_DB_NAME
      value: employees
    envFrom:
    - secretRef:
        name: ceph-secret
    - secretRef:
        name: mariadb-secret
    - secretRef:
        name: aws-secret
EOF

waiting "백업 실행 중... (최대 3분)"
kubectl wait --for=condition=Ready pod/backup-test --timeout=60s \
  || error "Pod 시작 실패. 'kubectl describe pod backup-test' 로 원인 확인"

for i in {1..36}; do
  PHASE=$(kubectl get pod backup-test -o jsonpath='{.status.phase}' 2>/dev/null)
  if [[ "$PHASE" == "Succeeded" ]]; then
    break
  elif [[ "$PHASE" == "Failed" ]]; then
    echo ""
    kubectl logs backup-test
    kubectl delete pod backup-test --ignore-not-found > /dev/null 2>&1
    error "백업 실패. 위 로그를 확인하세요."
  fi
  waiting "  진행 중... ($i/36)"
  sleep 5
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "백업 실행 결과"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
kubectl logs backup-test
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
info "DB 백업 상태 확인"
kubectl exec galera-0 -- \
  mysql -u root -pkosa1004 -e \
  "SELECT id, full_name, backup_status FROM employees.employee;" \
  2>/dev/null

kubectl delete pod backup-test --ignore-not-found > /dev/null 2>&1

# ================================================================
# 최종 결과 확인
# ================================================================
echo ""
echo "=================================================================="
echo " 전체 배포가 성공적으로 완료되었습니다!"
echo "=================================================================="
echo ""
echo "[현재 Pod 상태]"
kubectl get pod
echo ""
echo "[Ingress 서비스 (EXTERNAL-IP 확인)]"
kubectl get svc -n ingress-nginx ingress-nginx-controller
echo ""
echo "[백업 CronJob 상태]"
kubectl get cronjob photo-backup
echo ""
info "EXTERNAL-IP가 할당되면 브라우저를 띄울 PC의 /etc/hosts 에 아래 내용을 추가하세요:"
echo "<EXTERNAL-IP>  myapp.local"
echo ""
info "자동 백업: 매일 새벽 2시 실행"
info "수동 백업: kubectl create job backup-now --from=cronjob/photo-backup"
info "실행 이력: kubectl get jobs | grep photo-backup"
echo "=================================================================="
