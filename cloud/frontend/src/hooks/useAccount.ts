import { createContext, useContext, useEffect, useState, createElement, type ReactNode } from "react";
import { useAuth } from "./useAuth";
import { apiFetch } from "../api/client";

interface OrgInfo {
  id: string;
  name: string;
  role: string;
  icon_url: string | null;
}

interface AccountData {
  id: string;
  email: string;
  name: string | null;
  account_type: string;
  icon_url: string | null;
  org: OrgInfo | null;
}

interface AccountContextValue {
  account: AccountData | null;
  loading: boolean;
  refresh: () => Promise<void>;
}

const AccountContext = createContext<AccountContextValue | null>(null);

export function AccountProvider({ children }: { children: ReactNode }) {
  const { user, loading: authLoading } = useAuth();
  const [account, setAccount] = useState<AccountData | null>(null);
  const [loading, setLoading] = useState(true);

  async function fetchAccount() {
    try {
      const data = await apiFetch<AccountData>("/api/account");
      setAccount(data);
    } catch {
      setAccount(null);
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    if (authLoading) return;
    if (!user) {
      setAccount(null);
      setLoading(false);
      return;
    }
    fetchAccount();
  }, [user, authLoading]);

  return createElement(
    AccountContext.Provider,
    { value: { account, loading: authLoading || loading, refresh: fetchAccount } },
    children,
  );
}

export function useAccount(): AccountContextValue {
  const ctx = useContext(AccountContext);
  if (!ctx) throw new Error("useAccount must be used within AccountProvider");
  return ctx;
}
