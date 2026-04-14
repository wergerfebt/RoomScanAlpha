import type { ReactNode } from "react";
import TopBar from "./TopBar";

export default function Layout({ children }: { children: ReactNode }) {
  return (
    <>
      <TopBar />
      <main>{children}</main>
    </>
  );
}
