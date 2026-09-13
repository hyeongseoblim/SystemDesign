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

## 후속 운영 반영 완료

- 소스: `482affc` — main 커밋·푸시 완료.
- API Cloud Build: `c777aa0c-e1b9-4b73-b1a0-69cc8990933d`, SUCCESS.
- Cloud Run: `jobstudy-api-00014-c7d`, 운영 트래픽 100%.
- Web: Vercel `dpl_CYwd6aBEXXYQjg2cepXn2Q1maZR6`, READY, 운영 별칭 반영 완료.
- 원격 CI: `34731262692`, 성공.
- 로컬 검증: 콘텐츠 계약, Node 검사 10개, Web 프로덕션 빌드, diff 공백 검사 통과.
- 운영 검증: V10 성공·세 본문 일치, V9 성공·32개 본문 일치를 다시 확인했다. MANUAL 카드 ID/slug 및 질문 레코드는 배포 전후 동일하다.
- API health 정상, 추가 세 카드 상세 HTTP 200 및 원본 본문 일치. 운영 네트워킹 상세 HTML에 새 본문과 질문 해설이 포함되는 것을 확인했다.

누적 35개 본문 변경(심층 30개·부분 정정 5개), 해설 37개/111문항을 운영 반영했다. 나머지 94개는 구조 점검 상태이며 전체 심층 검수 완료로 계산하지 않는다. 모바일 상호작용·실제 Kubernetes 장애 주입은 이번 배포 검증에 포함하지 않았다.

## 이벤트·Outbox·MSA 후속 운영 반영 완료

- 소스: `de4c656`(이벤트·Outbox), `01c6099`(MSA) — 모두 main 커밋·푸시 완료. 최종 배포 소스는 `01c6099`다.
- 최종 API Cloud Build: `8aa35d27-4114-43a4-8c7a-cd0a65b8a85b`, SUCCESS.
- Cloud Run: `jobstudy-api-00015-gfk`, 운영 트래픽 100%.
- 최종 Web: `dpl_H8at8fPyL5cfb4AdLUMT1STDAbJp`, READY, 운영 별칭 반영 완료.
- 원격 CI: `34751873707`, `34752076964` 모두 성공.
- 중간 `de4c656` API 이미지 빌드 `a13d96fb-4c63-463a-bc31-9e05b3bfbbb2`는 성공했지만 Cloud Run에는 최종 이미지로 직접 반영했다. 중간 Web 배포 `dpl_Hbv6d93somqfF1BPE6csFy53zSRj`는 최종 Web으로 교체됐다.

로컬 Node 검사 12개, 콘텐츠 계약, Web 빌드, diff 검사를 통과했다. 콘텐츠 계약에서 빠진 강조 박스를 보완한 뒤 재검사했다. MSA 본문의 Python 가용성 계산을 직접 실행해 99.5010%와 43.71시간을 확인했다.

운영 DB에서 V11·V12 성공과 변경한 고유 본문 35개 전체의 최신 원본 일치를 확인했다. MANUAL 카드 ID/slug와 질문 레코드는 배포 전후 동일하다. API health 정상 및 세 카드 상세 200·본문 일치를 확인했고, MSA 운영 HTML에서 새 계산 예제와 새 질문 해설을 확인했다.

누적 심층 33개·부분 정정 2개, 해설 39개/117문항이다. 본문 고유 변경 수는 35개로 동일하며, 부분 정정 3개를 심층 검수로 전환한 것이다. 남은 94개는 구조 점검 상태다. 실제 Kafka/CDC·외부 API·서비스 장애 주입과 모바일 상호작용 검증은 수행하지 않았다.
