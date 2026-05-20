# syntax=docker/dockerfile:1.7

ARG NODE_IMAGE=node:18-bookworm-slim

FROM ${NODE_IMAGE} AS keys
WORKDIR /keys
RUN node <<'NODE'
const { generateKeyPairSync } = require('node:crypto');
const fs = require('node:fs');
const { publicKey, privateKey } = generateKeyPairSync('rsa', {
  modulusLength: 2048,
  publicExponent: 0x10001,
});
fs.writeFileSync('/keys/gingko-keys.json', JSON.stringify({
  publicKey: publicKey.export({ format: 'jwk' }),
  privateKey: privateKey.export({ format: 'jwk' }),
}, null, 2));
NODE

FROM ${NODE_IMAGE} AS client-builder
RUN apt-get update \
  && apt-get install -y --no-install-recommends git ca-certificates python3 make g++ curl unzip \
  && rm -rf /var/lib/apt/lists/* \
  && curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:$PATH"
WORKDIR /build
ARG GINGKO_CLIENT_REF=master
ARG PUBLIC_URL=http://localhost:3000
RUN GIT_HTTP_LOW_SPEED_LIMIT=1024 GIT_HTTP_LOW_SPEED_TIME=30 \
    git clone --depth 1 --branch "$GINGKO_CLIENT_REF" https://github.com/gingko/client.git client \
    || GIT_HTTP_LOW_SPEED_LIMIT=1024 GIT_HTTP_LOW_SPEED_TIME=30 \
    git clone --depth 1 --branch "$GINGKO_CLIENT_REF" https://github.com/gingko/client.git client
WORKDIR /build/client
COPY --from=keys /keys/gingko-keys.json /tmp/gingko-keys.json
RUN cat > /tmp/make-client-config.js <<'BUN'
const fs = require('node:fs');
const keys = JSON.parse(fs.readFileSync('/tmp/gingko-keys.json', 'utf8'));
const publicUrl = process.env.PUBLIC_URL || 'http://localhost:3000';
const config = {
  TEST_SERVER: publicUrl,
  PRODUCTION_SERVER: 'https://gingko-selfhost.invalid',
  HOMEPAGE_URL: publicUrl,
  COUCHDB_HOST: 'couchdb',
  COUCHDB_PORT: '5984',
  COUCHDB_SERVER: `${publicUrl}/db`,
  PUBLIC_KEY: keys.publicKey,
  SUPPORT_EMAIL: 'support@localhost',
  SUPPORT_URGENT_EMAIL: 'urgent@localhost',
  FRESHDESK_APPID: 0,
  BEAMER_APPID: 'disabled',
  LOGROCKET_APPID: 'disabled/disabled',
  TESTIMONIAL_URL: publicUrl,
  DESKTOP_SERIAL_SALT: 'selfhost',
  DESKTOP_PURCHASE_URL: publicUrl,
  DESKTOP_PURCHASE_SUCCESS_URL: publicUrl,
  STRIPE_PUBLIC_KEY: 'pk_test_selfhost000000000000000000000000',
  PRICE_DATA: {
    USD: {
      monthly: { discount: 'price_selfhost', regular: 'price_selfhost', bonus: 'price_selfhost' },
      yearly: { discount: 'price_selfhost', regular: 'price_selfhost', bonus: 'price_selfhost' },
    },
  },
};
fs.writeFileSync('config.js', `module.exports = ${JSON.stringify(config, null, 2)};\n`);
BUN
RUN PUBLIC_URL="$PUBLIC_URL" bun /tmp/make-client-config.js
RUN bun install
RUN chmod +x elm-log-colors.sh || true
RUN bun run newbuild

FROM ${NODE_IMAGE} AS server-builder
RUN apt-get update \
  && apt-get install -y --no-install-recommends git ca-certificates python3 python3-setuptools make g++ \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /build
ARG GINGKO_SERVER_REF=master
RUN GIT_HTTP_LOW_SPEED_LIMIT=1024 GIT_HTTP_LOW_SPEED_TIME=30 \
    git clone --depth 1 --branch "$GINGKO_SERVER_REF" https://github.com/gingko/server.git server \
    || GIT_HTTP_LOW_SPEED_LIMIT=1024 GIT_HTTP_LOW_SPEED_TIME=30 \
    git clone --depth 1 --branch "$GINGKO_SERVER_REF" https://github.com/gingko/server.git server
WORKDIR /build/server
COPY --from=keys /keys/gingko-keys.json /tmp/gingko-keys.json
RUN node <<'NODE'
const fs = require('node:fs');
const keys = JSON.parse(fs.readFileSync('/tmp/gingko-keys.json', 'utf8'));
const configSource = `export default {
  COUCHDB_USER: process.env.COUCHDB_USER || 'admin',
  COUCHDB_PASS: process.env.COUCHDB_PASSWORD || process.env.COUCHDB_PASS || 'admin',
  COUCHDB_SECRET: process.env.COUCHDB_SECRET || 'selfhost-couch-secret',
  SESSION_SECRET: process.env.SESSION_SECRET || 'selfhost-session-secret',
  PRIVATE_KEY: ${JSON.stringify(keys.privateKey, null, 2)},
  MAILGUN_API_KEY: process.env.MAILGUN_API_KEY || 'disabled',
  MAILGUN_DOMAIN: process.env.MAILGUN_DOMAIN || 'disabled.local',
  MAILERLITE_API_KEY: process.env.MAILERLITE_API_KEY || 'disabled',
  SUPPORT_EMAIL: process.env.SUPPORT_EMAIL || 'support@localhost',
  SUPPORT_URGENT_EMAIL: process.env.SUPPORT_URGENT_EMAIL || 'urgent@localhost',
  URGENT_MESSAGE_SUBJECT: 'Urgent message received',
  URGENT_MESSAGE_BODY: 'This self-hosted Gingko instance has no configured outbound mail.',
  NTFY_URL: process.env.NTFY_URL || 'https://ntfy.sh/gingko-selfhost-disabled',
  STRIPE_SECRET_KEY: process.env.STRIPE_SECRET_KEY || 'sk_test_selfhost000000000000000000000000',
  URL_ROOT: process.env.PUBLIC_URL || 'http://localhost:3000',
  ANTHROPIC_API_KEY: process.env.ANTHROPIC_API_KEY || '',
};
`;
fs.writeFileSync('config.js', configSource);

const indexFile = 'src/index.ts';
let s = fs.readFileSync(indexFile, 'utf8');
const patches = [
  [
    /const nano = Nano\(`http:\/\/\$\{config\.COUCHDB_USER\}:\$\{config\.COUCHDB_PASS\}@127\.0\.0\.1:5984`\);/,
    "const couchHost = process.env.COUCHDB_HOST || 'couchdb'; const couchPort = process.env.COUCHDB_PORT || '5984'; const nano = Nano(`http://${config.COUCHDB_USER}:${config.COUCHDB_PASS}@${couchHost}:${couchPort}`);",
    'CouchDB host patch',
  ],
  [
    /const redis = createClient\(\{legacyMode: true\}\);/,
    "const redis = createClient({ legacyMode: true, url: process.env.REDIS_URL || 'redis://redis:6379' });",
    'Redis URL patch',
  ],
  [
    /app\.use\('\/db', proxy\('http:\/\/127\.0\.0\.1:5984', \{/,
    "app.use('/db', proxy(`http://${couchHost}:${couchPort}`, {",
    'CouchDB proxy patch',
  ],
  [
    /"trial:" \+ trialExpiry/g,
    '"customer:selfhost"',
    'Self-host paid-account patch',
  ],
];
for (const [pattern, replacement, name] of patches) {
  const before = s;
  s = s.replace(pattern, replacement);
  if (s === before) {
    throw new Error(`${name} failed; upstream source changed.`);
  }
}
fs.writeFileSync(indexFile, s);
NODE
RUN npm ci
RUN npm run build
RUN npm prune --omit=dev

FROM ${NODE_IMAGE} AS runtime
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates pandoc \
  && rm -rf /var/lib/apt/lists/*
ENV NODE_ENV=production \
    PORT=3000 \
    COUCHDB_HOST=couchdb \
    COUCHDB_PORT=5984 \
    REDIS_URL=redis://redis:6379
WORKDIR /app
COPY --from=server-builder /build/server /app/server
COPY --from=client-builder /build/client/web /app/client/web
RUN mkdir -p /app/data
VOLUME ["/app/data"]
WORKDIR /app/server
EXPOSE 3000
CMD ["node", "dist/index.js"]
