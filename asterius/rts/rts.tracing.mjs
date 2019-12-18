import { performance } from "perf_hooks";

export class Tracer {
  constructor(logger, syms, gcStatistics) {
    this.logger = logger;
    this.symbolLookupTable = {};
    for (const [k, v] of Object.entries(syms)) this.symbolLookupTable[v] = k;
    this.gcStatistics = gcStatistics;
    this.counters = {
      gc_wall_s: 0,
      num_minor_GCs: 0,
      num_major_GCs: 0,
      liveMBlocksNo: [],
      aliveVSDeadMBlocks: [],
      allocatedMBlocks: 0
    };
    Object.freeze(this);
  }

  /**
   * Force @param arg to be evaluated, i.e.
   * in case it is a callback, @param arg is called
   * and the result returned. Useful when tracing/logging
   * data that is expensive to compute, so that the actual
   * value is computed only if the logging level is
   * appropriate.
   */
  static force(arg) {
    if (typeof arg === "function") {
      return arg();
    } else {
      return arg;
    }
  }

  /**
   * Return the number of seconds passed since
   * the app has started.
   */
  now() {
    return performance.now() / 1000.0;
  }

  traceCmm(f) {
    this.logger.logInfo(["call", f, this.symbolLookupTable[f]]);
  }

  traceCmmBlock(f, lbl) {
    this.logger.logInfo(["br", f, this.symbolLookupTable[f], lbl]);
  }

  traceCmmSetLocal(f, i, v) {
    this.logger.logInfo([
      "set_local",
      f,
      this.symbolLookupTable[f],
      i,
      v,
      this.symbolLookupTable[v]
    ]);
  }

  /**
   * Trace the end of the initialization of
   * the runtime system (INIT)
   */
  traceInitDone() {
    if (!this.gcStatistics) return;
    this.counters.init_wall_s = this.now();
  }

  /**
   * Trace the end of a garbage collection.
   * @param beginTime is the time when the GC has started
   */
  traceMinorGC(beginTime) {
    if (!this.gcStatistics) return;
    this.counters.gc_wall_s += this.now() - Tracer.force(beginTime);
    this.counters.num_minor_GCs += 1;
  }

  /**
   * Trace the end of a garbage collection.
   * @param beginTime is the time when the GC has started
   */
  traceMajorGC(beginTime) {
    if (!this.gcStatistics) return;
    this.counters.gc_wall_s += this.now() - Tracer.force(beginTime);
    this.counters.num_major_GCs += 1;
  }

  /**
   * Trace the number of megablocks that are found to be
   * alive during a garbage collection.
   */
  traceAliveDeadMBlocks(arg) {
    if (!this.gcStatistics) return;
    arg = Tracer.force(arg);
    this.counters.liveMBlocksNo.push(arg.alive);
    this.counters.aliveVSDeadMBlocks.push(arg.alive / arg.dead);
  }

  /**
   * Trace the allocation of new megablocks.
   * Called from {@link Memory.getMBlocks}
   * @param n The number of newly allocated megablocks
   */
  traceGetMBlocks(n) {
    if (!this.gcStatistics) return;
    this.counters.allocatedMBlocks += Tracer.force(n);
  }

  /**
   * Display various GC statistics.
   */
  displayGCStatistics() {
    if (!this.gcStatistics) return;
    var counters = this.counters;
    var total_wall_s = this.now();
    var gc_wall_s = counters.gc_wall_s;
    var mutator_wall_s = total_wall_s - gc_wall_s - counters.init_wall_s;
    var totalLiveMBlocksNo = 0;
    for(const n of counters.liveMBlocksNo) {
      totalLiveMBlocksNo += n;
    }
    var liveMBlocksAverageNo = "n/a";
    if (counters.liveMBlocksNo.length != 0) 
      liveMBlocksAverageNo = totalLiveMBlocksNo / counters.liveMBlocksNo.length;
    var aliveVSDeadMBlocks = 0;
    for(const n of counters.aliveVSDeadMBlocks) {
      aliveVSDeadMBlocks += n;
    }
    if (counters.aliveVSDeadMBlocks.length == 0) {
      aliveVSDeadMBlocks = "n/a";
    } else {
      aliveVSDeadMBlocks /= counters.aliveVSDeadMBlocks.length;
    }
    console.log("Garbage Collection Statistics", {
      num_major_GCs: counters.num_major_GCs,
      num_minor_GCs: counters.num_minor_GCs,
      average_live_mblocks: liveMBlocksAverageNo,
      alive_vs_dead_mblocks: aliveVSDeadMBlocks,
      allocated_mblocks: counters.allocatedMBlocks,
      init_wall_seconds: counters.init_wall_s,
      mutator_wall_seconds: mutator_wall_s,
      GC_wall_seconds: gc_wall_s,
    });
  }
}
