const { onRequest } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const { defineSecret } = require("firebase-functions/params");

admin.initializeApp();
// v2 - redeploy with Firestore enabled
const db = admin.firestore();

const sendgridApiKey = defineSecret("SENDGRID_API_KEY");

// TODO: Replace with your actual TestFlight public link
const TESTFLIGHT_LINK = "https://testflight.apple.com/join/PLACEHOLDER";

function buildEmailHtml() {
  return `
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
</head>
<body style="margin:0; padding:0; background:#f5f5f7; font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;">
  <table width="100%" cellpadding="0" cellspacing="0" style="background:#f5f5f7; padding:40px 20px;">
    <tr>
      <td align="center">
        <table width="100%" cellpadding="0" cellspacing="0" style="max-width:520px; background:#ffffff; border-radius:16px; overflow:hidden; box-shadow:0 2px 12px rgba(0,0,0,0.06);">
          <!-- Header -->
          <tr>
            <td style="padding:36px 32px 24px; text-align:center; background:linear-gradient(180deg,#f0f4ff,#ffffff);">
              <h1 style="margin:0; font-size:24px; font-weight:700; color:#1d1d1f;">Welcome to Room Scan <span style="color:#0066cc;">Alpha</span></h1>
              <p style="margin:12px 0 0; font-size:15px; color:#6e6e73; line-height:1.5;">Thanks for signing up! You're in. Here's how to get the app on your iPhone.</p>
            </td>
          </tr>
          <!-- Steps -->
          <tr>
            <td style="padding:8px 32px 24px;">
              <table width="100%" cellpadding="0" cellspacing="0">
                <tr>
                  <td style="padding:16px 0; border-bottom:1px solid #f0f0f3;">
                    <p style="margin:0 0 4px; font-size:12px; font-weight:600; color:#0066cc; text-transform:uppercase; letter-spacing:0.5px;">Step 1</p>
                    <p style="margin:0; font-size:15px; color:#1d1d1f; line-height:1.5;">If you don't have <strong>TestFlight</strong> installed, <a href="https://apps.apple.com/app/testflight/id899247664" style="color:#0066cc; text-decoration:none; font-weight:500;">download it from the App Store</a>. It's Apple's official app for beta testing.</p>
                  </td>
                </tr>
                <tr>
                  <td style="padding:16px 0; border-bottom:1px solid #f0f0f3;">
                    <p style="margin:0 0 4px; font-size:12px; font-weight:600; color:#0066cc; text-transform:uppercase; letter-spacing:0.5px;">Step 2</p>
                    <p style="margin:0; font-size:15px; color:#1d1d1f; line-height:1.5;">Tap the button below to join the RoomScanAlpha beta. If you just installed TestFlight, you may need to tap it a second time.</p>
                  </td>
                </tr>
              </table>
            </td>
          </tr>
          <!-- CTA Button -->
          <tr>
            <td style="padding:0 32px 32px; text-align:center;">
              <a href="${TESTFLIGHT_LINK}" style="display:inline-block; padding:14px 36px; font-size:16px; font-weight:600; color:#ffffff; background:#0066cc; border-radius:12px; text-decoration:none;">Join the Beta</a>
            </td>
          </tr>
          <!-- Footer note -->
          <tr>
            <td style="padding:0 32px 32px; text-align:center;">
              <p style="margin:0; font-size:13px; color:#86868b; line-height:1.5;">Questions or feedback? Reply to this email or reach us at <a href="mailto:jake@roomscanalpha.com" style="color:#0066cc; text-decoration:none;">jake@roomscanalpha.com</a></p>
            </td>
          </tr>
        </table>
        <!-- Sub-footer -->
        <p style="margin:20px 0 0; font-size:12px; color:#86868b; text-align:center;">&copy; 2026 Quoterra. All rights reserved.</p>
      </td>
    </tr>
  </table>
</body>
</html>`;
}

exports.signup = onRequest(
  { cors: true, secrets: [sendgridApiKey] },
  async (req, res) => {
    if (req.method !== "POST") {
      res.status(405).json({ error: "Method not allowed" });
      return;
    }

    const { email } = req.body;
    if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      res.status(400).json({ error: "Valid email required" });
      return;
    }

    try {
      // Store signup in Firestore
      await db.collection("signups").add({
        email,
        timestamp: admin.firestore.FieldValue.serverTimestamp(),
      });

      // Send welcome email via SendGrid
      const response = await fetch("https://api.sendgrid.com/v3/mail/send", {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${sendgridApiKey.value()}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          personalizations: [{ to: [{ email }] }],
          from: { email: "info@roomscanalpha.com", name: "Room Scan Alpha" },
          subject: "Welcome to Room Scan Alpha — Here's Your Beta Access",
          content: [{ type: "text/html", value: buildEmailHtml() }],
        }),
      });

      if (!response.ok) {
        const err = await response.text();
        console.error("SendGrid error:", err);
        throw new Error("Email send failed");
      }

      res.status(200).json({ success: true });
    } catch (err) {
      console.error("Signup error:", err);
      res.status(500).json({ error: "Something went wrong. Please try again." });
    }
  }
);
