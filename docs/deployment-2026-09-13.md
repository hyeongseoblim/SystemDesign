# 2026-09-13 콘텐츠 검수 배포

## 운영 반영 완료

- 소스: `61009dc` — main 커밋·푸시 완료.
- 범위: V9의 MANUAL 본문 32개, Web 질문 해설 34개/102문항. 심층 검수 27개와 부분 정정 5개를 구분한다.
- API Cloud Build: `802f4639-bd70-4213-a1eb-4e2d8e0c0516`, SUCCESS.
- 이미지: `asia-northeast3-docker.pkg.dev/jobstudy-14798/jobstudy/jobstudy-api:61009dc`.
- Cloud Run: `jobstudy-api-00013-55d`, 운영 트래픽 100%. 기존 환경·비밀·인스턴스 설정을 유지하고 이미지만 교체했다.
- Web: Vercel `dpl_6kjCuUZrCD3Bw1gymni9TwDuz5A7`, READY, [운영 사이트](https://jobstudy-eta.vercel.app).
- 원격 CI: `34730061974`, 성공.

## 검증 근거

운영 DB를 읽기 전용으로 조회해 Flyway V9 성공을 확인했다. 32개 `content_md`의 MD5를 Markdown 본문과 비교해 전부 일치했다. 배포 전후 MANUAL 카드의 ID/slug와 연결된 질문 레코드는 동일했다.

API health와 검수 카드 상세 HTTP 200을 확인했다. Vercel 홈에서 카드 목록을 확인했고, Kubernetes 자원 관리 상세 페이지 응답에 새 본문의 HPA 설명과 새 질문 해설이 포함되는 것을 확인했다. 브라우저 상호작용·모바일 레이아웃·Mermaid 렌더를 새로 검증한 것은 아니다.

## 후속 Kubernetes 검수

네트워킹·스토리지·장애 진단 면접 3개 카드의 심층 검수를 추가했다. EndpointSlice와 패킷 경로, RWO/RWOP와 PVC 보존, Pod 상태와 재시작 원인 진단을 보강했다. 누적 심층 30개·부분 5개, 해설 37개/111문항이다.

후속 본문은 V10에 분리했다. 배포 완료된 V9는 변경하지 않았다. 실제 Kubernetes 클러스터 장애·CSI 복원 시험은 수행하지 않았다.
