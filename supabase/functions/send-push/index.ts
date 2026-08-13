import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const FCM_API_URL = "https://fcm.googleapis.com/v1/projects/YOUR_PROJECT_ID/messages:send";

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
      },
    });
  }

  try {
    const { token, title, body } = await req.json();

    // Get FCM service account key from Supabase secrets
    const fcmKey = Deno.env.get("FCM_SERVICE_ACCOUNT_KEY");
    if (!fcmKey) throw new Error("FCM_SERVICE_ACCOUNT_KEY not set");

    const serviceAccount = JSON.parse(fcmKey);

    // Get OAuth2 access token
    const now = Math.floor(Date.now() / 1000);
    const jwtHeader = btoa(JSON.stringify({ alg: "RS256", typ: "JWT" }));
    const jwtClaimSet = JSON.stringify({
      iss: serviceAccount.client_email,
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      aud: "https://oauth2.googleapis.com/token",
      iat: now,
      exp: now + 3600,
    });
    const enc = new TextEncoder();

    // Sign JWT with service account private key
    const keyData = serviceAccount.private_key;
    const pemBody = keyData.replace(/-----BEGIN PRIVATE KEY-----/, "").replace(/-----END PRIVATE KEY-----/, "").replace(/\s/g, "");
    const binaryDer = Uint8Array.from(atob(pemBody), (c) => c.charCodeAt(0));

    const privateKey = await crypto.subtle.importKey(
      "pkcs8",
      binaryDer,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["sign"]
    );

    const dataToSign = enc.encode(`${jwtHeader}.${btoa(jwtClaimSet).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_")}`);
    const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", privateKey, dataToSign);
    const jwt = `${jwtHeader}.${btoa(jwtClaimSet).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_")}.${btoa(String.fromCharCode(...new Uint8Array(signature))).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_")}`;

    const tokenRes = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: `grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=${jwt}`,
    });
    const { access_token } = await tokenRes.json();

    // Send FCM message
    const fcmRes = await fetch(FCM_API_URL, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${access_token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        message: {
          token,
          notification: { title, body },
          android: { priority: "high", notification: { channel_id: "bus_updates" } },
          apns: { payload: { aps: { "content-available": 1, sound: "default" } } },
        },
      }),
    });

    const fcmData = await fcmRes.json();
    return new Response(JSON.stringify(fcmData), {
      headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" },
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: e.message }), {
      status: 500,
      headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" },
    });
  }
});
