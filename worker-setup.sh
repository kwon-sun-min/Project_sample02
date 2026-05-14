#!/bin/bash
set -e

echo "========================================="
echo "  Worker 노드 설정 스크립트"
echo "========================================="

echo ""
echo "[STEP 1] 디렉토리 생성 중..."
sudo mkdir -p /mnt/data/mariadb
sudo chmod 777 /mnt/data/mariadb

echo ""
echo "========================================="
echo "  ✅ Worker 설정 완료!"
echo "========================================="
ls -la /mnt/data/