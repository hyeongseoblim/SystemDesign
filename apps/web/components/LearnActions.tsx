"use client";

import { useEffect, useState } from "react";
import { readKey, doneKey } from "@/lib/api";
import { Mastery, MASTERY_LABELS, masteryKey, readStudy, writeStorage } from "@/lib/study";

export default function LearnActions({ cardId, step = 3 }: { cardId: string; step?: number }) {
  const [done, setDone] = useState(false);
  const [mastery, setMastery] = useState<Mastery>();
  const [error, setError] = useState(false);
  useEffect(() => {
    const record = readStudy(cardId);
    setDone(!!record.done);
    setMastery(record.mastery);
    setError(!writeStorage(readKey(cardId), new Date().toISOString()));
  }, [cardId]);
  function rate(value: Mastery) {
    if (!writeStorage(masteryKey(cardId), value)) { setError(true); return; }
    setMastery(value); setError(false);
  }
  function toggle() {
    if (!writeStorage(doneKey(cardId), done ? null : new Date().toISOString())) { setError(true); return; }
    setDone(!done); setError(false);
  }
  return (
    <section id="complete" className={`learn-actions ${done ? "is-done" : ""}`}>
      <div className="learn-actions-copy"><span>STEP {step}</span><div>
        <h2>본문 없이 설명할 수 있나요?</h2>
        <p>이해도를 선택하면 복습 목록에 반영됩니다. 학습 완료와 별도로 기록해요.</p>
      </div></div>
      <div className="mastery-options" role="group" aria-label="이해도 자기 평가">
        {(Object.keys(MASTERY_LABELS) as Mastery[]).map((value) => (
          <button key={value} className={`chip ${mastery === value ? "on" : ""}`} aria-pressed={mastery === value} onClick={() => rate(value)}>{MASTERY_LABELS[value]}</button>
        ))}
      </div>
      <p className="hint" aria-live="polite">{mastery === "confident" ? "복습 필요 목록에서 제외됩니다." : mastery ? "홈의 ‘복습 필요’에서 다시 볼 수 있어요." : "선택한 이해도는 이 브라우저에 저장됩니다."}</p>
      <button className={`done-btn ${done ? "on" : ""}`} onClick={toggle} aria-pressed={done}>{done ? "✓ 학습 완료됨" : "학습 완료로 표시"}</button>
      {done && <p className="undo-hint">다시 누르면 완료 표시가 해제됩니다. 이해도 기록은 유지됩니다.</p>}
      {error && <p role="alert">이 브라우저에 기록을 저장하지 못했어요. 저장소 사용 설정을 확인해 주세요.</p>}
    </section>
  );
}
