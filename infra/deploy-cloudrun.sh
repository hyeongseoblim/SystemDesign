#!/usr/bin/env bash
# jobStudy API를 Cloud Run에 빌드/배포한다.
# 사전 조건: gcloud 인증, 결제 연결 GCP 프로젝트, Neon DB 생성.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${1:-$SCRIPT_DIR/.env.cloudrun}"

if [ ! -f "$ENV_FILE" ]; then
  echo "설정 파일이 없습니다: $ENV_FILE"
  echo "cp $SCRIPT_DIR/.env.cloudrun.example $SCRIPT_DIR/.env.cloudrun 후 값을 채우세요."
  exit 1
fi

# URL의 &, 비밀번호의 특수문자 등을 셸 문법으로 실행하지 않고 KEY=VALUE 그대로 읽는다.
# source를 사용하면 Neon URL의 `&channel_binding=require`가 백그라운드 연산자로 해석된다.
while IFS='=' read -r key value || [ -n "${key:-}" ]; do
  key="${key%$'\r'}"
  value="${value%$'\r'}"
  [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
  if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "잘못된 환경변수 키입니다: $key"
    exit 1
  fi
  printf -v "$key" '%s' "$value"
  export "$key"
done < "$ENV_FILE"

: "${GCP_PROJECT_ID:?GCP_PROJECT_ID가 필요합니다}"
: "${GCP_REGION:=asia-northeast3}"
: "${DB_URL:?DB_URL이 필요합니다}"
: "${DB_USER:?DB_USER가 필요합니다}"
: "${DB_PASSWORD:?DB_PASSWORD가 필요합니다}"
: "${CORS_ORIGINS:?CORS_ORIGINS가 필요합니다}"
: "${ADMIN_TOKEN:?ADMIN_TOKEN이 필요합니다}"

if [[ "$GCP_PROJECT_ID" == "your-gcp-project-id" || "$DB_URL" == *"//host/"* || "$ADMIN_TOKEN" == "change-me-random-token" ]]; then
  echo "예시 값이 남아 있습니다. $ENV_FILE을 실제 값으로 수정하세요."
  exit 1
fi

for command_name in gcloud; do
  command -v "$command_name" >/dev/null 2>&1 || { echo "$command_name 명령이 필요합니다."; exit 1; }
done

if ! gcloud auth list --filter=status:ACTIVE --format='value(account)' | grep -q .; then
  echo "gcloud 인증이 필요합니다: gcloud auth login"
  exit 1
fi

SERVICE=jobstudy-api
REPOSITORY=jobstudy
IMAGE="$GCP_REGION-docker.pkg.dev/$GCP_PROJECT_ID/$REPOSITORY/$SERVICE:latest"

echo "==> 프로젝트/API 준비"
gcloud config set project "$GCP_PROJECT_ID"
gcloud services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com secretmanager.googleapis.com

if ! gcloud artifacts repositories describe "$REPOSITORY" --location="$GCP_REGION" >/dev/null 2>&1; then
  gcloud artifacts repositories create "$REPOSITORY" \
    --repository-format=docker \
    --location="$GCP_REGION" \
    --description="jobStudy container images"
fi

put_secret() {
  local name="$1"
  local value="$2"
  local new_version
  if gcloud secrets describe "$name" >/dev/null 2>&1; then
    if [ "$(gcloud secrets versions access latest --secret="$name")" = "$value" ]; then
      echo "Secret 값 변경 없음: $name"
      return
    fi
  else
    gcloud secrets create "$name" --replication-policy=automatic
  fi
  new_version="$(printf '%s' "$value" | gcloud secrets versions add "$name" --data-file=- --format='value(name)')"
  new_version="${new_version##*/}"
  # 이전 버전은 롤백 확인 전까지 비활성화한다. Disabled도 과금 대상이므로 배포 검증 후 파기한다.
  while IFS= read -r old_version; do
    [ -z "$old_version" ] && continue
    [ "$old_version" = "$new_version" ] && continue
    gcloud secrets versions disable "$old_version" --secret="$name" --quiet >/dev/null
  done < <(gcloud secrets versions list "$name" --filter='state=ENABLED' --format='value(name)')
}

echo "==> Secret Manager 갱신"
put_secret jobstudy-db-password "$DB_PASSWORD"
put_secret jobstudy-admin-token "$ADMIN_TOKEN"
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  put_secret jobstudy-anthropic-api-key "$ANTHROPIC_API_KEY"
  ANTHROPIC_SECRET=",ANTHROPIC_API_KEY=jobstudy-anthropic-api-key:latest"
else
  ANTHROPIC_SECRET=""
fi

PROJECT_NUMBER="$(gcloud projects describe "$GCP_PROJECT_ID" --format='value(projectNumber)')"
gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor" \
  --condition=None >/dev/null

echo "==> Cloud Build로 이미지 빌드"
if [ "${SKIP_BUILD:-false}" = "true" ]; then
  echo "    기존 Artifact Registry 이미지 사용: $IMAGE"
else
  gcloud builds submit "$ROOT_DIR/apps/api" --tag "$IMAGE"
fi

echo "==> Cloud Run 배포"
gcloud run deploy "$SERVICE" \
  --image="$IMAGE" \
  --region="$GCP_REGION" \
  --platform=managed \
  --allow-unauthenticated \
  --execution-environment=gen2 \
  --cpu=1 \
  --memory=1Gi \
  --concurrency=20 \
  --min=0 \
  --max=1 \
  --timeout=300 \
  --set-env-vars="^@^DB_URL=$DB_URL@DB_USER=$DB_USER@CORS_ORIGINS=$CORS_ORIGINS@GEN_ENABLED=false@INTERVIEW_ENABLED=false@GEN_DAILY_CARDS=${GEN_DAILY_CARDS:-1}@GEN_DAILY_TOKENS=${GEN_DAILY_TOKENS:-50000}@INTERVIEW_MAX_TURNS=${INTERVIEW_MAX_TURNS:-20}@INTERVIEW_DAILY_TOKENS=${INTERVIEW_DAILY_TOKENS:-100000}@JAVA_OPTS=-XX:MaxRAMPercentage=60 -XX:+UseSerialGC -Xss512k -XX:MaxMetaspaceSize=192m" \
  --set-secrets="DB_PASSWORD=jobstudy-db-password:latest,ADMIN_TOKEN=jobstudy-admin-token:latest${ANTHROPIC_SECRET}"

# `--max-instances`는 리비전 상한이다. 서비스 전체 상한은 별도 설정으로
# 유지해야 트래픽을 여러 리비전에 나누거나 다음 배포를 해도 비용 보호가 남는다.
gcloud run services update "$SERVICE" \
  --region="$GCP_REGION" \
  --min=0 \
  --max=1 \
  --quiet >/dev/null

SERVICE_URL="$(gcloud run services describe "$SERVICE" --region="$GCP_REGION" --format='value(status.url)')"
echo "==> 헬스 체크: $SERVICE_URL/api/v1/health"
curl --fail --show-error --retry 8 --retry-delay 5 "$SERVICE_URL/api/v1/health"
echo
echo "배포 완료: $SERVICE_URL"
echo "Vercel의 NEXT_PUBLIC_API_BASE에 위 URL을 설정한 뒤 다시 배포하세요."
