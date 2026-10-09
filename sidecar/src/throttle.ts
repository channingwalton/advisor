/// Rate-limit `fn` to one call per `intervalMs`. The first request runs at once;
/// requests within the interval collapse into one trailing call, so `fn` should
/// read the latest state when it runs rather than take it as an argument.
export function throttle(fn: () => void, intervalMs: number): { request(): void; cancel(): void } {
  let last = -Infinity;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const fire = (): void => {
    timer = undefined;
    last = Date.now();
    fn();
  };
  return {
    request() {
      if (timer) return;
      const wait = last + intervalMs - Date.now();
      if (wait <= 0) fire();
      else timer = setTimeout(fire, wait);
    },
    /// Drop a pending trailing call.
    cancel() {
      clearTimeout(timer);
      timer = undefined;
    },
  };
}
