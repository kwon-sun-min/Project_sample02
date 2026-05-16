#!/bin/bash
# ================================================================
# Ceph → AWS S3 백업 설정 스크립트
# 실행 방법: bash setup_backup.sh
#
# 이 스크립트 하나로:
#   1. Docker 이미지 빌드 & 푸시
#   2. AWS Secret 배포
#   3. CronJob 배포 (매일 새벽 2시 자동 실행)
#   4. 즉시 테스트 실행 & 결과 확인
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
IMAGE="kwsumin01/photo-backup:v1"

# ================================================================
# STEP 1. Docker 이미지 빌드 & 푸시
# ================================================================
info "[1/4] Docker 이미지 빌드 중..."
docker build -t "$IMAGE" "$BASEDIR/backup/" \
  || error "이미지 빌드 실패. Docker가 설치되어 있는지 확인하세요."

info "[1/4] Docker Hub에 푸시 중..."
docker push "$IMAGE" \
  || error "이미지 푸시 실패. 'docker login' 으로 로그인 후 재시도하세요."

info "이미지 빌드 & 푸시 완료: $IMAGE"

# ================================================================
# STEP 2. AWS Secret 배포
# ================================================================
info "[2/4] AWS Secret 배포 중..."
kubectl apply -f "$BASEDIR/k8s/backup/00-aws-secret.yaml"
info "AWS Secret 배포 완료"

# ================================================================
# STEP 3. CronJob 배포
# ================================================================
info "[3/4] CronJob 배포 중... (매일 새벽 2시 자동 실행)"
kubectl apply -f "$BASEDIR/k8s/backup/01-backup-cronjob.yaml"
info "CronJob 배포 완료"
kubectl get cronjob photo-backup

# ================================================================
# STEP 4. 즉시 테스트 실행
# ================================================================
info "[4/4] 테스트 Job 실행 중..."

# 이전 테스트 Pod 정리
kubectl delete pod backup-test --ignore-not-found > /dev/null 2>&1
sleep 2

# 테스트 Pod 실행
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

# Pod 완료 대기
waiting "백업 실행 중... (최대 3분)"
kubectl wait --for=condition=Ready pod/backup-test --timeout=60s \
  || error "Pod 시작 실패. 'kubectl describe pod backup-test' 로 원인 확인"

# 완료될 때까지 대기 (Succeeded or Failed)
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

# 결과 출력
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "백업 실행 결과"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
kubectl logs backup-test
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# DB 백업 상태 확인
echo ""
info "DB 백업 상태 확인"
kubectl exec galera-0 -- \
  mysql -u root -pkosa1004 -e \
  "SELECT id, full_name, backup_status FROM employees.employee;" \
  2>/dev/null

# 테스트 Pod 정리
kubectl delete pod backup-test --ignore-not-found > /dev/null 2>&1

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "설정 완료"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "자동 백업: 매일 새벽 2시 실행"
info "수동 실행: kubectl create job backup-now --from=cronjob/photo-backup"
info "실행 이력: kubectl get jobs | grep photo-backup"
