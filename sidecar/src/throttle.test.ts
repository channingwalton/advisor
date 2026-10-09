import { test } from "node:test";
import assert from "node:assert/strict";
import { throttle } from "./throttle.js";

test("#card-token-stream the first request runs at once", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"] });
  let calls = 0;
  const th = throttle(() => calls++, 100);
  th.request();
  assert.equal(calls, 1);
});

test("#card-token-stream requests within the interval collapse into one trailing call", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"] });
  let calls = 0;
  const th = throttle(() => calls++, 100);
  th.request();
  th.request();
  th.request();
  assert.equal(calls, 1);
  t.mock.timers.tick(99);
  assert.equal(calls, 1);
  t.mock.timers.tick(1);
  assert.equal(calls, 2);
  t.mock.timers.tick(500);
  assert.equal(calls, 2);
});

test("#card-token-stream a request after a quiet interval runs at once", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"] });
  let calls = 0;
  const th = throttle(() => calls++, 100);
  th.request();
  t.mock.timers.tick(150);
  th.request();
  assert.equal(calls, 2);
});

test("#card-token-stream cancel drops the pending trailing call", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"] });
  let calls = 0;
  const th = throttle(() => calls++, 100);
  th.request();
  th.request();
  th.cancel();
  t.mock.timers.tick(500);
  assert.equal(calls, 1);
});
