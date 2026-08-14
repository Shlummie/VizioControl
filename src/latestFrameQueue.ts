export interface PreparedFrame {
  commit(): void;
  discard?(): void;
}

/**
 * Decodes one frame at a time while retaining only the newest frame waiting
 * behind it. A prepared frame is committed before the next decode begins, so
 * a slow decoder cannot starve the visible viewport.
 */
export class LatestFrameQueue<T> {
  private pending: { value: T; generation: number } | null = null;
  private pumping = false;
  private stopped = false;
  private generation = 0;

  constructor(private readonly prepare: (value: T) => Promise<PreparedFrame>) {}

  push(value: T) {
    if (this.stopped) return;
    this.pending = { value, generation: this.generation };
    if (!this.pumping) void this.pump();
  }

  clear() {
    if (this.stopped) return;
    this.generation += 1;
    this.pending = null;
  }

  stop() {
    this.stopped = true;
    this.generation += 1;
    this.pending = null;
  }

  private async pump() {
    this.pumping = true;
    try {
      while (!this.stopped && this.pending) {
        const candidate = this.pending;
        this.pending = null;
        let prepared: PreparedFrame;
        try {
          prepared = await this.prepare(candidate.value);
        } catch {
          continue;
        }
        if (this.stopped || candidate.generation !== this.generation) {
          prepared.discard?.();
          continue;
        }
        prepared.commit();
      }
    } finally {
      this.pumping = false;
      if (!this.stopped && this.pending) void this.pump();
    }
  }
}
