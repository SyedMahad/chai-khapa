/* Chai Khapa: conservative offline support.
 * Never cache private Supabase API responses, OAuth redirects, group data or ledger records.
 * Route navigations use network first and a generic offline page on failure.
 */
const CACHE = 'chai-khapa-static-v1';
const PRELOAD = ['/offline.html', '/manifest.webmanifest', '/icons/chai-khapa-192.png', '/icons/chai-khapa-512.png'];
self.addEventListener('install', event => {
  event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(PRELOAD)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', event => {
  event.waitUntil(Promise.all([caches.keys().then(keys => Promise.all(keys.filter(key => key !== CACHE).map(key => caches.delete(key)))), self.clients.claim()]));
});
self.addEventListener('fetch', event => {
  const request = event.request;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;
  if (request.mode === 'navigate') {
    event.respondWith(fetch(request).catch(() => caches.match('/offline.html')));
    return;
  }
  if (!(/\.(?:css|js|png|svg|webmanifest|woff2)$/.test(url.pathname))) return;
  // Network first prevents an old CSS/theme or JS bundle from persisting after deployment.
  event.respondWith(fetch(request).then(response => {
    if (response.ok && response.type === 'basic') {
      const copy = response.clone();
      void caches.open(CACHE).then(cache => cache.put(request, copy));
    }
    return response;
  }).catch(() => caches.match(request)));

});
