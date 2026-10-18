# snowflake-dbt

Snowflake 위에서 dbt로 SQL 변환을 관리하고, 내부 GitLab CI로 검증·배포하는 프로젝트다.
원천 데이터는 사용자에게 닫아 두고, dbt가 만든 결과 객체만 조회용 롤에 열어 주는 구조를 검증하려고 만들었다.

## 구성 한눈에

```
원천 (SNOWFLAKE_SAMPLE_DATA, 사용자 접근 X)
   │  IMPORTED PRIVILEGES
   ▼
DBT_APP 롤  ← SVC_DBT 계정 (dbt가 접속)  ← GitLab CI (k8s Runner 파드)
   │  CREATE VIEW / TABLE / DYNAMIC TABLE
   ▼
DBT_PROD.MART  (결과 객체)
   │  SELECT (FUTURE 권한)
   ▼
DBT_USER 롤 (조회 전용, 사람 또는 앱 계정에 부여)
```

| 요소 | 값 | 역할 |
|---|---|---|
| dbt | 로컬 dbt-core 1.12.6 / dbt-snowflake 1.12.3, CI는 공식 이미지의 dbt 1.9 | SQL 모델 실행·테스트 |
| 원천 | `SNOWFLAKE_SAMPLE_DATA.TPCH_SF1` | Snowflake 샘플 데이터(공유 DB). 실제 원천은 아직 정하지 않았다 |
| 롤 `DBT_APP` | 원천 읽기 + 결과 생성 | dbt 애플리케이션이 쓰는 롤 |
| 롤 `DBT_USER` | 결과 조회만 | 사용자에게 여는 롤. 원천 권한이 없다 |
| 계정 `SVC_DBT` | `DBT_APP` 사용 | 로컬과 CI가 접속에 쓰는 비사람 계정 |
| 웨어하우스 `DBT_WH` | XSMALL, 60초 유휴 시 자동 중지 | dbt 실행과 조회에 공용 |
| 개발 DB `DBT_DEV` | 스키마 `DEV` | dbt가 스키마를 직접 만든다 |
| 운영 DB `DBT_PROD` | 스키마 `MART` | 관리자가 미리 만들고, dbt는 객체만 만든다 |
| CI | GitLab CI, k8s executor Runner | MR/`main`에서 검증, `main`에서 배포 |

## 저장소 구조

| 경로 | 내용 |
|---|---|
| `setup/00-teardown.sql` | dbt 관련 Snowflake 객체를 전부 지운다. 처음부터 다시 시작할 때 쓴다 |
| `setup/01-dbt-setup.sql` | 롤·웨어하우스·DB·권한·`SVC_DBT` 계정을 만든다 |
| `setup/02-materializations.sql` | 테이블·다이내믹 테이블을 쓰기 위한 추가 권한 |
| `profiles.yml` | 접속 정보. 비밀번호는 환경변수로만 받는다 |
| `dbt_project.yml` | 프로젝트 설정. 모델 기본 구체화 방식은 뷰 |
| `models/sources.yml` | 원천 정의와 원천 테스트 |
| `models/schema.yml` | 모델 테스트 |
| `models/demo/` | 모델 SQL. 구체화 방식별 비교 모델 4개와 `customer_orders` |
| `requirements.txt` | dbt 버전 고정 |
| `.gitlab-ci.yml` | 파이프라인 정의 |

## 1. 로컬 환경 준비

```bash
# 저장소로 이동
cd ~/gitlab/snowflake-dbt

# 가상환경 생성 및 활성화
python3 -m venv .venv && source .venv/bin/activate

# 고정된 버전으로 dbt 설치
pip install -r requirements.txt

# 설치 확인 (Core가 1.12.6이어야 한다)
dbt --version
```

버전을 고정한 이유는 로컬과 CI가 같은 버전을 쓰게 하려는 것이다. 처음에는 베타 버전(`1.13.0-b1`)이 설치되어 안정 버전으로 되돌렸다.

## 2. Snowflake 구성

Snowsight의 SQL Worksheet에서 `ACCOUNTADMIN`으로 `setup/01-dbt-setup.sql`을 실행한다. 파일의 `<% svc_dbt_password %>`는 직접 정한 비밀번호로 바꾼다. Snowflake CLI로 실행하면 `-D svc_dbt_password="..."`로 넘길 수 있다. 이어서 `setup/02-materializations.sql`을 실행한다.

### 만드는 객체와 권한

