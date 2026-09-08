"use client";

import { useState } from "react";
import { AREA_LABELS, TopicArea } from "@/lib/api";
import { buildChatGptInterviewPrompt } from "@/lib/chatgptInterview";

const AREAS = Object.keys(AREA_LABELS) as TopicArea[];

/** 모바일에서 주제를 직접 타이핑하는 부담을 줄이는 예시 */
const SUGGESTIONS: Record<TopicArea, string[]> = {
  SYSTEM_DESIGN: [
    "결제·정산 시스템 설계",
    "알림 시스템 설계 — 다채널 팬아웃",
    "근접 검색 — Geohash 기반 주변 기사 찾기",
  ],
  LOGISTICS: [
    "전국 실시간 재고 가용성(ATP) 설계",
    "배송 약속(Delivery Promise) 계산 시스템",
    "반품·역물류 상태 합류 처리",
  ],
  BACKEND_DEV: [
    "재고 차감 동시성 — 오버셀 방지",
    "재시도와 멱등성(Idempotency) 설계",
    "대용량 배치의 트랜잭션 경계",
  ],
  BACKEND_ARCHITECTURE: [
    "주문-결제-배송 Saga 보상 트랜잭션",
    "Outbox 패턴과 exactly-once 전달",
    "모놀리스에서 서비스 분리 기준",
  ],
  DATABASE: [
    "슬로우 쿼리 진단과 인덱스 설계",
    "샤딩 키 선택과 리샤딩 전략",
    "격리수준과 팬텀 리드 실무 사례",
  ],
  INFRA: [
    "무중단 배포 중 장애 롤백 시나리오",
    "오토스케일이 못 따라가는 트래픽 스파이크",
    "관측성 — 장애 원인을 5분 안에 좁히기",
  ],
  CS: [
    "TCP 연결이 느려지는 원인 추적",
    "HTTPS 핸드셰이크와 성능 최적화",
    "데드락 탐지와 회피",
  ],
  AI: [
    "사내 문서 RAG 검색·답변 시스템 설계",
    "LLM Agent 도구 호출의 권한과 실패 처리",
    "LLM 품질 평가와 비용·지연 최적화",
  ],
};

const DIFFICULTIES = [
  { level: 1, label: "입문" },
  { level: 2, label: "기초" },
  { level: 3, label: "중급" },
  { level: 4, label: "시니어" },
  { level: 5, label: "스태프" },
];

export default function InterviewStarter({
  initialArea = "SYSTEM_DESIGN",
  initialTopic = "",
  initialDifficulty = 4,
}: {
  initialArea?: TopicArea;
  initialTopic?: string;
  initialDifficulty?: number;
}) {
  const [area, setArea] = useState<TopicArea>(initialArea);
  const [topic, setTopic] = useState(initialTopic);
  const [difficulty, setDifficulty] = useState(initialDifficulty);
  const [prompt, setPrompt] = useState("");
  const [copied, setCopied] = useState(false);
  const [error, setError] = useState<string | null>(null);

  function prepare() {
    const trimmed = topic.trim();
    if (!trimmed) return;
    setPrompt(buildChatGptInterviewPrompt({ area, topic: trimmed, difficulty }));
    setCopied(false);
    setError(null);
  }

  async function copyPrompt() {
    if (!prompt) return;
    try {
      await navigator.clipboard.writeText(prompt);
      setCopied(true);
    } catch (e) {
      setError(e instanceof Error ? e.message : "프롬프트를 복사하지 못했습니다");
    }
  }

  function openChatGpt() {
    window.open("https://chatgpt.com/", "_blank", "noopener,noreferrer");
  }

  return (
    <section className={`starter a-${area}`}>
      <label className="field-label">영역</label>
      <div className="chips">
        {AREAS.map((a) => (
          <button
            key={a}
            type="button"
            className={`chip a-${a} ${area === a ? "on" : ""}`}
            onClick={() => { setArea(a); setPrompt(""); setCopied(false); }}
          >
            {AREA_LABELS[a]}
          </button>
        ))}
      </div>

      <label className="field-label" htmlFor="topic">
        주제
      </label>
      <textarea
        id="topic"
        className="topic-input"
        rows={2}
        placeholder="예: 쿠팡 로켓배송 라스트마일 배차 시스템 설계"
        value={topic}
        onChange={(e) => { setTopic(e.target.value); setPrompt(""); setCopied(false); }}
      />
      <div className="chips suggestions">
        {SUGGESTIONS[area].map((s) => (
          <button
            key={s}
            type="button"
            className="chip ghost"
            onClick={() => { setTopic(s); setPrompt(""); setCopied(false); }}
          >
            {s}
          </button>
        ))}
      </div>

      <label className="field-label">난이도</label>
      <div className="chips">
        {DIFFICULTIES.map((d) => (
          <button
            key={d.level}
            type="button"
            className={`chip ${difficulty === d.level ? "on" : ""}`}
            onClick={() => { setDifficulty(d.level); setPrompt(""); setCopied(false); }}
          >
            {d.level} · {d.label}
          </button>
        ))}
      </div>

      {error && <p className="form-error">{error}</p>}

      <button
        className="primary-btn"
        onClick={prepare}
        disabled={!topic.trim()}
      >
        무료 면접 프롬프트 만들기
      </button>
      <p className="hint">
        API를 호출하지 않습니다. 프롬프트를 개인 ChatGPT 대화에 붙여넣어 진행합니다.
      </p>

      {prompt && (
        <div className="handoff">
          <div className="handoff-head">
            <strong>면접 프롬프트가 준비됐습니다</strong>
            <span>API 비용 0원</span>
          </div>
          <textarea
            className="prompt-preview"
            value={prompt}
            readOnly
            rows={10}
            aria-label="ChatGPT 면접 프롬프트"
          />
          <ol className="handoff-steps">
            <li>프롬프트를 복사합니다.</li>
            <li>ChatGPT를 열어 새 대화에 붙여넣습니다.</li>
            <li>면접이 끝나면 “면접 종료”라고 입력해 피드백을 받습니다.</li>
          </ol>
          <div className="handoff-actions">
            <button className="ghost-btn" type="button" onClick={copyPrompt}>
              {copied ? "✓ 복사됨" : "프롬프트 복사"}
            </button>
            <button className="primary-btn" type="button" onClick={openChatGpt}>
              ChatGPT 웹 열기 ↗
            </button>
          </div>
        </div>
      )}
    </section>
  );
}
