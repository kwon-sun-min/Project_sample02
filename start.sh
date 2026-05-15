#!/bin/bash

# 1. 스크립트가 위치한 절대 경로를 계산 (어디서 실행하든 이 경로가 기준이 됨)
BASEDIR=$(dirname "$(readlink -f "$0")")
K8S_DIR="$BASEDIR/k8s"

echo "=================================================================="
echo "[INFO] 배포 시작 위치: $BASEDIR"
echo "=================================================================="

# 2. Secret 배포 (Idempotent: 이미 존재하면 덮어쓰거나 통과)
echo "[INFO] [1/7] Secret 배포..."
kubectl create secret generic mariadb-secret \
  --from-literal=MYSQL_ROOT_PASSWORD=rootpassword \
  --from-literal=MYSQL_PASSWORD=password \
  --from-literal=MYSQL_DATABASE=employees \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic ceph-secret \
  --from-literal=CEPH_KEY=mycephkey \
  --dry-run=client -o yaml | kubectl apply -f -

# 3. Galera 클러스터 기반 리소스 배포
echo "[INFO] [2/7] Galera ConfigMap 및 PV/PVC 배포..."
kubectl apply -f "$K8S_DIR/galera/00-galera-configmap.yaml"
kubectl apply -f "$K8S_DIR/galera/01-galera-pv.yaml"

echo "[INFO] [3/7] Galera Service 및 StatefulSet 배포..."
kubectl apply -f "$K8S_DIR/galera/03-galera-services.yaml"
kubectl apply -f "$K8S_DIR/galera/02-galera-statefulset.yaml"

# 4. Galera 파드 기동 대기 (선택 사항, 안정적인 K8s 배포를 위해 권장)
echo "[WAIT] Galera 클러스터 파드가 모두 준비될 때까지 대기합니다..."
kubectl rollout status statefulset/galera --timeout=300s

# 5. 백엔드 서비스 배포
echo "[INFO] [5/7] 마이크로서비스(백엔드) 배포..."
kubectl apply -f "$K8S_DIR/07-auth-server.yaml"
kubectl apply -f "$K8S_DIR/08-employee-server.yaml"
kubectl apply -f "$K8S_DIR/09-photo-service.yaml"
kubectl apply -f "$K8S_DIR/10-gateway.yaml"

# 6. 프론트엔드 배포
echo "[INFO] [6/7] Frontend(Nginx) 배포..."
kubectl apply -f "$K8S_DIR/11-nginx-deployment.yaml"
kubectl apply -f "$K8S_DIR/12-nginx-service.yaml"

# 7. 네트워크 및 Ingress 배포
echo "[INFO] [7/7] 네트워크(MetalLB, Ingress) 배포..."
if [ -f "$K8S_DIR/metallb-config.yaml" ]; then
    kubectl apply -f "$K8S_DIR/metallb-config.yaml"
fi
kubectl apply -f "$K8S_DIR/13-ingress.yaml"

echo "=================================================================="
echo "[SUCCESS] 모든 리소스 배포 명령이 성공적으로 전달되었습니다!"
echo "진행 상태를 확인하려면 다음 명령어를 입력하세요: kubectl get pods -w"
echo "=================================================================="
