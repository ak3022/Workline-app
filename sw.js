// Amber Process Tracker — service worker for push notifications.
// This file must be deployed at the root of the site (same folder as
// index.html) for its notification scope to cover the whole app.

self.addEventListener('push', (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch (e) { data = { title: 'Amber Process Tracker', body: event.data ? event.data.text() : '' }; }
  event.waitUntil(
    self.registration.showNotification(data.title || 'Amber Process Tracker', {
      body: data.body || '',
      tag: data.tag || 'amber-reminder',
      renotify: true,
      data: { url: data.url || '/' },
    })
  );
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then((list) => {
      for (const client of list) { if ('focus' in client) return client.focus(); }
      if (clients.openWindow) return clients.openWindow(event.notification.data.url || '/');
    })
  );
});

// Required for the browser to treat this as a valid, installable service worker
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));
