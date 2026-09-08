"use client";

import { useEffect, useRef, useState } from "react";
import { QuestionItem } from "@/lib/api";
import { readStorage, writeStorage } from "@/lib/study";

export interface AnswerGuide {
  reviewedAt: string;
  scope: string;
  sources: { label: string; url: string }[];
  questions: { question: string; points: string[]; pitfall: string; followUp: string }[];
}

/** 질문별 답변 — localStorage 자동 저장 (Phase 4에서 interactions API로 승격 예정) */
export default function QuestionAnswers({
  cardId,
  questions,
  guide,
}: {
  cardId: string;
  questions: QuestionItem[];
  guide?: AnswerGuide;
}) {
  const [answered, setAnswered] = useState<Set<string>>(new Set());

  useEffect(() => {
    const stored = new Set<string>();
    for (const question of questions) {
      const key = `jobStudy::ans::${cardId}::${question.id}`;
      if ((readStorage(key) ?? "").trim()) stored.add(question.id);
    }
    setAnswered(stored);
  }, [cardId, questions]);

  function updateAnswered(qid: string, hasAnswer: boolean) {
    setAnswered((current) => {
      const next = new Set(current);
      if (hasAnswer) next.add(qid);
      else next.delete(qid);
      return next;
    });
  }

  if (questions.length === 0) return null;
  return (
    <div id="questions" className="qsection">
      <div className="qsection-head">
        <span>STEP 2</span>
        <div>
          <h2>기억에서 꺼내보기</h2>
          <p className="qhint">본문을 보지 않고, 동료에게 설명하듯 답해보세요.</p>
        </div>
        <strong>{answered.size}/{questions.length} 작성</strong>
      </div>
      {questions.map((q, i) => (
        <AnswerCard
          key={q.id}
          cardId={cardId}
          qid={q.id}
          index={i}
          question={q.question}
          guide={guide?.questions.find((item) => item.question === q.question)}
          onAnsweredChange={updateAnswered}
        />
      ))}
      {guide && <aside className="guide-sources"><p>점검 기준 검수: {guide.reviewedAt} · {guide.scope}</p>
        <ul>{guide.sources.map((source) => <li key={source.url}><a href={source.url} target="_blank" rel="noopener noreferrer">{source.label} ↗</a></li>)}</ul>
      </aside>}
    </div>
  );
}

function AnswerCard({
  cardId,
  qid,
  index,
  question,
  guide,
  onAnsweredChange,
}: {
  cardId: string;
  qid: string;
  index: number;
  question: string;
  guide?: AnswerGuide["questions"][number];
  onAnsweredChange: (qid: string, hasAnswer: boolean) => void;
}) {
  const storageKey = `jobStudy::ans::${cardId}::${qid}`;
  const [value, setValue] = useState("");
  const [saved, setSaved] = useState(false);
  const [saveError, setSaveError] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    setValue(readStorage(storageKey) ?? "");
    return () => { if (timer.current) clearTimeout(timer.current); };
  }, [storageKey]);

  function onChange(e: React.ChangeEvent<HTMLTextAreaElement>) {
    setValue(e.target.value);
    const success = writeStorage(storageKey, e.target.value);
    setSaveError(!success);
    onAnsweredChange(qid, !!e.target.value.trim());
    setSaved(success);
    if (timer.current) clearTimeout(timer.current);
    timer.current = setTimeout(() => setSaved(false), 1200);
  }

  return (
    <div className="qcard">
      <div className="qhead">
        <span className="qn">Q{index + 1}</span>
        <span className={`saved ${saved ? "show" : ""}`} aria-hidden={!saved}>✓ 저장됨</span>
      </div>
      <p className="qtext">{question}</p>
      <textarea
        value={value}
        onChange={onChange}
        placeholder="내 언어로 핵심을 설명해 보세요…"
        aria-label={`Q${index + 1} 답변`}
      />
      {saveError && <p role="alert">답변을 저장하지 못했어요. 화면을 나가기 전에 답변을 복사해 주세요.</p>}
      <div className="answer-foot">
        <span>{saveError ? "저장되지 않음" : "이 기기에 자동 저장"}</span>
        <span>{value.trim().length}자</span>
      </div>
      {guide && <details className="answer-guide">
        <summary>답변 점검 기준 보기 · 먼저 내 답을 작성해 보세요</summary>
        <p>유일한 모범 답안이 아닌 자기 점검 기준입니다. 설명한 항목을 체크해 보세요.</p>
        <div className="guide-checklist">{guide.points.map((point) => <label key={point}><input type="checkbox" /> <span>{point}</span></label>)}</div>
        <p><strong>흔한 오답</strong> {guide.pitfall}</p>
        <p><strong>꼬리 질문</strong> {guide.followUp}</p>
      </details>}
    </div>
  );
}
