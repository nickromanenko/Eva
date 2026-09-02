// The one place the email-link pages talk to the Eva API.
//
// Any HTTP response — 200 or an `{ error: { code, message } }` body — comes back
// as a value so the page can map the code. It throws only when no response
// arrived at all (offline, DNS, the API down, CORS refused), which the pages
// show as a retry. No cookies are sent or accepted, and nothing here logs:
// the request carries a one-time token.
export async function callAuthApi(base, path, init = {}) {
  // An unset base (no PUBLIC_API_BASE_URL at build time) hits the site's own
  // origin, which has no API — the caller shows its retry state.
  const response = await fetch((base ?? '').replace(/\/+$/, '') + path, {
    ...init,
    credentials: 'omit',
    cache: 'no-store',
  });
  const body = await response.json().catch(() => null);
  if (response.ok) return { ok: true, body };
  return {
    ok: false,
    code: body?.error?.code ?? 'UNKNOWN',
    message: body?.error?.message ?? '',
  };
}

// Reads the token out of the URL **fragment** and then strips it, so it does not
// survive in history, a bookmark, or a screenshot. It lives only in the caller's
// local variable from here on.
//
// The fragment, not the query string, and that is the whole point: a fragment is
// never sent to a server, so the token appears in no access log — not Firebase
// Hosting's for this page, not the API's for the call behind it, and not in a
// `Referer` to anything this page loads. A reset link is a live credential for an
// hour; a query string would have put it in two sets of retained logs. `email.ts`
// on the API side builds the links to match.
export function readTokenAndScrubUrl() {
  const token = new URLSearchParams(location.hash.replace(/^#/, '')).get('token');
  if (location.hash || location.search) {
    history.replaceState(null, '', location.pathname);
  }
  return token;
}

// Swaps the visible state and moves focus to its heading, so a screen reader
// announces the outcome without a live region.
export function showState(root, name) {
  for (const el of root.querySelectorAll('[data-state]')) {
    el.hidden = el.dataset.state !== name;
  }
  root.querySelector(`[data-state="${name}"] h1`)?.focus();
}
