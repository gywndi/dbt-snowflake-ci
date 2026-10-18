"""운영 배포(deploy 작업)가 마지막으로 성공했을 때 남긴 manifest.json을 prod-state/로 내려받는다.

Slim CI가 이 파일과 현재 코드를 비교해 바뀐 모델만 고른다.
파일이 없으면(첫 실행 등) 아무것도 만들지 않고 정상 종료한다. 호출하는 쪽이 전체 빌드로 되돌아간다.
표준 라이브러리만 쓴다. 공식 dbt 이미지에 curl이 있는지 확실하지 않아서다.
"""
import io
import os
import sys
import urllib.request
import zipfile

api = os.environ.get("CI_API_V4_URL")
project = os.environ.get("CI_PROJECT_ID")
token = os.environ.get("CI_JOB_TOKEN")
branch = os.environ.get("CI_DEFAULT_BRANCH", "main")

if not (api and project and token):
    print("CI 환경변수가 없어 운영 manifest를 받지 않는다.")
    sys.exit(0)

url = f"{api}/projects/{project}/jobs/artifacts/{branch}/download?job=deploy"
request = urllib.request.Request(url, headers={"JOB-TOKEN": token})

try:
    data = urllib.request.urlopen(request, timeout=30).read()
except Exception as error:
    print(f"운영 manifest를 받지 못했다(첫 실행이거나 만료됨): {error}")
    sys.exit(0)

with zipfile.ZipFile(io.BytesIO(data)) as archive:
    names = [n for n in archive.namelist() if n.endswith("manifest.json")]
    if not names:
        print("산출물에 manifest.json이 없다.")
        sys.exit(0)
    os.makedirs("prod-state", exist_ok=True)
    with open("prod-state/manifest.json", "wb") as out:
        out.write(archive.read(names[0]))

print("운영 manifest를 prod-state/manifest.json으로 받았다.")