| 대상 | 권한 | 이유 |
|---|---|---|
| `DBT_APP` → 웨어하우스 `DBT_WH` | `USAGE` | 쿼리 실행 |
| `DBT_APP` → `SNOWFLAKE_SAMPLE_DATA` | `IMPORTED PRIVILEGES` | 공유 DB는 `USAGE`/`SELECT`를 따로 줄 수 없다 |
| `DBT_APP` → `DBT_DEV` | `USAGE`, `CREATE SCHEMA` | 개발 스키마를 dbt가 직접 만든다 |
| `DBT_APP` → `DBT_PROD.MART` | `USAGE`, `CREATE VIEW`, `CREATE TABLE`, `CREATE DYNAMIC TABLE` | 결과 객체 생성 |
| `DBT_USER` → `DBT_PROD`, `MART` | `USAGE` | 객체를 열어 본다 |
| `DBT_USER` → `MART` | `SELECT` on `FUTURE VIEWS` / `TABLES` / `DYNAMIC TABLES` | dbt가 객체를 다시 만들어도 권한이 자동으로 붙는다 |
| `SVC_DBT` | 롤 `DBT_APP` | 비사람 계정 |

### 설계 결정

- **원천은 `DBT_USER`에게 열지 않는다.** 뷰는 소유자(`DBT_APP`) 권한으로 실행된다. 사용자는 결과 객체 `SELECT`만 있으면 되고, 원천 권한이 없어도 조회된다.
- **운영 스키마는 관리자가 미리 만든다.** dbt가 스키마를 만들면 소유자가 `DBT_APP`이라 사용자 롤에 `USAGE`를 주려면 `DBT_APP`이 직접 부여해야 한다. 미리 만들면 `DBT_APP`은 `CREATE VIEW` 등 객체 생성 권한만 있으면 된다.
- **사용자 권한은 `FUTURE` 권한으로 준다.** dbt는 뷰를 `create or replace`로 다시 만들어서 객체 단위 권한은 사라진다. `FUTURE` 권한은 새로 만들어진 객체에 자동으로 다시 붙는다.
- **관리자 세션에서 보려면 커스텀 롤을 `SYSADMIN` 아래에 부여한다.** `GRANT ROLE DBT_APP TO ROLE SYSADMIN`, `GRANT ROLE DBT_USER TO ROLE SYSADMIN`을 검증 중에 안내했다. 두 줄은 `01-dbt-setup.sql`에 아직 넣지 않았다.
- **`SVC_DBT`는 `TYPE = LEGACY_SERVICE`에 비밀번호 인증이다.** CI 한 바퀴 검증용이다. 키페어 인증(`TYPE = SERVICE`)이 맞지만 이번 목표가 파이프라인 검증이어서 단순한 쪽을 택했다.
- **웨어하우스는 XSMALL, 60초 자동 중지다.** 비용을 최소로 묶는다.

## 3. dbt 프로젝트

### 접속 (`profiles.yml`)

| 타깃 | 데이터베이스.스키마 | 용도 |
|---|---|---|
| `dev` (기본) | `DBT_DEV.DEV` | 로컬 개발, MR 검증 |
| `prod` | `DBT_PROD.MART` | `main` 배포 |

- 계정 식별자(`<org>-<account>`)와 유저(`SVC_DBT`)는 `env_var`의 기본값으로 넣었다. 비밀이 아니기 때문이다. 환경변수를 주면 덮어쓴다.
- 비밀번호는 `SNOWFLAKE_PASSWORD` 환경변수로만 받는다. 파일에는 없다.

### 모델 (`models/demo/`)

같은 원천(`orders`)에서 같은 집계(상태별 주문 수, 고유 고객 수)를 구체화 방식만 바꿔 만들었다.

| 모델 | `materialized` | 동작 |
|---|---|---|
| `demo_view` | `view` | 조회할 때마다 계산한다. 항상 최신이다 |
| `demo_table` | `table` | `dbt run`마다 전체를 다시 계산해 저장한다 |
| `demo_incremental` | `incremental` | 첫 실행은 전체, 이후는 새 날짜만 계산해 `merge`한다 |
| `demo_dynamic` | `dynamic_table` | Snowflake가 `target_lag` 1시간 안에서 갱신한다 |
| `customer_orders` | `view` (기본) | 고객별 주문 수와 총액. 사용자에게 여는 결과 뷰 |

