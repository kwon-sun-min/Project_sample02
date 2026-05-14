# Hot/Warm/Cold Data 분리 하기 위해 파일 관리 테이블 수정

## 1. 핵심 개념

| Tier | 의미        | 저장소            |
| ---- | --------- | -------------- |
| Hot  | 자주 접근     | Ceph RGW       |
| Warm | 가끔 접근     | Ceph RGW/AWS   |
| Cold | 거의 접근 안 함 | AWS S3/Glacier |


위 기능을 구현하기 위해 첨부 파일 관리 테이블에 아래 항목 추가합니다 

| 컬럼             | 설명         |
| ---------------- | ---------    |
| object_key       | 파일명       |
| storage_type     | ceph/aws     |
| backup_status    | backup 여부  |
| upload_time      | 업로드 시간  |
| last_access_time | 마지막 접근  |


## 테이블 필드 추가

MySQL 기준으로 다음과 같이 추가하세요:

```bash
docker compose exec -it db bash

mysql -u root -p
#비밀번호입력 :

use employees;

ALTER TABLE employee
ADD COLUMN storage_type NVARCHAR(50) DEFAULT 'ceph' NULL COMMENT 'ceph/aws',
ADD COLUMN backup_status TINYINT(1) DEFAULT 0 COMMENT 'backup 여부',
ADD COLUMN upload_time DATETIME NULL COMMENT '업로드 시간',
ADD COLUMN last_access_time DATETIME DEFAULT now() COMMENT '마지막 접근';


# 이전에 등록된 자료 last_access_time을 2026-04-20으로 수정 
# 1주일 이전 자료를 aws s3로 이관 한다
update employee set  storage_type='ceph', backup_status=0, last_access_time='2026-04-20';

```

### 컬럼 설명 설계 의도

* `storage_type`

  * `ceph` / `aws` 같은 저장소 구분
* `backup_status`

  * 0 = 미백업, 1 = 백업 완료 (bool처럼 사용)
* `upload_time`

  * 파일 또는 데이터 최초 업로드 시각
* `last_access_time`

  * 최근 조회/사용 시각

---



## 2. models.py 수정

```python
from datetime import datetime
from typing import Optional, List
from sqlmodel import Field, SQLModel
from pydantic import BaseModel


class Employee(SQLModel, table=True):
    id: Optional[int] = Field(default=None, primary_key=True)
    object_key: Optional[str] = Field(default=None, max_length=80)

    full_name: str = Field(max_length=200)
    location: str = Field(max_length=200)
    job_title: str = Field(max_length=200)
    badges: str = Field(max_length=200)

    created_datetime: datetime = Field(default_factory=datetime.now)

    # =========================
    # ✅ 신규 추가 필드
    # =========================
    storage_type: Optional[str] = Field(default="ceph", max_length=50)
    backup_status: int = Field(default=0)  # 0: false, 1: true
    upload_time: Optional[datetime] = None
    last_access_time: Optional[datetime] = None

    class Config:
        json_encoders = {
            datetime: lambda dt: dt.isoformat()
        }


class EmployeePublic(BaseModel):
    id: int
    object_key: Optional[str] = None

    full_name: str
    location: str
    job_title: str
    badges: str

    photo_url: Optional[str] = None

    # =========================
    # public에도 추가 (조회용)
    # =========================
    storage_type: Optional[str] = None
    backup_status: int = 0
    upload_time: Optional[datetime] = None
    last_access_time: Optional[datetime] = None

    class Config:
        from_attributes = True


EmployeesListResponse = List[EmployeePublic]
```

---

## 3. 상세조회 시 last_access_time 자동 갱신

### 📌 핵심 포인트

* GET /employee/{id} 호출 시
* DB의 last_access_time = now() 업데이트

---

### application.py, database.py 에 datetime 패키지 추가


```python
from datetime import datetime
```

### database.py  파일 수정

load_employee 함수 수정 (중요)

```python
def load_employee(employee_id: int) -> Optional[Employee]:
    """Select one the employee from DB and update last_access_time."""
    with Session(engine) as session:
        employee = session.get(Employee, employee_id)

        if employee:
            # 접근 시간 업데이트 추가
            employee.last_access_time = datetime.now()
            session.add(employee)
            session.commit()
            session.refresh(employee)

        return employee
```

---

### application.py 수정
 
save_employee 함수 (POST)에도 신규 필드 반영

```python
employee_data = Employee(
    id=employee_id,
    object_key=key,
    full_name=full_name,
    location=location,
    job_title=job_title,
    badges=badges,

    # =========================
    # 신규 필드 초기값
    # =========================
    storage_type="ceph",   # 기본값 (원하면 aws로 변경)
    backup_status=0,
    upload_time=datetime.now() if key else None,
    last_access_time=datetime.now()
)
```
---

## 13. 실행

```bash
docker compose up -d

# ip 주소 확인 
ip a
```

## 14. 실행 결과 확인

```bash
윈도우 브라우저 실행 후 
주소창에 http://client 서버의 ip:8080 으로 접속하여 직원 정보를 등록한다


```

## 15. DB 실행 결과 확인

```bash
docker compose exec -it db bash

mysql -u root -p

select * from  employees.employee;

#웹 브라우저에서 신규 등록시 storage_type(ceph),  backup_status(0), upload_time(현재시간), last_access_time(현재시간) 기본 입력이 잘되는지 확인 합니다 
#웹 브라우저에서 edit를 버튼을 눌럿을 때 last_access_time(현재 시간)으로 변경되는지 확인 합니다 


```

