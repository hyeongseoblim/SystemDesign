"use client";
export default function CardError({ reset }: { reset: () => void }) {
  return <div className="empty" role="alert"><strong>카드를 불러오지 못했어요.</strong><p>연결 상태를 확인한 뒤 다시 시도해 주세요.</p><button className="loadmore" onClick={reset}>다시 시도</button><a className="back" href="/">카드 목록으로</a></div>;
}
