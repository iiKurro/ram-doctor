// RAM Doctor relay - Cloudflare Worker entry point. All logic lives in ./lib.js (so it can be unit-tested in Node).
import { handle } from './lib.js';

export default {
  async fetch(request, env, ctx) {
    // waitUntil lets an accepted upload finish its commit and bookkeeping even if the client disconnects meanwhile
    const deps = {};
    if (ctx && typeof ctx.waitUntil === 'function') deps.waitUntil = (p) => ctx.waitUntil(p);
    return handle(request, env, deps);
  },
};
