"use client";

import { useRef } from "react";
import { useSearchParams } from "next/navigation";

export default function FilterSheet({ children }: { children: React.ReactNode }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const params = useSearchParams();
  const count = ["area", "mode", "difficulty"].filter(key => params.has(key)).length;
  return <div className="filter-launcher">
    <span>나에게 맞는 학습 찾기</span>
    <button className="chip" onClick={() => dialog.current?.showModal()} aria-haspopup="dialog">필터{count > 0 ? ` · ${count}` : ""} ☰</button>
    <dialog ref={dialog} className="filter-sheet" aria-labelledby="filter-title" onClick={event => { if (event.target === dialog.current) dialog.current.close(); }}>
      <div className="filter-sheet-content">
        <div className="sheet-heading"><h2 id="filter-title">학습 필터</h2><button autoFocus className="chip" onClick={() => dialog.current?.close()} aria-label="필터 닫기">닫기</button></div>
        {children}
        <button className="primary-btn" onClick={() => dialog.current?.close()}>결과 보기</button>
      </div>
    </dialog>
  </div>;
}
