import type { ReactNode } from "react";
import { useLocation } from "react-router-dom";
import TopBar from "./TopBar";
import ContractorTopBar from "./ContractorTopBar";
import { useAccount } from "../hooks/useAccount";

export default function Layout({ children }: { children: ReactNode }) {
  const { account, loading } = useAccount();
  const location = useLocation();
  const hasOrg = !loading && account?.org;
  const onOrgRoute = location.pathname.startsWith("/org");

  // Contractor workspace: dark top bar with inline nav + "Acting as X".
  if (hasOrg && onOrgRoute) {
    return (
      <>
        <ContractorTopBar org={account.org!} />
        <main>{children}</main>
      </>
    );
  }

  // Personal view (homeowners and contractors on non-/org pages).
  // The regular TopBar shows a "Workspace" chip for contractors so they can
  // hop back to their org workspace.
  return (
    <>
      <TopBar />
      <main>{children}</main>
    </>
  );
}
