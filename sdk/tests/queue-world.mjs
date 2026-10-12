// A World whose queue delivers the way Vercel Queues does, over world-local's
// runs, events and streams, for tests of a World that cannot tell whether a
// lease's holder runs:
//
// - a delivery holds its message until its handler returns, and the message
//   keeps its id across deliveries, each with the next attempt;
// - a handler that returns `{ timeoutSeconds }` has the message's payload
//   sent again that much later as a new message, as world-vercel does;
// - one that throws gets the same message again shortly;
// - `lapse(message)` delivers a message again while its delivery still runs,
//   as the queue does once the process holding it died or lost it;
//   `rerun(message)` runs its delivery again, attempt and all, as Vercel
//   does when a function's process exits mid-delivery; and `adopt(message)`
//   delivers here a message another of these Worlds held, as one queue
//   shared by two processes hands a message on.
//
// The test starts the World and passes it to world(), so it stays the
// test's: `closeQueueWorlds()` closes them after the agents.
import { world } from "../durable/world.mjs";

const { createWorld } = await import(new URL("../durable/node_modules/@workflow/world-local/dist/index.js", import.meta.url).href);
const opened = [];

function createBroker({ retryMs }) {
  const handlers = new Map();
  const inner = Symbol("handler");
  const timers = new Set();
  // Messages not yet acknowledged, by id.
  const messages = new Map();
  const keys = new Map();
  const sent = [];
  // Ids stay distinct across Worlds, so one can take another's message.
  const tag = crypto.randomUUID().slice(0, 8);
  let count = 0;
  let closed = false;
  const later = (fn, ms) => {
    if (closed) return;
    const timer = setTimeout(() => { timers.delete(timer); fn(); }, ms);
    timers.add(timer);
  };
  const acknowledge = (message) => {
    messages.delete(message.id);
    if (message.key !== undefined && keys.get(message.key) === message.id) keys.delete(message.key);
  };
  const send = async (queueName, payload, { delaySeconds = 0, idempotencyKey } = {}) => {
    if (idempotencyKey !== undefined && keys.has(idempotencyKey)) return { messageId: keys.get(idempotencyKey) };
    count += 1;
    const message = { id: `msg_${tag}${String(count).padStart(8, "0")}`, queueName, payload, attempt: 0, key: idempotencyKey };
    messages.set(message.id, message);
    if (idempotencyKey !== undefined) keys.set(idempotencyKey, message.id);
    sent.push(message);
    later(() => deliver(message), delaySeconds * 1000);
    return { messageId: message.id };
  };
  const deliver = (message, again = false) => {
    if (closed || !messages.has(message.id)) return;
    const prefix = [...handlers.keys()].find((name) => message.queueName.startsWith(name));
    if (prefix === undefined) return later(() => deliver(message, again), 10);
    if (!again) message.attempt += 1;
    const attempt = message.attempt;
    Promise.resolve()
      .then(() => handlers.get(prefix)(message.payload, { queueName: message.queueName, messageId: message.id, attempt }))
      .then((result) => {
        // world-vercel sends the next message before it acknowledges this
        // one, so a delivery the queue has since handed on still sends it.
        if (Number.isFinite(result?.timeoutSeconds)) void send(message.queueName, message.payload, { delaySeconds: result.timeoutSeconds });
        if (attempt === message.attempt) acknowledge(message);
      }, () => {
        if (attempt === message.attempt) later(() => deliver(message), retryMs);
      });
  };
  return {
    sent,
    // The messages not yet acknowledged whose libfx message matches.
    held(match = () => true) {
      return [...messages.values()].filter((message) => match(message.payload?.input ?? {}));
    },
    lapse(message) {
      deliver(message);
    },
    rerun(message) {
      deliver(message, true);
    },
    adopt(message) {
      const copy = { ...message };
      messages.set(copy.id, copy);
      deliver(copy);
      return copy;
    },
    queue: send,
    createQueueHandler(_prefix, handler) {
      const route = async () => new Response("this test World delivers in process", { status: 404 });
      route[inner] = handler;
      return route;
    },
    registerHandler(prefix, route) {
      handlers.set(prefix, route[inner]);
    },
    close() {
      closed = true;
      for (const timer of timers) clearTimeout(timer);
      timers.clear();
    },
  };
}

/** The durability, a World at `dir` with that queue passed to world(), and its broker. */
export async function queueWorldAt(dir, { retryMs = 20, ...options } = {}) {
  const stored = createWorld({ dataDir: dir, recoverActiveRuns: false });
  await stored.start();
  const broker = createBroker({ retryMs });
  const instance = {
    ...stored,
    queue: broker.queue,
    createQueueHandler: broker.createQueueHandler,
    registerHandler: broker.registerHandler,
    async close() {
      broker.close();
      await stored.close();
    },
  };
  opened.push(instance);
  // The broker keeps its messages in memory, so a message dies with the
  // process and prompt() stores each prompt before it sends it.
  return { durability: world(instance, { name: "queue", pollMs: 250, queueDurable: false, ...options }), broker };
}

export async function closeQueueWorlds() {
  for (const instance of opened.splice(0)) await instance.close().catch(() => {});
}
