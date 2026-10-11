// `libfx/chatgpt`: sign in with ChatGPT for a Codex agent. Two flows, both
// plain data between steps so a website can start in one request and finish in
// another:
//
// - Paste the address: the user signs in on OpenAI, lands on a page at
//   localhost:1455 that does not load, and pastes its address back.
// - Device code: the user enters a short code on OpenAI's page. ChatGPT
//   workspaces and accounts must turn device code sign-in on first.
import { chatgptClientId, chatgptIssuer, normalizeChatgptCredentials, refreshChatgptCredentials } from "./chatgpt.js";

const redirectUri = "http://localhost:1455/auth/callback";
const deviceRedirectUri = `${chatgptIssuer}/deviceauth/callback`;
const scope = "openid profile email offline_access api.connectors.read api.connectors.invoke";
const deviceCodeLifetimeMs = 15 * 60 * 1000;
const maxAddressBytes = 16 * 1024;
const encoder = new TextEncoder();

function signInError(code, message, fields = {}) {
  const error = new Error(message);
  error.code = code;
  return Object.assign(error, fields);
}

const base64url = (bytes) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const randomSecret = () => base64url(crypto.getRandomValues(new Uint8Array(32)));
const hostFetch = (fetch) => fetch ?? globalThis.fetch?.bind(globalThis);

/** Starts a sign-in. Keep the result on the server: `verifier` is secret. */
export async function startSignIn() {
  const verifier = randomSecret();
  const state = randomSecret();
  const challenge = base64url(new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(verifier))));
  const url = new URL(`${chatgptIssuer}/oauth/authorize`);
  for (const [key, value] of Object.entries({
    response_type: "code",
    client_id: chatgptClientId,
    redirect_uri: redirectUri,
    scope,
    code_challenge: challenge,
    code_challenge_method: "S256",
    id_token_add_organizations: "true",
    codex_cli_simplified_flow: "true",
    state,
    originator: "fx",
  })) url.searchParams.set(key, value);
  return { url: url.href, state, verifier };
}

/**
 * Reads the sign-in result from a pasted address: the whole address, its query,
 * or either wrapped in quotes, backticks or angle brackets.
 */
