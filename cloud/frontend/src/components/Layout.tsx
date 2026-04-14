import type { ReactNode } from "react";
import TopBar from "./TopBar";
import OrgSidebar from "./OrgSidebar";
import { useAccount } from "../hooks/useAccount";

export default function Layout({ children }: { children: ReactNode }) {
  const { account, loading } = useAccount();
  const showSidebar = !loading && account?.org;

  return (
    <>
      <TopBar />
      <div className={showSidebar ? "layout-with-sidebar" : ""}>
        {showSidebar && <OrgSidebar org={account.org!} />}
        <main className={showSidebar ? "layout-main" : ""}>{children}</main>
      </div>
    </>
  );
}
