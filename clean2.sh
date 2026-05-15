#!/bin/bash

# 1. 스크립트 위치 절대 경로 계산
BASEDIR=$(dirname "$(readlink -f "$0")")
K8S_DIR="$BASEDIR/k8s"

echo "=================================================================="
echo " 🧹 통합 클러스터 초기화 스크립트 "
echo "[INFO] 초기화 시작 위치: $BASEDIR"
echo "=================================================================="

# 2. 어플리케이션 및 네트워크 리소스 삭제
echo "[INFO] [1/5] 프론트엔드 및 네트워크(Ingress) 리소스 삭제 중..."
kubectl delete -f "$K8S_DIR/13-ingress.yaml" --ignore-not-found
kubectl delete -f "$K8S_DIR/12-nginx-service.yaml" --ignore-not-found
kubectl delete -f "$K8S_DIR/11-nginx-deployment.yaml" --ignore-not-found

echo "[INFO] [2/5] 마이크로서비스(백엔드) 리소스 삭제 중..."
kubectl delete -f "$K8S_DIR/10-gateway.yaml" --ignore-not-found
kubectl delete -f "$K8S_DIR/09-photo-service.yaml" --ignore-not-found
kubectl delete -f "$K8S_DIR/08-employee-server.yaml" --ignore-not-found
kubectl delete -f "$K8S_DIR/07-auth-server.yaml" --ignore-not-found

# 3. 데이터베이스 (Galera) 리소스 삭제
echo "[INFO] [3/5] Galera 클러스터(StatefulSet, Service, ConfigMap) 삭제 중..."
kubectl delete -f "$K8S_DIR/galera/02-galera-statefulset.yaml" --ignore-not-found
kubectl delete -f "$K8S_DIR/galera/03-galera-services.yaml" --ignore-not-found
kubectl delete -f "$K8S_DIR/galera/00-galera-configmap.yaml" --ignore-not-found

# 4. Secret 삭제
echo "[INFO] [4/5] Secret(데이터베이스/스토리지 키) 삭제 중..."
kubectl delete secret mariadb-secret ceph-secret --ignore-not-found

# 5. 스토리지 (PVC & PV) 삭제
echo "[INFO] [5/5] 볼륨(PVC, PV) 리소스 삭제 중..."
# StatefulSet에 의해 동적 생성된 PVC는 이름으로 직접 삭제
kubectl delete pvc data-galera-0 data-galera-1 data-galera-2 --ignore-not-found
kubectl delete -f "$K8S_DIR/galera/01-galera-pv.yaml" --ignore-not-found

# 6. MetalLB 설정 삭제 (선택적)
if [ -f "$K8S_DIR/metallb-config.yaml" ]; then
    echo "[INFO] MetalLB 추가 Config 삭제 중..."
    kubectl delete -f "$K8S_DIR/metallb-config.yaml" --ignore-not-found
fi
# start.sh에서 동적으로 적용한 IP Pool 삭제
kubectl delete ipaddresspool first-pool -n metallb-system --ignore-not-found
kubectl delete l2advertisement example -n metallb-system --ignore-not-found

echo "=================================================================="
echo " [SUCCESS] K8s 리소스가 모두 삭제되었습니다!"
echo "=================================================================="
echo ""
echo "🚨 [매우 중요: CrashLoopBackOff 방지] 🚨"
echo "다시 start.sh를 실행하시기 전에 반드시 워커 노드에 접속하여"
echo "디스크에 남아있는 기존 DB 파일들을 직접 지워주셔야 합니다."
echo ""
echo "복사해서 워커 노드에서 실행하세요:"
echo "sudo rm -rf /mnt/data/galera/node0/* /mnt/data/galera/node1/* /mnt/data/galera/node2/*"
echo "=================================================================="
