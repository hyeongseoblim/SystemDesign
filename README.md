# STUDY WITH JOB — 백엔드 이직 준비 학습 플랫폼

6년차 백엔드 개발자의 이직 준비를 위한 **모바일 우선 학습 카드 플랫폼**. 시스템 디자인·물류 도메인·백엔드 설계·AI/LLM을 카드 단위로 학습한다.

> 정적 HTML 학습 노트에서 출발해, **API + PWA + AI 생성** 구조로 전환한 프로젝트다.

## 아키텍처

```
[사용자] → Vercel (Next.js PWA) → Cloud Run (Spring/Kotlin API) → Neon PostgreSQL
                │                           └→ Claude API (선택적 생성·면접 API)
                └→ ChatGPT 웹 (무료 수동 면접)
```

- **`apps/api`** — Spring Boot 3.5 / Kotlin 2.3 / JDK 25 / PostgreSQL / Flyway. 학습 카드 REST API + AI 생성 파이프라인(품질 게이트 3종) + 스케줄러.
- **`apps/web`** — Next.js 15(App Router) 모바일 우선 PWA. 카드 피드·상세(마크다운 + Mermaid 렌더)·오프라인 캐시.
- **`infra`** — Cloud Run + Neon + Vercel 배포 설정·스크립트, 로컬 전용 Docker Compose.
- **`docs`** — 플랫폼 아키텍처·로컬 개발·콘텐츠 운영 설계 문서.

## 콘텐츠 모델

학습 콘텐츠는 **DB의 Card**로 관리된다(정적 HTML 아님).

| 테이블 | 역할 |
|---|---|
| `cards` | 카드 본문(`content_md` 마크다운) · area · mode · 난이도 · 상태(DRAFT/PUBLISHED) · source(AI_GENERATED/MANUAL) |
| `card_tags` / `card_questions` | 태그 · 이해도 확인 질문 |
| `curriculum_topics` | AI가 생성할 주제 목록(중복 방지 게이트) |
| `interactions` | 사용자 답변 · 북마크 |
| `interview_sessions` / `interview_turns` | 대화형 면접 세션과 턴 기록 · 피드백 · 토큰 사용량 |

카드 출처는 두 가지다.
1. **수동(MANUAL)** — `apps/api/src/main/resources/content/*.md`(프론트매터 + 마크다운)를 `ContentSeeder`가 부팅 시 slug 기준 멱등 적재. 현재 소스 기준 **8개 영역 129개 카드** 시드.
2. **AI 생성(AI_GENERATED)** — 선택적 유료 파이프라인. 기본 비활성화하며, Cloud Run에서 정기 실행하려면 외부 스케줄러와 비용 한도를 먼저 구성한다.

카드가 **읽는 학습**이라면, 면접은 **대답하는 학습**이다. `/interview`에서 영역·주제·난이도를
고르면 면접 프롬프트를 만들고, 이를 개인 ChatGPT 웹 대화에 붙여넣어 무료로 진행한다.
기존 서버 기반 면접 API는 별도 설정을 켠 경우에만 Claude API를 호출한다.

## 학습 영역 (8종)

시스템 디자인 · 물류 도메인 · 백엔드 개발 · 백엔드 아키텍처 · 데이터베이스 · 인프라 · CS 기초 · AI/LLM.
각 영역별 **코치 에이전트**(`.claude/agents/`)와 학습 모드(`/interview` `/concept` `/design` `/review`)가 정의되어 있다. 상세는 [CLAUDE.md](CLAUDE.md) 참고.

## 로컬 실행

> 상세 가이드·트러블슈팅: [docs/local-dev.md](docs/local-dev.md)

### 원샷 (권장)
```bash
scripts/local-dev.sh up      # Postgres(도커) + API + 웹 전부 기동 → http://localhost:3000
scripts/local-dev.sh down    # 전부 종료
```

### 백엔드
```bash
# PostgreSQL
cd infra && docker compose -f docker-compose.local.yml up -d

# API (JDK 25 필요)
cd apps/api && ./gradlew bootRun
# Flyway가 스키마 생성 → ContentSeeder가 129개 카드 적재
```
> **주의**: 프로젝트 툴체인은 **JDK 25**다(Gradle 9.6 / Kotlin 2.3 / Spring Boot 3.5). JDK 21~24로는 Gradle 데몬은 뜨지만 툴체인 25를 요구하므로, 로컬에 JDK 25가 없으면 Gradle이 자동 다운로드를 시도한다.

### 프론트엔드
```bash
cd apps/web && cp .env.example .env.local && npm install && npm run dev
# http://localhost:3000 (API가 8080에 떠 있어야 함)
```

### 한 번에 (Docker Compose)
```bash
cd infra && cp .env.example .env   # DB_PASSWORD / ADMIN_TOKEN 설정
docker compose up -d
```

## 주요 API

| 메서드 | 경로 | 설명 |
|---|---|---|
| `GET` | `/api/v1/cards?area=&mode=&difficulty=&shuffleSeed=&cursor=&limit=20` | 카드 피드(영역·모드·난이도 필터, 결정적 랜덤/기본 keyset 페이지네이션) |
| `GET` | `/api/v1/cards/{id}` | 카드 상세(본문 + 질문) |
| `POST` | `/api/v1/cards` | 카드 수동 생성(MANUAL) |
| `GET` | `/api/v1/interviews` | 지난 면접 세션 목록 |
| `POST` | `/api/v1/interviews` | 면접 시작(영역·주제·난이도) → 면접관 첫 질문 |
| `GET` | `/api/v1/interviews/{id}` | 세션 상세(전체 대화 + 피드백) |
| `POST` | `/api/v1/interviews/{id}/answers` | 답변 전송 → 후속 질문 |
| `POST` | `/api/v1/interviews/{id}/finish` | 면접 종료 → 3축 피드백 생성 |
| `GET` | `/api/v1/health` | 헬스체크 |

> 기존 유료 면접 API와 카드 생성 배치는 기본 비활성화되어 있다. 사용자 면접은 `/interview`의 ChatGPT 웹 수동 연동을 사용한다.

자세한 내용은 [apps/api/README.md](apps/api/README.md), [apps/web/README.md](apps/web/README.md), [infra/README.md](infra/README.md) 참고.

검색·약점 복습·질문 점검 기준의 사용 흐름과 검증 방법은 [학습 경험 개선](docs/study-experience.md)을 참고한다.

카드 확장 목표, 중복 방지 모델, 작성·검수 절차는 [콘텐츠 확장 설계](docs/content-expansion-plan.md)를 따른다.

## 라이선스

[MIT License](LICENSE)