function parseSignInAddress(text) {
  if (typeof text !== "string" || encoder.encode(text).length > maxAddressBytes) {
    throw signInError("LIBFX_CHATGPT_SIGN_IN_INVALID_ADDRESS", "Paste the address of the page OpenAI opened after you signed in.");
  }
  const trimmed = text.trim().replace(/^[`'"<\s]+|[`'">\s]+$/g, "");
  let params;
  try {
    params = new URL(trimmed).searchParams;
  } catch {
    params = new URLSearchParams(trimmed.includes("?") ? trimmed.slice(trimmed.indexOf("?") + 1) : trimmed);
  }
  const error = params.get("error");
  if (error) {
    throw signInError("LIBFX_CHATGPT_SIGN_IN_DENIED", `OpenAI did not sign you in: ${params.get("error_description") || error}`, { reason: error });
  }
  const code = params.get("code");
  if (!code) {
    throw signInError(
      "LIBFX_CHATGPT_SIGN_IN_INVALID_ADDRESS",
      `That address has no sign-in code. Copy the whole address of the page OpenAI opened after you signed in; it starts with ${redirectUri}?code=`,
    );
  }
  return { code, state: params.get("state") };
}

async function exchangeCode({ code, verifier, redirect, fetch, signal }) {
  const response = await hostFetch(fetch)(`${chatgptIssuer}/oauth/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "authorization_code", client_id: chatgptClientId, code, code_verifier: verifier, redirect_uri: redirect }).toString(),
    signal,
  });
  if (response.status === 400 || response.status === 401) {
    await response.body?.cancel().catch(() => {});
    throw signInError("LIBFX_CHATGPT_SIGN_IN_EXPIRED", "This sign-in expired or was already used. Start again.", { status: response.status });
  }
  if (!response.ok) {
    await response.body?.cancel().catch(() => {});
    throw signInError("LIBFX_CHATGPT_SIGN_IN_FAILED", `OpenAI could not finish the sign-in (HTTP ${response.status}).`, { status: response.status });
  }
  const tokens = await response.json();
  return normalizeChatgptCredentials({
    accessToken: tokens.access_token,
    refreshToken: tokens.refresh_token,
    ...(Number.isFinite(tokens.expires_in) ? { expiresAt: Date.now() + tokens.expires_in * 1000 } : {}),
  });
}

/** Finishes a sign-in from the address the user pasted. */
export async function finishSignIn(signIn, address, { fetch, signal } = {}) {
  if (!signIn || typeof signIn.state !== "string" || typeof signIn.verifier !== "string") {
    throw new TypeError("finishSignIn() needs the object startSignIn() returned");
  }
  const { code, state } = parseSignInAddress(address);
  if (state !== signIn.state) {
    throw signInError("LIBFX_CHATGPT_SIGN_IN_STATE_MISMATCH", "That address is from a different sign-in. Start again and paste the address from this one.");
  }
  return exchangeCode({ code, verifier: signIn.verifier, redirect: redirectUri, fetch, signal });
}

/** Starts a device code sign-in. Show `userCode` and `verificationUrl`. */
export async function startDeviceSignIn({ fetch, signal } = {}) {
  const response = await hostFetch(fetch)(`${chatgptIssuer}/api/accounts/deviceauth/usercode`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ client_id: chatgptClientId }),
    signal,
  });
  if (!response.ok) {
    await response.body?.cancel().catch(() => {});
    throw signInError("LIBFX_CHATGPT_DEVICE_CODE_UNAVAILABLE", `OpenAI did not issue a device code (HTTP ${response.status}).`, { status: response.status });
  }
  const body = await response.json();
  const userCode = body.user_code ?? body.usercode;
  if (typeof userCode !== "string" || typeof body.device_auth_id !== "string") {
    throw signInError("LIBFX_CHATGPT_DEVICE_CODE_UNAVAILABLE", "OpenAI returned a device code response libfx does not understand.");
  }
  const interval = Number(body.interval);
  return {
    verificationUrl: `${chatgptIssuer}/codex/device`,
    userCode,
    deviceAuthId: body.device_auth_id,
    intervalMs: Math.max(Number.isFinite(interval) ? interval : 5, 1) * 1000,
    expiresAt: Date.now() + deviceCodeLifetimeMs,
  };
}

/** Checks a device sign-in once: credentials when the user has entered the code, otherwise null. */
export async function pollDeviceSignIn(device, { fetch, signal } = {}) {
  if (!device || typeof device.deviceAuthId !== "string" || typeof device.userCode !== "string") {
    throw new TypeError("pollDeviceSignIn() needs the object startDeviceSignIn() returned");
  }
  if (Date.now() > device.expiresAt) {
    throw signInError(
      "LIBFX_CHATGPT_DEVICE_CODE_EXPIRED",
      "The code expired before it was entered. If OpenAI's page said device code sign-in is off, turn it on in ChatGPT's security settings, or ask your workspace admin.",
    );
  }
  const response = await hostFetch(fetch)(`${chatgptIssuer}/api/accounts/deviceauth/token`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ device_auth_id: device.deviceAuthId, user_code: device.userCode }),
    signal,
  });
  if (response.status === 403 || response.status === 404) {
    await response.body?.cancel().catch(() => {});
    return null;
  }
  if (!response.ok) {
    await response.body?.cancel().catch(() => {});
    throw signInError("LIBFX_CHATGPT_SIGN_IN_FAILED", `OpenAI could not finish the sign-in (HTTP ${response.status}).`, { status: response.status });
  }
  const grant = await response.json();
  return exchangeCode({ code: grant.authorization_code, verifier: grant.code_verifier, redirect: deviceRedirectUri, fetch, signal });
}

/** Waits until the user enters the code, polling at OpenAI's interval. */
export async function completeDeviceSignIn(device, { fetch, signal } = {}) {
  for (;;) {
    const credentials = await pollDeviceSignIn(device, { fetch, signal });
    if (credentials) return credentials;
    await new Promise((resolve, reject) => {
      if (signal?.aborted) return reject(signal.reason ?? new DOMException("Aborted", "AbortError"));
      const timer = setTimeout(() => { signal?.removeEventListener("abort", onAbort); resolve(); }, device.intervalMs);
      const onAbort = () => { clearTimeout(timer); reject(signal.reason ?? new DOMException("Aborted", "AbortError")); };
      signal?.addEventListener("abort", onAbort, { once: true });
    });
  }
}

/** Refreshes credentials. Codex agents refresh on their own; this is for hosts. */
export function refreshCredentials(credentials, { fetch, signal } = {}) {
  return refreshChatgptCredentials(normalizeChatgptCredentials(credentials), { fetch, signal });
}
