import { performance } from "perf_hooks";

export class Tracer {
  constructor(logger, syms, gcStatistics) {
    this.logger = logger;
    this.symbolLookupTable = {};
    this.gcStatistics = gcStatistics;
    for (const [k, v] of Object.entries(syms)) this.symbolLookupTable[v] = k;
    this.stats = {
      gc_wall_ms: 0,
      num_minor_GCs: 0,
      num_major_GCs: 0,
      liveMBlocksNo: [],
      aliveVSDeadMBlocks: [],
      allocatedMBlocks: 0
    };
    Object.freeze(this);
  }

  now() {
    return performance.now();
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

  traceInitDone() {
    this.stats.init_wall_ms = this.now();
  }

  traceMinorGC(beginTime) {
    this.stats.gc_wall_ms += this.now() - beginTime;
    this.stats.num_minor_GCs += 1;
  }

  traceMajorGC(beginTime) {
    this.stats.gc_wall_ms += this.now() - beginTime;
    this.stats.num_major_GCs += 1;
  }

  traceLiveMBlocksNo(liveMBlocksNo){
    this.stats.liveMBlocksNo.push(liveMBlocksNo);
  }

  traceAliveVSDeadMBlocks(ratio) {
    this.stats.aliveVSDeadMBlocks.push(ratio);
  }

  traceGetMBlocks(n) {
    this.stats.allocatedMBlocks += n;
  }

  displayGCStatistics() {
    var stats = this.stats;
    var total_wall_ms = this.now();
    var gc_wall_ms = stats.gc_wall_ms;
    var mutator_wall_ms = total_wall_ms - gc_wall_ms - stats.init_wall_ms;
    var totalLiveMBlocksNo = 0;
    for(const n of stats.liveMBlocksNo) {
      totalLiveMBlocksNo += n;
    }
    var liveMBlocksAverageNo = totalLiveMBlocksNo / stats.liveMBlocksNo.length;
    var aliveVSDeadMBlocks = 0;
    for(const n of stats.aliveVSDeadMBlocks) {
      aliveVSDeadMBlocks += n;
    }
    aliveVSDeadMBlocks /= stats.aliveVSDeadMBlocks.length;
    if (stats.num_major_GCs != stats.aliveVSDeadMBlocks.length || stats.num_major_GCs != stats.liveMBlocksNo.length) {
      throw "Error: inconsistent data gathered by GC statistics"
    }
    console.log("Garbage Collection Statistics", {
      num_major_GCs: stats.num_major_GCs,
      num_minor_GCs: stats.num_minor_GCs,
      average_live_mblocks: liveMBlocksAverageNo,
      alive_vs_dead_mblocks: aliveVSDeadMBlocks,
      allocated_mblocks: stats.allocatedMBlocks,
      init_wall_seconds: stats.init_wall_ms / 1000.0,
      mutator_wall_seconds: mutator_wall_ms / 1000.0,
      GC_wall_seconds: gc_wall_ms / 1000.0,
    });
  }
}
