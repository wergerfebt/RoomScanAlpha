import { useState, type FormEvent } from "react";
import { useAuth } from "../hooks/useAuth";
import { friendlyAuthError } from "../api/firebase";

interface AuthModalProps {
  onSuccess?: () => void;
  onClose?: () => void;
  allowCreate?: boolean;
  subtitle?: string;
  inline?: boolean;
}

export default function AuthModal({
  onSuccess,
  onClose,
  allowCreate = true,
  subtitle = "Sign in to continue",
  inline = false,
}: AuthModalProps) {
  const { signInEmail, signUpEmail, signInGoogle, sendReset } = useAuth();
  const [isCreate, setIsCreate] = useState(false);
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [resetSent, setResetSent] = useState(false);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    if (!email.trim() || !password) {
      setError("Email and password required.");
      return;
    }
    setSubmitting(true);
    setError("");
    try {
      if (isCreate) {
        await signUpEmail(email.trim(), password);
      } else {
        await signInEmail(email.trim(), password);
      }
      onSuccess?.();
    } catch (err: unknown) {
      const code = (err as { code?: string }).code || "";
      setError(friendlyAuthError(code));
    } finally {
      setSubmitting(false);
    }
  }

  async function handleGoogle() {
    try {
      await signInGoogle();
      onSuccess?.();
    } catch (err: unknown) {
      const code = (err as { code?: string }).code || "";
      setError(friendlyAuthError(code));
    }
  }

  async function handleForgot() {
    if (!email.trim()) {
      setError("Enter your email first.");
      return;
    }
    try {
      await sendReset(email.trim());
      setResetSent(true);
      setError("");
    } catch (err: unknown) {
      const code = (err as { code?: string }).code || "";
      setError(friendlyAuthError(code));
    }
  }

  const form = (
    <div style={{ maxWidth: 400, width: "100%", position: "relative" }}>
      {onClose && (
        <button className="modal-close" onClick={onClose}>
          &times;
        </button>
      )}

      <h2 style={{ fontSize: 20, fontWeight: 700, marginBottom: 4 }}>
        {isCreate ? "Create Account" : "Sign In"}
      </h2>
      <p
        style={{
          color: "var(--color-text-muted)",
          fontSize: 13,
          marginBottom: 20,
        }}
      >
        {subtitle}
      </p>

      <form onSubmit={handleSubmit}>
        <input
          className="form-input"
          type="email"
          placeholder="Email"
          autoComplete="email"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          style={{ marginBottom: 10 }}
        />
        <input
          className="form-input"
          type="password"
          placeholder="Password"
          autoComplete={isCreate ? "new-password" : "current-password"}
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          style={{ marginBottom: 8 }}
        />

        <div
          style={{
            color: resetSent ? "var(--color-success)" : "var(--color-danger)",
            fontSize: 13,
            minHeight: 20,
            marginBottom: 8,
          }}
        >
          {resetSent ? "Reset link sent — check your email." : error}
        </div>

        <button className="btn btn-primary btn-full" type="submit" disabled={submitting}>
          {submitting
            ? isCreate
              ? "Creating..."
              : "Signing in..."
            : isCreate
              ? "Create Account"
              : "Sign In"}
        </button>
      </form>

      {allowCreate && (
        <button
          className="btn-link"
          onClick={() => {
            setIsCreate(!isCreate);
            setError("");
            setResetSent(false);
          }}
        >
          {isCreate ? "Already have an account? Sign In" : "Don't have an account? Create one"}
        </button>
      )}

      {!isCreate && (
        <button className="btn-link" onClick={handleForgot}>
          Forgot password?
        </button>
      )}

      <div
        style={{
          color: "var(--color-text-muted)",
          fontSize: 11,
          margin: "12px 0 8px",
          textAlign: "center",
        }}
      >
        or
      </div>

      <button
        className="btn btn-full"
        onClick={handleGoogle}
        style={{ background: "#4285f4", color: "#fff", borderColor: "#4285f4" }}
      >
        Sign In with Google
      </button>
    </div>
  );

  if (inline) {
    return form;
  }

  return (
    <div className="modal-overlay" onClick={(e) => e.target === e.currentTarget && onClose?.()}>
      <div className="modal-content">{form}</div>
    </div>
  );
}
