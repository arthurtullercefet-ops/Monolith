const CACHE_NAME = "monolith-v71-profile-edit";

self.addEventListener("install", event => {
  self.skipWaiting();
});

self.addEventListener("activate", event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(key => key.startsWith("monolith-")).map(key => caches.delete(key))))
      .then(() => self.registration.unregister())
  );
});
