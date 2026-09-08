"use client";
import { useEffect, useRef, useState } from "react";
import { readStorage, writeStorage } from "@/lib/study";

export default function ReadingProgress({ cardId }: { cardId: string }) {
  const barRef = useRef<HTMLSpanElement>(null);
  const [resume, setResume] = useState<string | null>(null);
  const key = `jobStudy::position::${cardId}`;
  useEffect(() => {
    setResume(readStorage(key));
    let raf = 0;
    function update(save: boolean) {
      const doc = document.documentElement;
      const max = doc.scrollHeight - window.innerHeight;
      if (barRef.current) barRef.current.style.width = `${max > 0 ? Math.min(1, window.scrollY / max) * 100 : 0}%`;
      if (save) {
        const sections = [...document.querySelectorAll<HTMLElement>(".content h2[id], #questions, #complete")];
        const current = sections.filter((section) => section.getBoundingClientRect().top <= 120).at(-1);
        if (current) writeStorage(key, current.id);
      }
    }
    function onScroll() { cancelAnimationFrame(raf); raf = requestAnimationFrame(() => update(true)); }
    function onResize() { update(false); }
    update(false);
    window.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("resize", onResize);
    return () => { cancelAnimationFrame(raf); window.removeEventListener("scroll", onScroll); window.removeEventListener("resize", onResize); };
  }, [key]);
  return <>
    <div className="progressbar" aria-hidden><span ref={barRef} /></div>
    {resume && <button className="resume-reading chip" onClick={() => { document.getElementById(resume)?.scrollIntoView(); setResume(null); }}>마지막 읽은 위치로 이동 ↓</button>}
  </>;
}
