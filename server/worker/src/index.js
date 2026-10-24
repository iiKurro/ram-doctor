// RAM Doctor relay - Cloudflare Worker entry point. All logic lives in ./lib.js (so it can be unit-tested in Node).
import { handle } from './lib.js';

export default {
  async fetch(request, env) {
    return handle(request, env);
  },
};
