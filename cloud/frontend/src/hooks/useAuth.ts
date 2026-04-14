import {
  createContext,
  useContext,
  useEffect,
  useState,
  useCallback,
  type ReactNode,
} from "react";
import { createElement } from "react";
import {
  getFirebaseAuth,
  onAuthStateChanged,
  emailSignIn,
  emailSignUp,
  googleSignIn,
  resetPassword,
  signOut,
  type User,
} from "../api/firebase";

interface AuthContextValue {
  user: User | null;
  loading: boolean;
  signInEmail: (email: string, password: string) => Promise<void>;
  signUpEmail: (email: string, password: string) => Promise<void>;
  signInGoogle: () => Promise<void>;
  sendReset: (email: string) => Promise<void>;
  logout: () => Promise<void>;
}

const AuthContext = createContext<AuthContextValue | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<User | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const auth = getFirebaseAuth();
    const unsubscribe = onAuthStateChanged(auth, (u) => {
      setUser(u);
      setLoading(false);
    });
    return unsubscribe;
  }, []);

  const signInEmail = useCallback(async (email: string, password: string) => {
    await emailSignIn(email, password);
  }, []);

  const signUpEmail = useCallback(async (email: string, password: string) => {
    await emailSignUp(email, password);
  }, []);

  const signInGoogle = useCallback(async () => {
    await googleSignIn();
  }, []);

  const sendReset = useCallback(async (email: string) => {
    await resetPassword(email);
  }, []);

  const logout = useCallback(async () => {
    await signOut();
  }, []);

  return createElement(
    AuthContext.Provider,
    { value: { user, loading, signInEmail, signUpEmail, signInGoogle, sendReset, logout } },
    children,
  );
}

export function useAuth(): AuthContextValue {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error("useAuth must be used within AuthProvider");
  return ctx;
}
