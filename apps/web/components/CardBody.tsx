"use client";

import { useEffect, useRef } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import remarkCjkFriendly from "remark-cjk-friendly";
import rehypeHighlight from "rehype-highlight";
import { sectionId } from "@/lib/reading";
import type { ReactNode } from "react";

/** React 노드 트리에서 텍스트만 평탄화 (callout 분류용) */
function flatText(node: ReactNode): string {
  if (node == null || typeof node === "boolean") return "";
  if (typeof node === "string" || typeof node === "number") return String(node);
  if (Array.isArray(node)) return node.map(flatText).join("");
  if (typeof node === "object" && "props" in node) {
    return flatText((node as { props: { children?: ReactNode } }).props.children);
  }
  return "";
}

/** 콜아웃 종류 감지 — `> **면접 포인트**` / `> **실무 함정**` / `> **팁**` 패턴 */
function calloutKind(children: ReactNode): string | undefined {
  const head = flatText(children).trim().slice(0, 30);
  if (/면접/.test(head)) return "interview";
  if (/함정|주의|안티패턴|실수|경고/.test(head)) return "warn";
  if (/팁|권장|체크리스트|요령/.test(head)) return "tip";
  return undefined;
}

/** 본문 끝의 보일러플레이트 "이해도 확인" 섹션 제거 — 질문 UI가 별도로 렌더됨 */
function stripTrailingQnaSection(md: string): string {
  return md.replace(/\n#{2,3}\s*(?:\d+\.\s*)?이해도 확인[^\n]*\n[\s\S]*$/, "\n");
}

/** 마크다운 본문 렌더 — 코드 하이라이팅 · Callout · 표 래핑 · Mermaid */
export default function CardBody({ md: rawMd }: { md: string }) {
  const md = stripTrailingQnaSection(rawMd);
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    let active = true;
    (async () => {
      const nodes = ref.current?.querySelectorAll<HTMLElement>(
        "[data-mermaid]:not([data-rendered])"
      );
      if (!nodes || nodes.length === 0) return;
      const mermaid = (await import("mermaid")).default;
      if (!active) return;
      const dark = window.matchMedia("(prefers-color-scheme: dark)").matches;
      // useMaxWidth:false — 모바일에서 축소 대신 원본 크기 + 박스 내 가로 스크롤
      mermaid.initialize({
        startOnLoad: false,
        securityLevel: "loose",
        theme: dark ? "dark" : "neutral",
        themeVariables: { fontFamily: "inherit", fontSize: "13.5px" },
        flowchart: { useMaxWidth: false },
        sequence: { useMaxWidth: false },
        er: { useMaxWidth: false },
        state: { useMaxWidth: false },
        class: { useMaxWidth: false },
        gantt: { useMaxWidth: false },
      });
      for (let i = 0; i < nodes.length; i++) {
        const el = nodes[i];
        const code = el.getAttribute("data-mermaid") ?? "";
        try {
          const { svg } = await mermaid.render(`mmd-${Date.now()}-${i}`, code);
          if (!active) return;
          el.innerHTML = svg;
          el.setAttribute("data-rendered", "1");
        } catch {
          el.textContent = code; // 렌더 실패 시 원문 표시
          el.setAttribute("data-rendered", "1");
        }
      }
    })();
    return () => {
      active = false;
    };
  }, [md]);

  return (
    <div className="content" ref={ref}>
      <ReactMarkdown
        remarkPlugins={[remarkGfm, remarkCjkFriendly]}
        rehypePlugins={[rehypeHighlight]}
        components={{
          h2({ children }) { return <h2 id={sectionId(flatText(children))}>{children}</h2>; },
          code({ className, children, ...props }) {
            const match = /language-(\w+)/.exec(className ?? "");
            if (match?.[1] === "mermaid") {
              return (
                <div
                  className="mermaid-box"
                  data-mermaid={String(children).replace(/\n$/, "")}
                />
              );
            }
            return (
              <code className={className} {...props}>
                {children}
              </code>
            );
          },
          pre({ children, ...props }) {
            // 코드 블록 언어 라벨 추출
            let lang: string | undefined;
            const child = Array.isArray(children) ? children[0] : children;
            if (
              child &&
              typeof child === "object" &&
              "props" in child &&
              typeof (child as { props: { className?: string } }).props
                .className === "string"
            ) {
              lang = /language-(\w+)/.exec(
                (child as { props: { className: string } }).props.className
              )?.[1];
            }
            if (lang === "mermaid") return <>{children}</>;
            return (
              <div className="codeblock">
                {lang && <span className="lang">{lang}</span>}
                <pre {...props}>{children}</pre>
              </div>
            );
          },
          blockquote({ children, ...props }) {
            return (
              <blockquote data-co={calloutKind(children)} {...props}>
                {children}
              </blockquote>
            );
          },
          table({ children, ...props }) {
            return (
              <div className="table-wrap">
                <table {...props}>{children}</table>
              </div>
            );
          },
        }}
      >
        {md}
      </ReactMarkdown>
    </div>
  );
}