- 머터리얼라이즈드 뷰는 Snowflake 제약(조인 불가 등) 때문에 쓰지 않았다.
- 테이블과 다이내믹 테이블은 뷰와 객체 종류가 달라서 `DBT_USER`에 `FUTURE TABLES`/`FUTURE DYNAMIC TABLES` 권한을 따로 줘야 한다. `setup/02-materializations.sql`이 이 권한을 준다.
- 증분 모델은 날짜 단위로 집계해서 `COUNT(DISTINCT)`가 날짜 안에서 닫히게 했다. 날짜를 넘나드는 고유 값은 증분으로 합칠 수 없다.

### 테스트

- 원천: 기본키 `unique`/`not_null`, 주문의 고객 키가 고객 테이블에 존재하는지(`relationships`).
- 결과(`customer_orders`): `customer_key`의 `unique`/`not_null`, 집계 열 `not_null`.

## 4. 로컬 실행

```bash
# 저장소로 이동 (venv 활성화 상태)
cd ~/gitlab/snowflake-dbt

# 비밀번호는 화면에 안 보이게 입력 (셸 히스토리에 남지 않는다)
read -s "SNOWFLAKE_PASSWORD?비밀번호: " && export SNOWFLAKE_PASSWORD

# 연결만 점검
dbt debug --connection

# 개발 환경(DBT_DEV.DEV)에 모델 생성
dbt run

# 테스트 실행
dbt test
```

## 5. GitLab CI

### 파이프라인

dbt 관련 파일(`models/`, `macros/`, `seeds/`, `snapshots/`, `tests/`, `dbt_project.yml`, `profiles.yml`, `ci/`, `.gitlab-ci.yml`)이 바뀐 경우에만 작업이 만들어진다. README나 `setup/`만 바꾸는 커밋은 파이프라인을 돌리지 않는다.

| 작업 | 실행 조건 | 하는 일 |
|---|---|---|
| `validate` | MR, `main` (dbt 파일 변경 시) | 개발 환경(`dev` 타깃)에서 Slim CI로 `dbt build` |
| `deploy` | `main` (dbt 파일 변경 시) | 운영 환경(`prod` 타깃)에서 전체 `dbt build`, 끝나면 `target/manifest.json`을 산출물로 남긴다 |

### Slim CI

`validate`는 모든 모델을 빌드하지 않고, 운영 대비 바뀐 모델과 그 하위만 빌드한다.

1. `ci/fetch-prod-state.py`가 `main`의 마지막 성공 `deploy` 작업 산출물에서 `manifest.json`을 `prod-state/`로 받는다(CI 작업 토큰 사용).
2. 받았으면 `dbt build --target dev --select "state:modified+" --defer --state prod-state`를 실행한다. 바뀌지 않은 상위 모델은 빌드하지 않고 운영 객체를 가리킨다.
3. 못 받으면(첫 실행이거나 산출물이 만료됨) 전체를 `dbt build`한다.

dbt 1.9에서 오프라인으로 시험했다. 운영 타깃으로 만든 manifest와 개발 타깃의 현재 코드를 비교했을 때, 코드 변경이 없으면 선택되는 모델이 없고, 모델 하나를 고치면 그 모델만 선택됐다. 타깃이 달라 스키마가 다른 것은 변경으로 잡히지 않았다. Snowflake에 연결한 실제 파이프라인 실행은 아직 하지 않았다.

- 작업 이미지는 dbt 공식 이미지 `ghcr.io/dbt-labs/dbt-snowflake:1.9.latest`다. dbt가 미리 설치되어 있어서 작업마다 `pip install`을 하지 않는다. 이미지의 진입점이 `dbt`라서 `entrypoint: [""]`로 비워 스크립트를 실행한다.
- Runner는 k8s 클러스터 안의 Kubernetes executor다. CI 작업마다 파드가 하나 떠서 실행하고 사라진다. 태그를 지정하지 않아도 받는다.
- 비밀번호는 프로젝트 CI 변수 `SNOWFLAKE_PASSWORD`(Masked)로 주입한다. `Protected`는 껐다. MR 파이프라인에서도 써야 해서다.
- `Masked` 변수는 사용할 수 있는 문자에 제한이 있다. 영문 대소문자와 숫자 위주로 정하면 안전하다.

## 6. 검증 이력

