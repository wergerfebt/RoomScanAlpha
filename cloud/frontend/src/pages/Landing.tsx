import { Link } from "react-router-dom";
import Layout from "../components/Layout";
import SearchBar from "../components/SearchBar";

const steps = [
  {
    icon: "📱",
    title: "Scan Your Room",
    desc: "Use the RoomScanAlpha iOS app to capture a detailed 3D scan of your space.",
  },
  {
    icon: "📋",
    title: "Describe Your Project",
    desc: "Tell us what work you need done — kitchen remodel, new flooring, bathroom renovation.",
  },
  {
    icon: "💰",
    title: "Get Competing Bids",
    desc: "Vetted local contractors review your 3D scan and submit detailed quotes.",
  },
  {
    icon: "✅",
    title: "Compare & Hire",
    desc: "Compare bids side-by-side and choose the contractor that's right for you.",
  },
];

export default function Landing() {
  return (
    <Layout>
      {/* Hero */}
      <section
        style={{
          background: "linear-gradient(180deg, #f0f4ff 0%, var(--color-bg) 100%)",
          padding: "80px 24px 60px",
          textAlign: "center",
        }}
      >
        <h1
          style={{
            fontSize: "clamp(1.8rem, 4vw, 2.8rem)",
            fontWeight: 800,
            lineHeight: 1.15,
            marginBottom: 16,
            letterSpacing: "-0.5px",
          }}
        >
          Real contractor quotes.
          <br />
          No site visits. 48 hours.
        </h1>
        <p
          style={{
            fontSize: 18,
            color: "var(--color-text-secondary)",
            maxWidth: 520,
            margin: "0 auto 36px",
          }}
        >
          Scan your room with your iPhone. Get competing bids from vetted local contractors.
        </p>

        {/* Large search bar */}
        <div style={{ display: "flex", justifyContent: "center" }}>
          <SearchBar size="large" />
        </div>
      </section>

      {/* How it works */}
      <section
        style={{
          maxWidth: "var(--max-width)",
          margin: "0 auto",
          padding: "60px 24px",
        }}
      >
        <h2
          style={{
            fontSize: 24,
            fontWeight: 700,
            textAlign: "center",
            marginBottom: 40,
          }}
        >
          How Quoterra Works
        </h2>
        <div
          style={{
            display: "grid",
            gridTemplateColumns: "repeat(auto-fit, minmax(220px, 1fr))",
            gap: 24,
          }}
        >
          {steps.map((step, i) => (
            <div
              key={i}
              className="card"
              style={{
                padding: 24,
                textAlign: "center",
              }}
            >
              <div style={{ fontSize: 36, marginBottom: 12 }}>{step.icon}</div>
              <div
                style={{
                  fontSize: 12,
                  fontWeight: 700,
                  color: "var(--color-primary)",
                  marginBottom: 8,
                  textTransform: "uppercase",
                  letterSpacing: "0.5px",
                }}
              >
                Step {i + 1}
              </div>
              <h3 style={{ fontSize: 16, fontWeight: 700, marginBottom: 8 }}>{step.title}</h3>
              <p style={{ fontSize: 14, color: "var(--color-text-secondary)", lineHeight: 1.5 }}>
                {step.desc}
              </p>
            </div>
          ))}
        </div>
      </section>

      {/* CTA */}
      <section
        style={{
          background: "var(--color-surface)",
          borderTop: "1px solid var(--color-border)",
          padding: "60px 24px",
          textAlign: "center",
        }}
      >
        <h2 style={{ fontSize: 22, fontWeight: 700, marginBottom: 12 }}>
          Ready to get started?
        </h2>
        <p
          style={{
            fontSize: 15,
            color: "var(--color-text-secondary)",
            marginBottom: 24,
            maxWidth: 400,
            margin: "0 auto 24px",
          }}
        >
          Download the RoomScanAlpha app, scan your first room, and receive bids within 48 hours.
        </p>
        <Link
          to="/login"
          className="btn btn-primary"
          style={{ padding: "14px 32px", fontSize: 16 }}
        >
          Sign Up Free
        </Link>
      </section>

      {/* Footer */}
      <footer
        style={{
          padding: "24px",
          textAlign: "center",
          fontSize: 13,
          color: "var(--color-text-muted)",
        }}
      >
        &copy; {new Date().getFullYear()} Quoterra &middot;{" "}
        <a href="mailto:jake@roomscanalpha.com" style={{ color: "var(--color-text-muted)" }}>
          Contact
        </a>
      </footer>
    </Layout>
  );
}
