import type { Metadata, Viewport } from "next";
import "./globals.css";
import { Suspense } from "react";
import AppNavigation from "@/components/AppNavigation";
import ServiceWorkerRegister from "@/components/ServiceWorkerRegister";

export const metadata: Metadata = {
  title: "STUDY WITH JOB — 커리어를 만드는 기술 학습",
  description: "매일 쌓이는 백엔드/시스템 디자인 학습 카드",
  manifest: "/manifest.webmanifest",
  appleWebApp: { capable: true, statusBarStyle: "default", title: "STUDY WITH JOB" },
};

export const viewport: Viewport = {
  themeColor: [
    { media: "(prefers-color-scheme: dark)", color: "#0b1120" },
    { media: "(prefers-color-scheme: light)", color: "#f5f7fb" },
  ],
  width: "device-width",
  initialScale: 1,
  viewportFit: "cover",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="ko">
      <body>
        <div className="app">{children}</div>
        <Suspense fallback={null}><AppNavigation /></Suspense>
        <ServiceWorkerRegister />
      </body>
    </html>
  );
}