- 2026-10-18: `SVC_DBT`로 `dbt debug` 연결 점검 통과(CI 로그 `Connection test: OK`).
- 2026-10-18: GitLab CI 파이프라인에서 `validate`, `deploy` 모두 성공. `DBT_PROD.MART`에 결과 객체가 생기고 Snowsight에서 조회 확인.
- 2026-10-18: 구체화 방식 데모 모델 4종과 `customer_orders`가 `main` 배포에 포함되어 파이프라인 성공 확인.
- 2026-10-18: 다이내믹 테이블 `demo_dynamic`의 갱신 모드는 `FULL`이다. 원천이 공유 DB(`SNOWFLAKE_SAMPLE_DATA`)라서 변경 추적을 켤 수 없어 증분 갱신이 안 된다. 직접 소유한 테이블을 원천으로 쓰면 다시 확인해야 한다.
- 2026-10-18: CI 작업 이미지를 dbt 공식 이미지(1.9)로 바꿔 파이프라인 전체가 약 100초에서 68초로 줄었다(`pip install` 제거).
- 확인하지 않은 것: 증분 모델의 두 번째 실행 결과, MR 파이프라인, `DBT_USER` 롤로 원천이 막히는지 여부.

## 7. 알려진 이슈

- **로컬(1.12.6)과 CI(1.9) 버전이 다르다.** 공식 이미지의 태그가 `1.9.latest`(2024-12 빌드)에서 멈춰 있어서 최신 버전 이미지가 없다. 1.9는 더 이상 정기 패치를 받지 않는 버전이다. 모델 SQL과 설정은 두 버전에서 모두 파싱되도록 맞췄다.
- **테스트 인자(`relationships`의 `to`, `field`)는 `arguments:` 없이 쓴다.** `arguments:`는 1.9에서 컴파일 오류가 난다. 1.12에서는 대신 deprecation 경고가 나온다.
- **새 비밀번호가 `MIN_LENGTH`로 거부된다.** 계정에 사용자 정의 정책이 없어도 최소 길이 요건이 있다. 대소문자와 숫자를 섞은 16자 이상으로 정하면 통과했다.
- **`ACCOUNTADMIN`에서 CI가 만든 객체가 안 보인다.** 객체 소유자가 `DBT_APP`이라서 `ACCOUNTADMIN`에는 권한이 없다. 커스텀 롤을 `SYSADMIN` 아래에 부여하거나 `USE ROLE DBT_APP`으로 전환해서 조회한다.
- **CI에서 `dbt debug`가 `git` 의존성 점검으로 실패한다.** 작업 이미지에 `git`이 없다. `--connection` 옵션으로 연결 점검만 한다.
- **`relationships` 테스트 인자는 `arguments:` 아래에 쓴다.** 그렇게 쓰지 않으면 dbt가 deprecation 경고를 낸다.

## 8. 운영 전환 시 논의할 것

| 항목 | 현재 | 운영에서 필요한 방향 |
|---|---|---|
| 계정 인증 | `LEGACY_SERVICE` + 비밀번호 | 키페어(`TYPE = SERVICE`) 또는 PAT. 키 회전 절차 포함 |
| 비밀 관리 | GitLab CI 변수(Masked) | Vault 연동(GitLab ID 토큰으로 로그인, 비밀번호를 Vault에서 읽기). 내장 `secrets:` 키워드는 유료 등급 기능이라 `id_tokens`와 `vault` CLI를 직접 호출하는 방식이 현실적이다 |
| 배포 롤 분리 | `dev`와 `prod`가 같은 `DBT_APP` | 운영 배포 전용 롤(`DBT_PROD`에만 권한)로 분리해서 MR 파이프라인이 운영을 건드리지 못하게 한다 |
| MR 검증 | 공용 개발 스키마 `DBT_DEV.DEV` | MR별 임시 스키마를 만들고 닫힌 뒤 삭제 |
| 사용자 계정 | 롤 `DBT_USER`만 준비 | 사람은 SSO/SCIM 그룹을 롤에 매핑. 앱은 서비스 계정에 롤만 부여 |
| CI 이미지 | 공식 이미지 1.9 (패치 종료 버전) | 버전을 올려야 하면 `requirements.txt`로 dbt를 설치한 이미지를 직접 만들어 레지스트리(GitLab 컨테이너 레지스트리 등)에 올려 쓴다 |
| 구체화 방식 | 비교용 데모 4종 | 모델별로 정한다. 무거운 계산은 숨긴 스키마에 테이블로 두고 사용자에게는 얇은 뷰만 여는 계층 분리를 검토한다 |
| 원천 | 샘플 데이터 | 실제 원천 DB/스키마 확정. 일반 DB는 `USAGE`/`SELECT`, 공유 DB는 `IMPORTED PRIVILEGES` |
| 비용 | 웨어하우스 1개 공용 | 용도별 웨어하우스 분리, 리소스 모니터(크레딧 상한) 설정 |
| 가용성 | Vault와 Runner가 같은 k8s | Vault가 sealed면 CI가 멈춘다. 수동 unseal 구조의 영향을 같이 본다 |
