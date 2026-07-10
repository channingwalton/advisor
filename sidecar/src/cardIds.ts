import { randomUUID } from "node:crypto";

/// Allocates opaque card ids that remain unique when the Swift app retains cards
/// across a sidecar restart. The UUID identifies this process incarnation; the
/// counter only provides compact ordering within it.
export class ProcessCardIDs {
  private counter = 0;

  constructor(private readonly instanceId: string = randomUUID()) {}

  next(): string {
    return `${this.instanceId}:c${++this.counter}`;
  }
}
