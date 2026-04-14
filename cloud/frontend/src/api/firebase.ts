import { initializeApp, getApps } from "firebase/app";
import {
  getAuth,
  onAuthStateChanged,
  signInWithEmailAndPassword,
  createUserWithEmailAndPassword,
  signInWithPopup,
  GoogleAuthProvider,
  sendPasswordResetEmail,
  signOut as firebaseSignOut,
  type User,
} from "firebase/auth";

const FIREBASE_CONFIG = {
  apiKey: "AIzaSyCW1KBTi5nuNCpJjZG48gQThaSaeK6h6gg",
  authDomain: "roomscanalpha.firebaseapp.com",
  projectId: "roomscanalpha",
};

function ensureApp() {
  if (getApps().length === 0) {
    initializeApp(FIREBASE_CONFIG);
  }
}

export function getFirebaseAuth() {
  ensureApp();
  return getAuth();
}

export function onAuthReady(): Promise<User | null> {
  const auth = getFirebaseAuth();
  return new Promise((resolve) => {
    const unsubscribe = onAuthStateChanged(auth, (user) => {
      unsubscribe();
      resolve(user);
    });
  });
}

export async function getIdToken(): Promise<string | null> {
  const user = getFirebaseAuth().currentUser;
  if (!user) return null;
  return user.getIdToken();
}

export async function emailSignIn(email: string, password: string) {
  return signInWithEmailAndPassword(getFirebaseAuth(), email, password);
}

export async function emailSignUp(email: string, password: string) {
  return createUserWithEmailAndPassword(getFirebaseAuth(), email, password);
}

export async function googleSignIn() {
  return signInWithPopup(getFirebaseAuth(), new GoogleAuthProvider());
}

export async function resetPassword(email: string) {
  return sendPasswordResetEmail(getFirebaseAuth(), email);
}

export async function signOut() {
  return firebaseSignOut(getFirebaseAuth());
}

export function friendlyAuthError(code: string): string {
  const map: Record<string, string> = {
    "auth/email-already-in-use": "An account with this email already exists.",
    "auth/wrong-password": "Incorrect password.",
    "auth/user-not-found": "No account found with this email.",
    "auth/weak-password": "Password must be at least 6 characters.",
    "auth/invalid-email": "Please enter a valid email address.",
    "auth/too-many-requests": "Too many attempts. Try again later.",
    "auth/invalid-credential": "Incorrect email or password.",
  };
  return map[code] || "Authentication failed. Please try again.";
}

export { onAuthStateChanged };
export type { User };
