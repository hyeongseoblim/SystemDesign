"use client";

import Link from "next/link";
import { usePathname, useSearchParams } from "next/navigation";

const tabs = [
  { id: "home", label: "홈", href: "/", path: "m3 10 9-7 9 7v10a1 1 0 0 1-1 1h-5v-7H9v7H4a1 1 0 0 1-1-1Z" },
  { id: "explore", label: "탐색", href: "/?view=explore", path: "M21 21l-5-5M18 10a8 8 0 1 1-16 0 8 8 0 0 1 16 0" },
  { id: "review", label: "복습", href: "/?view=review", path: "M3 10a9 9 0 1 1 2 8M3 4v6h6m3-3v5l3 2" },
  { id: "interview", label: "면접", href: "/interview", path: "M21 11a9 9 0 0 1-9 9H3l2-5a9 9 0 1 1 16-4ZM8 10h8m-8 4h5" },
];
export default function AppNavigation() {
  const pathname = usePathname();
  const params = useSearchParams();
  // 학습과 대화 화면은 콘텐츠에 집중하고 기존 뒤로 가기를 사용한다.
  if (pathname.startsWith("/cards/") || pathname.startsWith("/interview/")) return null;
  const active = pathname === "/interview" ? "interview" : params.get("view") === "review" ? "review" : params.get("view") === "explore" || ["area", "mode", "difficulty", "study", "q"].some(key => params.has(key)) ? "explore" : "home";
  return <nav className="app-navigation" aria-label="주요 메뉴">{tabs.map(tab =>
    <Link key={tab.id} href={tab.href} className={active === tab.id ? "selected" : undefined} aria-current={active === tab.id ? "page" : undefined}>
      <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d={tab.path} /></svg>
      <span>{tab.label}</span>
    </Link>
  )}</nav>;
}
